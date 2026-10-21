//
//  LogExportHTTPServer.swift
//  Yattee
//
//  Lightweight HTTP server for exporting logs on tvOS.
//  Uses NWListener to serve logs as a downloadable text file.
//

import Foundation
import Network

#if os(tvOS)
import Darwin
import Security
import UIKit

/// Lightweight HTTP server for exporting logs on tvOS.
/// Starts a temporary server that serves logs through a protected /logs.txt URL.
@MainActor
@Observable
final class LogExportHTTPServer {
    // MARK: - State

    /// Whether the server is currently running.
    private(set) var isRunning = false

    /// The single-use URL where logs can be downloaded.
    private(set) var serverURL: String?

    /// The port the server is listening on.
    private(set) var port: UInt16?

    /// Error message if server failed to start.
    private(set) var errorMessage: String?

    /// Seconds remaining until auto-stop.
    private(set) var secondsRemaining: Int = 0

    // MARK: - Private

    private var listener: NWListener?
    private var autoStopTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var accessToken: String?
    private var isDownloadInProgress = false
    private let queue = DispatchQueue(label: "stream.yattee.logexport", qos: .userInitiated)

    /// Auto-stop timeout in seconds (5 minutes).
    let autoStopTimeout: Int = 300

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Start the HTTP server.
    func start() {
        guard !isRunning else { return }

        errorMessage = nil

        guard let accessToken = generateAccessToken() else {
            errorMessage = "Unable to secure log export"
            LoggingService.shared.error("Failed to generate log export access token", category: .general)
            return
        }

        guard let ipAddress = getLocalIPAddress() else {
            errorMessage = AppLocalization.string("settings.advanced.logs.export.noNetwork")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true

            // Use port 0 to let the system assign an available port
            let listener = try NWListener(using: parameters, on: .any)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state, ipAddress: ipAddress)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }

            listener.start(queue: queue)
            self.listener = listener
            self.accessToken = accessToken
            isDownloadInProgress = false
            isRunning = true
            secondsRemaining = autoStopTimeout
            startAutoStopTimer()
            startCountdownTimer()

            LoggingService.shared.info("Log export HTTP server starting", category: .general)

        } catch {
            errorMessage = error.localizedDescription
            LoggingService.shared.error("Failed to start log export server", category: .general, details: error.localizedDescription)
        }
    }

    /// Stop the HTTP server.
    func stop() {
        accessToken = nil
        isDownloadInProgress = false
        guard isRunning else { return }

        listener?.cancel()
        listener = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        isRunning = false
        serverURL = nil
        port = nil
        secondsRemaining = 0

        LoggingService.shared.info("Log export HTTP server stopped", category: .general)
    }

    // MARK: - Private: Listener State

    private func handleListenerState(_ state: NWListener.State, ipAddress: String) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                self.port = port
                self.serverURL = accessToken.map { "http://\(ipAddress):\(port)/logs.txt?token=\($0)" }
                LoggingService.shared.info("Log export server ready", category: .general)
            }

        case .failed(let error):
            errorMessage = error.localizedDescription
            LoggingService.shared.error("Log export server failed", category: .general, details: error.localizedDescription)
            stop()

        case .cancelled:
            isRunning = false

        default:
            break
        }
    }

    // MARK: - Private: Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveHTTPRequest(on: connection)
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private nonisolated func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            // Parse HTTP request (minimal parsing)
            if let request = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.handleHTTPRequest(request, on: connection)
                }
            } else {
                connection.cancel()
            }
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        // Check if it's a GET request for /logs.txt
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(on: connection, code: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(on: connection, code: 400, message: "Bad Request")
            return
        }

        guard parts[0] == "GET", let components = requestComponents(from: parts[1]), components.path == "/logs.txt" else {
            sendErrorResponse(on: connection, code: 404, message: "Not Found")
            return
        }

        guard !isDownloadInProgress,
              let accessToken,
              let suppliedToken = components.queryItems?.first(where: { $0.name == "token" })?.value,
              securelyMatches(suppliedToken, accessToken)
        else {
            sendErrorResponse(on: connection, code: 403, message: "Forbidden")
            return
        }

        isDownloadInProgress = true
        sendLogsResponse(on: connection)
    }

    private func sendLogsResponse(on connection: NWConnection) {
        let logs = sanitizedLogExport(LoggingService.shared.exportLogs())
        let logsData = logs.data(using: .utf8) ?? Data()
        let filename = generateLogFilename()

        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Disposition: attachment; filename="\(filename)"\r
        Content-Length: \(logsData.count)\r
        Connection: close\r
        \r

        """

        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(logsData)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            connection.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error == nil {
                    LoggingService.shared.info("Logs downloaded via HTTP", category: .general)
                    self.stop()
                } else {
                    self.isDownloadInProgress = false
                }
            }
        })
    }

    private func requestComponents(from requestTarget: String) -> URLComponents? {
        if requestTarget.hasPrefix("http://") || requestTarget.hasPrefix("https://") {
            return URLComponents(string: requestTarget)
        }
        return URLComponents(string: "http://localhost\(requestTarget)")
    }

    private func generateAccessToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func securelyMatches(_ suppliedToken: String, _ expectedToken: String) -> Bool {
        let suppliedBytes = Array(suppliedToken.utf8)
        let expectedBytes = Array(expectedToken.utf8)
        guard suppliedBytes.count == expectedBytes.count else { return false }

        var difference: UInt8 = 0
        for index in suppliedBytes.indices {
            difference |= suppliedBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }

    private func sanitizedLogExport(_ logs: String) -> String {
        let redactions = [
            (#"(?i)(\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)\s*:\s*)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)(\"(?:password|passwd|access_token|refresh_token|api_key|apikey|client_secret|token)\"\s*:\s*\")[^\"]*(\")"#, "$1[REDACTED]$2"),
            (#"(?i)(\b(?:password|passwd|access_token|refresh_token|api_key|apikey|client_secret|token)\s*=\s*)[^&\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)(://[^:/\s]+:)[^@/\s]+(@)"#, "$1[REDACTED]$2")
        ]

        return redactions.reduce(logs) { result, redaction in
            result.replacingOccurrences(
                of: redaction.0,
                with: redaction.1,
                options: .regularExpression
            )
        }
    }

    /// Generate a filename with device name, build number, and timestamp.
    private func generateLogFilename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())

        // Get device name and sanitize it for filename
        let deviceName = UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        // Get build number
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        return "yattee-logs_\(deviceName)_b\(buildNumber)_\(timestamp).txt"
    }

    private func sendErrorResponse(on connection: NWConnection, code: Int, message: String) {
        let body = "<html><body><h1>\(code) \(message)</h1></body></html>"
        let bodyData = body.data(using: .utf8) ?? Data()

        let headers = """
        HTTP/1.1 \(code) \(message)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """

        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Private: Timers

    private func startAutoStopTimer() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(autoStopTimeout))
            guard !Task.isCancelled else { return }
            self.stop()
        }
    }

    private func startCountdownTimer() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.secondsRemaining -= 1
            }
        }
    }

    // MARK: - Private: IP Address Detection

    /// Get the local IP address, preferring WiFi (en0) or Ethernet (en1).
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // Prefer en0 (WiFi) or en1 (Ethernet on Apple TV)
        let preferredInterfaces = ["en0", "en1"]

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family

            guard family == UInt8(AF_INET) else { continue } // IPv4 only

            let name = String(cString: interface.ifa_name)
            guard preferredInterfaces.contains(name) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: hostname)

            // Prefer en0 if both exist
            if name == "en0" { break }
        }

        return address
    }
}
#endif
