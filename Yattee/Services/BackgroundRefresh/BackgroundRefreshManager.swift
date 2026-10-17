//
//  BackgroundRefreshManager.swift
//  Yattee
//
//  Platform-specific background refresh orchestration.
//

import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Manages background refresh scheduling and execution across platforms.
@MainActor
final class BackgroundRefreshManager {
    // MARK: - Constants

    static let backgroundTaskIdentifier = AppIdentifiers.backgroundFeedRefresh

    #if os(macOS)
    private var activityScheduler: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Dependencies

    private weak var appEnvironment: AppEnvironment?
    private let backgroundRefresher: BackgroundFeedRefresher
    private let notificationManager: NotificationManager
    #if os(iOS)
    private var isScheduling = false
    #endif

    // MARK: - Initialization

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        self.backgroundRefresher = BackgroundFeedRefresher(notificationManager: notificationManager)
    }

    func setAppEnvironment(_ environment: AppEnvironment) {
        self.appEnvironment = environment
        backgroundRefresher.setAppEnvironment(environment)
    }

    // MARK: - Registration (call at app launch)

    func registerBackgroundTasks() {
        #if os(iOS)
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        registerIOSBackgroundTask()
        #elseif os(macOS)
        registerMacOSBackgroundActivity()
        #endif
    }

    // MARK: - iOS Implementation

    #if os(iOS)
    private func registerIOSBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleIOSBackgroundTask(task)
        }
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordRegistration(registered)
        LoggingService.shared.info(
            "Registered iOS background task | success: \(registered)",
            category: .notifications
        )
        refreshPendingTaskDiagnostics()
        #else
        LoggingService.shared.info("Registered iOS background task", category: .notifications)
        #endif
    }

    func scheduleIOSBackgroundRefresh() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        guard shouldKeepBackgroundRefreshScheduled,
              UIApplication.shared.backgroundRefreshStatus == .available,
              !isScheduling else { return }
        isScheduling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isScheduling = false }
            let identifiers = await Self.pendingTaskIdentifiers()
            guard BackgroundRefreshPolicy.shouldSubmit(
                pendingIdentifiers: identifiers,
                identifier: Self.backgroundTaskIdentifier,
                isEnabled: self.shouldKeepBackgroundRefreshScheduled,
                isAvailable: UIApplication.shared.backgroundRefreshStatus == .available
            ) else { return }
            let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
                LoggingService.shared.info("Scheduled iOS background refresh", category: .notifications)
            } catch {
                LoggingService.shared.logNotificationError("Failed to schedule background refresh", error: error)
            }
            #if DEBUG
            self.refreshPendingTaskDiagnostics()
            #endif
        }
    }

    nonisolated private static func pendingTaskIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    func cancelIOSBackgroundRefresh() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        LoggingService.shared.debug("Cancelled iOS background refresh", category: .notifications)
    }

    private var shouldKeepBackgroundRefreshScheduled: Bool {
        guard let settings = appEnvironment?.settingsManager else { return false }
        return BackgroundRefreshPolicy.isEnabled(
            notificationsEnabled: settings.backgroundNotificationsEnabled,
            appIconBadgeEnabled: settings.appIconBadgeEnabled
        )
    }

    private func handleIOSBackgroundTask(_ task: BGAppRefreshTask) {
        let runID = UUID()
        #if DEBUG
        LoggingService.shared.info("iOS background task started | runID: \(runID.uuidString)", category: .notifications)
        #else
        LoggingService.shared.info("iOS background task started", category: .notifications)
        #endif

        // Schedule the next refresh immediately
        scheduleIOSBackgroundRefresh()

        // Create a task to perform the refresh
        let refreshTask = Task { @MainActor in
            await backgroundRefresher.performBackgroundRefresh(origin: "BGTaskScheduler", runID: runID)
        }

        // Set expiration handler
        task.expirationHandler = {
            #if DEBUG
            LoggingService.shared.warning("iOS background task expired | runID: \(runID.uuidString)", category: .notifications)
            Task { @MainActor in
                NotificationPipelineDiagnostic.shared.recordExpiration(runID: runID)
            }
            #else
            LoggingService.shared.warning("iOS background task expired", category: .notifications)
            #endif
            refreshTask.cancel()
        }

        // Wait for completion
        Task {
            let succeeded = await refreshTask.value
            task.setTaskCompleted(success: succeeded && !refreshTask.isCancelled)
            #if DEBUG
            LoggingService.shared.info(
                "iOS background task completed | runID: \(runID.uuidString) | success: \(succeeded && !refreshTask.isCancelled)",
                category: .notifications
            )
            #else
            LoggingService.shared.info(
                "iOS background task completed | success: \(succeeded && !refreshTask.isCancelled)",
                category: .notifications
            )
            #endif
        }
    }

    #if DEBUG
    func refreshPendingTaskDiagnostics() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let details = requests.map {
                "\($0.identifier) | earliestBeginDate: \(String(describing: $0.earliestBeginDate))"
            }
            LoggingService.shared.debug(
                "Pending iOS background requests | count: \(requests.count) | \(details.joined(separator: "; "))",
                category: .notifications
            )
            Task { @MainActor in
                NotificationPipelineDiagnostic.shared.recordPendingRequests(
                    requests.map { (identifier: $0.identifier, earliestBeginDate: $0.earliestBeginDate) }
                )
            }
        }
    }
    #endif
    #endif

    // MARK: - macOS Implementation

    #if os(macOS)
    private func registerMacOSBackgroundActivity() {
        let scheduler = NSBackgroundActivityScheduler(identifier: Self.backgroundTaskIdentifier)
        scheduler.repeats = true
        #if DEBUG
        scheduler.interval = 60  // 1 minute for testing
        scheduler.tolerance = 30
        #else
        scheduler.interval = 15 * 60  // 15 minutes
        scheduler.tolerance = 5 * 60  // 5 minute tolerance
        #endif
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }

            Task { @MainActor in
                LoggingService.shared.info("macOS background activity started", category: .notifications)
                let succeeded = await self.backgroundRefresher.performBackgroundRefresh(origin: "NSBackgroundActivityScheduler")
                completion(succeeded ? .finished : .deferred)
                LoggingService.shared.info("macOS background activity completed", category: .notifications)
            }
        }

        self.activityScheduler = scheduler
        LoggingService.shared.info("Registered macOS background activity", category: .notifications)
    }

    func invalidateMacOSScheduler() {
        activityScheduler?.invalidate()
        activityScheduler = nil
        LoggingService.shared.debug("Invalidated macOS background scheduler", category: .notifications)
    }

    func restartMacOSScheduler() {
        invalidateMacOSScheduler()
        registerMacOSBackgroundActivity()
    }
    #endif

    // MARK: - Enable/Disable

    func handleNotificationsEnabledChanged(_: Bool) {
        handleRefreshRequirementChanged()
    }

    func handleAppIconBadgeEnabledChanged(_: Bool) {
        handleRefreshRequirementChanged()
    }

    private func handleRefreshRequirementChanged() {
        #if os(iOS)
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        if shouldKeepBackgroundRefreshScheduled {
            scheduleIOSBackgroundRefresh()
        } else {
            cancelIOSBackgroundRefresh()
        }
        #elseif os(macOS)
        let enabled = appEnvironment.map {
            BackgroundRefreshPolicy.isEnabled(
                notificationsEnabled: $0.settingsManager.backgroundNotificationsEnabled,
                appIconBadgeEnabled: $0.settingsManager.appIconBadgeEnabled
            )
        } ?? false
        if enabled {
            if activityScheduler == nil {
                registerMacOSBackgroundActivity()
            }
        } else {
            invalidateMacOSScheduler()
        }
        #endif
    }
}
