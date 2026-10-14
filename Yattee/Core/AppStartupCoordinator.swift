//
//  AppStartupCoordinator.swift
//  Yattee
//
//  Coordinates safe startup of persistent storage and dependent services.
//

import Foundation

@MainActor
@Observable
final class AppStartupCoordinator {
    // MARK: - Types

    struct StartupFailure: Equatable, Sendable {
        let diagnosticID: UUID
        let errorDomain: String
        let errorCode: Int
    }

    enum State {
        case initializing
        case ready(AppEnvironment)
        case failed(StartupFailure)
    }

    typealias DataManagerFactory = @MainActor () throws -> DataManager
    typealias EnvironmentFactory = @MainActor (
        DataManager,
        NotificationManager,
        BackgroundRefreshManager
    ) -> AppEnvironment

    // MARK: - Shared Instance

    static let shared = AppStartupCoordinator()

    // MARK: - State

    private(set) var state: State = .initializing

    var readyEnvironment: AppEnvironment? {
        guard case .ready(let environment) = state else { return nil }
        return environment
    }

    var isInitializing: Bool {
        if case .initializing = state { return true }
        return false
    }

    // MARK: - Dependencies

    let backgroundRefreshManager: BackgroundRefreshManager

    private let notificationManager: NotificationManager
    private let dataManagerFactory: DataManagerFactory
    private let environmentFactory: EnvironmentFactory
    private var startupTask: Task<Void, Never>?
    private var backgroundTasksRegistered = false

    // MARK: - Initialization

    init(
        notificationManager: NotificationManager? = nil,
        backgroundRefreshManager: BackgroundRefreshManager? = nil,
        dataManagerFactory: @escaping DataManagerFactory = { try DataManager() },
        environmentFactory: @escaping EnvironmentFactory = { dataManager, notificationManager, backgroundRefreshManager in
            AppEnvironment(
                dataManager: dataManager,
                notificationManager: notificationManager,
                backgroundRefreshManager: backgroundRefreshManager
            )
        }
    ) {
        let notificationManager = notificationManager ?? NotificationManager()
        self.notificationManager = notificationManager
        self.backgroundRefreshManager = backgroundRefreshManager
            ?? BackgroundRefreshManager(notificationManager: notificationManager)
        self.dataManagerFactory = dataManagerFactory
        self.environmentFactory = environmentFactory
    }

    // MARK: - Startup

    /// Registers platform background tasks exactly once during the launch sequence.
    /// The manager safely rejects refresh work until a ready environment is injected.
    func registerBackgroundTasks() {
        guard !backgroundTasksRegistered else { return }
        backgroundTasksRegistered = true
        backgroundRefreshManager.registerBackgroundTasks()
    }

    /// Starts the initial attempt or retries a failed attempt.
    /// Calls made while an attempt is active or after success are ignored.
    func startOrRetry() {
        guard startupTask == nil, readyEnvironment == nil else { return }

        state = .initializing
        startupTask = Task { @MainActor [weak self] in
            // Yield once so SwiftUI can render the progress state before the
            // synchronous ModelContainer initialization begins.
            await Task.yield()
            self?.performStartupAttempt()
        }
    }

    /// Waits for the current attempt. Intended for deterministic tests.
    func waitForCurrentAttempt() async {
        await startupTask?.value
    }

    private func performStartupAttempt() {
        defer { startupTask = nil }

        do {
            let dataManager = try dataManagerFactory()
            let environment = environmentFactory(
                dataManager,
                notificationManager,
                backgroundRefreshManager
            )
            AppEnvironment.registerCurrent(environment)
            state = .ready(environment)
        } catch {
            let nsError = error as NSError
            let diagnosticID = UUID()
            LoggingService.shared.error(
                "Persistent storage failed to open",
                category: .general,
                details: "diagnosticID: \(diagnosticID.uuidString), domain: \(nsError.domain), code: \(nsError.code)"
            )
            state = .failed(
                StartupFailure(
                    diagnosticID: diagnosticID,
                    errorDomain: nsError.domain,
                    errorCode: nsError.code
                )
            )
        }
    }
}
