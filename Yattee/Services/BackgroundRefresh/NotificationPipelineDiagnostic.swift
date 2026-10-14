//
//  NotificationPipelineDiagnostic.swift
//  Yattee
//
//  DEBUG-only persistent diagnostics for the local notification pipeline.
//

#if DEBUG
import Foundation

@MainActor
@Observable
final class NotificationPipelineDiagnostic {
    struct Run: Codable, Identifiable, Sendable {
        let id: UUID
        let startedAt: Date
        var endedAt: Date?
        let origin: String
        var account: String?
        var source: String?
        var instanceID: String?
        var authorizationStatus: Int?
        var globalSettingEnabled: Bool?
        var enabledChannelCount: Int?
        var hadBaseline: Bool?
        var feedResult: String?
        var feedVideoCount: Int?
        var eligibleCount: Int?
        var ignoredCount: Int?
        var deferredCount: Int?
        var notificationSubmission: String?
        var finalResult: String?
        var expired = false

        init(id: UUID, startedAt: Date, origin: String) {
            self.id = id
            self.startedAt = startedAt
            self.origin = origin
        }
    }

    static let shared = NotificationPipelineDiagnostic()

    private static let storageKey = "debug.notificationPipeline.runs.v1"
    private static let maximumRunCount = 20

    private(set) var registrationResult: Bool?
    private(set) var pendingRequests: [String] = []
    private(set) var pendingRequestsUpdatedAt: Date?
    private(set) var runs: [Run] = []

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Run].self, from: data) else { return }
        runs = Self.boundedRuns(decoded)
    }

    func recordRegistration(_ succeeded: Bool) {
        registrationResult = succeeded
    }

    func recordPendingRequests(_ requests: [(identifier: String, earliestBeginDate: Date?)]) {
        let formatter = ISO8601DateFormatter()
        pendingRequests = requests.map { request in
            let date = request.earliestBeginDate.map(formatter.string(from:)) ?? "nil"
            return "\(request.identifier) | earliestBeginDate=\(date)"
        }
        pendingRequestsUpdatedAt = Date()
    }

    func startRun(id: UUID, origin: String, startedAt: Date = Date()) {
        guard !runs.contains(where: { $0.id == id }) else { return }
        runs.insert(Run(id: id, startedAt: startedAt, origin: origin), at: 0)
        trimAndPersist()
    }

    func recordContext(
        runID: UUID,
        account: String,
        source: String,
        instanceID: UUID?,
        authorizationStatus: Int,
        globalSettingEnabled: Bool
    ) {
        update(runID) {
            $0.account = account
            $0.source = source
            $0.instanceID = instanceID?.uuidString
            $0.authorizationStatus = authorizationStatus
            $0.globalSettingEnabled = globalSettingEnabled
        }
    }

    func recordEnabledChannels(_ count: Int, runID: UUID) {
        update(runID) { $0.enabledChannelCount = count }
    }

    func recordBaseline(_ exists: Bool, runID: UUID) {
        update(runID) { $0.hadBaseline = exists }
    }

    func recordFeed(result: String, videoCount: Int? = nil, runID: UUID) {
        update(runID) {
            $0.feedResult = result
            $0.feedVideoCount = videoCount
        }
    }

    func recordPlan(eligible: Int, ignored: Int, deferred: Int, runID: UUID) {
        update(runID) {
            $0.eligibleCount = eligible
            $0.ignoredCount = ignored
            $0.deferredCount = deferred
        }
    }

    func recordSubmission(_ result: String, runID: UUID) {
        update(runID) { $0.notificationSubmission = result }
    }

    func recordExpiration(runID: UUID) {
        update(runID) {
            $0.expired = true
            $0.finalResult = "expired"
        }
    }

    func finish(runID: UUID, succeeded: Bool) {
        update(runID) {
            $0.endedAt = Date()
            if !$0.expired {
                $0.finalResult = succeeded ? "success" : "failure"
            }
        }
    }

    var textReport: String {
        let formatter = ISO8601DateFormatter()
        let registration = registrationResult.map(String.init) ?? "unknown"
        var lines = [
            "YaTubee notification diagnostic",
            "generatedAt=\(formatter.string(from: Date()))",
            "bgTaskRegistered=\(registration)",
            "pendingRequestsUpdatedAt=\(pendingRequestsUpdatedAt.map(formatter.string(from:)) ?? "never")",
            "pendingRequests=\(pendingRequests.isEmpty ? "none" : pendingRequests.joined(separator: "; "))"
        ]

        for run in runs {
            lines.append([
                "runID=\(run.id.uuidString)",
                "startedAt=\(formatter.string(from: run.startedAt))",
                "endedAt=\(run.endedAt.map(formatter.string(from:)) ?? "running")",
                "origin=\(run.origin)",
                "account=\(run.account ?? "unknown")",
                "source=\(run.source ?? "unknown")",
                "instanceID=\(run.instanceID ?? "none")",
                "authorizationStatus=\(run.authorizationStatus.map(String.init) ?? "unknown")",
                "globalEnabled=\(run.globalSettingEnabled.map(String.init) ?? "unknown")",
                "enabledChannels=\(run.enabledChannelCount.map(String.init) ?? "unknown")",
                "hadBaseline=\(run.hadBaseline.map(String.init) ?? "unknown")",
                "feed=\(run.feedResult ?? "not reached")",
                "feedVideos=\(run.feedVideoCount.map(String.init) ?? "unknown")",
                "eligible=\(run.eligibleCount.map(String.init) ?? "unknown")",
                "ignored=\(run.ignoredCount.map(String.init) ?? "unknown")",
                "deferred=\(run.deferredCount.map(String.init) ?? "unknown")",
                "submission=\(run.notificationSubmission ?? "not attempted")",
                "expired=\(run.expired)",
                "result=\(run.finalResult ?? "running")"
            ].joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    private func update(_ runID: UUID, mutation: (inout Run) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        mutation(&runs[index])
        trimAndPersist()
    }

    private func trimAndPersist() {
        runs = Self.boundedRuns(runs)
        guard let data = try? JSONEncoder().encode(runs) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func boundedRuns(_ runs: [Run]) -> [Run] {
        Array(runs.prefix(maximumRunCount))
    }
}
#endif
