//
//  BackgroundFeedRefresher.swift
//  Yattee
//
//  Core background feed refresh logic for notifications.
//

import Foundation
import UserNotifications

/// Performs background feed refresh and detects new videos for notifications.
/// Only fetches videos from channels with notifications enabled.
@MainActor
final class BackgroundFeedRefresher {
    // MARK: - Dependencies

    private weak var appEnvironment: AppEnvironment?
    private let notificationManager: NotificationManager
    /// Shared across the scheduler-owned refresher and the debug/manual refresher
    /// created by NotificationManager.
    private static var refreshRunState = NotificationRefreshRunState()

    // MARK: - Initialization

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    func setAppEnvironment(_ environment: AppEnvironment) {
        self.appEnvironment = environment
    }

    // MARK: - Refresh Logic

    /// Performs background refresh and sends notifications for new videos.
    /// Routes to appropriate refresh method based on subscription account type.
    @discardableResult
    func performBackgroundRefresh(origin: String = "manual", runID suppliedRunID: UUID? = nil) async -> Bool {
        let runID = suppliedRunID ?? UUID()
        #if DEBUG
        NotificationPipelineDiagnostic.shared.startRun(id: runID, origin: origin)
        #endif

        guard Self.refreshRunState.begin() else {
            LoggingService.shared.debug(
                "Background refresh coalesced: another refresh is already running",
                category: .notifications
            )
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "coalesced", runID: runID)
            NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: true)
            #endif
            return true
        }
        defer { Self.refreshRunState.end() }

        guard let appEnvironment else {
            LoggingService.shared.warning("Background refresh skipped: no app environment", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:noAppEnvironment", runID: runID)
            NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: false)
            #endif
            return false
        }

        let notificationsEnabled = appEnvironment.settingsManager.backgroundNotificationsEnabled
        let badgeEnabled = appEnvironment.settingsManager.appIconBadgeEnabled
        guard BackgroundRefreshPolicy.isEnabled(
            notificationsEnabled: notificationsEnabled,
            appIconBadgeEnabled: badgeEnabled
        ) else {
            LoggingService.shared.debug("Background refresh disabled in settings", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordContext(
                runID: runID,
                account: NotificationRefreshScope.key(for: appEnvironment.settingsManager.subscriptionAccount),
                source: appEnvironment.settingsManager.subscriptionAccount.type.rawValue,
                instanceID: appEnvironment.settingsManager.subscriptionAccount.instanceID,
                authorizationStatus: notificationManager.authorizationStatus.rawValue,
                globalSettingEnabled: false
            )
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:globalDisabled", runID: runID)
            NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: true)
            #endif
            return true
        }

        if notificationsEnabled {
            await notificationManager.refreshAuthorizationStatus()
        }
        let account = appEnvironment.settingsManager.subscriptionAccount
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordContext(
            runID: runID,
            account: NotificationRefreshScope.key(for: account),
            source: account.type.rawValue,
            instanceID: account.instanceID,
            authorizationStatus: notificationManager.authorizationStatus.rawValue,
            globalSettingEnabled: notificationsEnabled
        )
        #endif
        let source = LocalFeedSource.resolve(
            from: appEnvironment.instancesManager.instances,
            preference: appEnvironment.settingsManager.localFeedSourcePreference
        )
        guard FeedNoveltyScope.localFeed(source: source) != nil else {
            LoggingService.shared.warning("Background refresh skipped: active Feed source is unavailable", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "configurationError:noLocalFeedSource", runID: runID)
            NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: false)
            #endif
            return false
        }

        let succeeded: Bool
        do {
            let acquisition = try await SubscriptionFeedCache.shared.synchronizeSilently(using: appEnvironment)
            try Task.checkCancellation()
            await consume(
                acquisition,
                notificationScope: NotificationRefreshScope.key(for: account),
                notificationsEnabled: notificationsEnabled && notificationManager.isAuthorized,
                badgeEnabled: badgeEnabled,
                runID: runID
            )
            succeeded = true
        } catch is CancellationError {
            LoggingService.shared.debug("Background Feed refresh cancelled", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "cancelled", runID: runID)
            #endif
            succeeded = false
        } catch {
            LoggingService.shared.logNotificationError("Background Feed refresh failed", error: error)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "error:\(String(describing: type(of: error)))", runID: runID)
            #endif
            succeeded = false
        }
        #if DEBUG
        NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: succeeded)
        #endif
        return succeeded
    }

    private func consume(
        _ acquisition: BackgroundFeedAcquisition,
        notificationScope: String,
        notificationsEnabled: Bool,
        badgeEnabled: Bool,
        runID: UUID
    ) async {
        guard let appEnvironment else { return }
        // SubscriptionFeedCache has already ingested this exact acquisition in
        // FeedNoveltyRegistry before publishing its resulting snapshot.

        var sourceStillActive = BackgroundRefreshPolicy.canConsume(
            acquiredScope: acquisition.scope,
            activeScope: FeedNoveltyScope.active(in: appEnvironment)
        )
        var appIconBadgeCount: Int? = nil
        if badgeEnabled, sourceStillActive {
            let snapshot = await FeedNoveltyRegistry.shared.snapshot(for: acquisition.scope)
            sourceStillActive = BackgroundRefreshPolicy.canConsume(
                acquiredScope: acquisition.scope,
                activeScope: FeedNoveltyScope.active(in: appEnvironment)
            )
            guard sourceStillActive else { return }
            let count = FeedNoveltyBadgeFilter.count(
                entries: snapshot.unconsulted,
                excluding: ChannelBadgePreferences.shared.excludedChannelIDs(in: acquisition.scope),
                includeShorts: appEnvironment.settingsManager.badgesIncludeShorts
            )
            appIconBadgeCount = count
            #if os(iOS)
            _ = await AppIconBadgeManager.shared.reconcile(count: count, enabled: true)
            sourceStillActive = BackgroundRefreshPolicy.canConsume(
                acquiredScope: acquisition.scope,
                activeScope: FeedNoveltyScope.active(in: appEnvironment)
            )
            #endif
        }

        guard notificationsEnabled, sourceStillActive else {
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordSubmission("notAttempted:notificationsDisabled", runID: runID)
            #endif
            return
        }
        let hasNotificationBaseline = appEnvironment.settingsManager
            .notificationRefreshState(for: notificationScope).lastCheck != nil
        guard BackgroundRefreshPolicy.canProcessNotifications(
            isCompleteSnapshot: acquisition.isCompleteSnapshot,
            hasBaseline: hasNotificationBaseline
        ) else {
            LoggingService.shared.info(
                "Incomplete background snapshot ignored until a complete baseline exists",
                category: .notifications
            )
            return
        }
        let enabledChannels = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())
        let notificationVideos = acquisition.videos
            .filter { enabledChannels.contains($0.author.id) }
            .map { (video: $0, channelName: $0.author.name) }
        await processFetchedVideos(
            notificationVideos,
            requestStartedAt: acquisition.observedAt,
            scope: notificationScope,
            appIconBadgeCount: appIconBadgeCount,
            runID: runID
        )
    }

    // MARK: - Notification Transaction

    /// Plans, submits, then commits a refresh. Only videos accepted by the
    /// notification center (plus permanently ignored videos) enter the ledger.
    private func processFetchedVideos(
        _ fetchedVideos: [(video: Video, channelName: String)],
        requestStartedAt: Date,
        scope: String,
        appIconBadgeCount: Int?,
        runID: UUID
    ) async {
        guard let appEnvironment else { return }

        let settingsManager = appEnvironment.settingsManager
        let watchEntries = appEnvironment.dataManager.watchEntriesMap()
        let persistentState = settingsManager.notificationRefreshState(for: scope)
        let processedVideos = persistentState.processedVideos
        let pendingVideos = persistentState.pendingVideos
        var pendingRecords = persistentState.pendingRecords
        let legacyVideoIDs = Set(settingsManager.lastNotifiedVideoPerChannel.values)

        let fetchedKeys = Set(fetchedVideos.map { $0.video.id.id })
        let persistedRetries = pendingRecords
            .filter { !fetchedKeys.contains($0.key) }
            .map { (video: $0.value.video, channelName: $0.value.channelName) }
        let videosForProcessing = fetchedVideos + persistedRetries

        let candidates = videosForProcessing.map { item in
            let watchEntry = watchEntries[item.video.id.videoID]
            return NotificationRefreshCandidate(
                deduplicationKey: item.video.id.id,
                legacyVideoID: item.video.id.videoID,
                publishedAt: item.video.publishedAt,
                isUpcoming: item.video.isUpcoming,
                isWatched: (watchEntry?.watchedSeconds ?? 0) > 0 || watchEntry?.isFinished == true,
                contentKind: item.video.contentKind
            )
        }

        let plan = NotificationRefreshTransaction.plan(
            candidates: candidates,
            requestStartedAt: requestStartedAt,
            previousCheck: persistentState.lastCheck,
            processedKeys: Set(processedVideos.keys),
            legacyProcessedVideoIDs: legacyVideoIDs,
            pendingKeys: Set(pendingVideos.keys),
            includeShorts: settingsManager.notificationsIncludeShorts
        )
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordPlan(
            eligible: plan.eligibleKeys.count,
            ignored: plan.ignoredKeys.count,
            deferred: plan.deferredKeys.count,
            runID: runID
        )
        #endif

        if plan.isInitialBaseline {
            settingsManager.setNotificationRefreshState(
                NotificationRefreshPersistentState(
                    lastCheck: requestStartedAt,
                    processedVideos: processedVideos,
                    pendingVideos: pendingVideos,
                    pendingRecords: pendingRecords
                ),
                for: scope
            )
            LoggingService.shared.info(
                "Background refresh established initial baseline without historical notifications",
                category: .notifications
            )
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordSubmission("notAttempted:initialBaseline", runID: runID)
            #endif
            return
        }

        let eligibleKeys = Set(plan.eligibleKeys)
        let videosToNotify = videosForProcessing
            .filter { eligibleKeys.contains($0.video.id.id) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.video.publishedAt ?? .distantPast
                let rhsDate = rhs.video.publishedAt ?? .distantPast
                if lhsDate == rhsDate { return lhs.video.id.id < rhs.video.id.id }
                return lhsDate < rhsDate
            }

        let submissionAccepted: Bool
        if videosToNotify.isEmpty {
            submissionAccepted = true
        } else {
            #if !os(tvOS)
            submissionAccepted = await notificationManager.sendNotification(
                for: videosToNotify,
                appIconBadgeCount: appIconBadgeCount,
                diagnosticRunID: runID
            )
            #else
            submissionAccepted = true
            #endif
        }
        #if DEBUG
        if videosToNotify.isEmpty {
            NotificationPipelineDiagnostic.shared.recordSubmission("notAttempted:noEligibleVideos", runID: runID)
        }
        #endif

        let committedState = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: submissionAccepted,
            existingProcessedVideos: processedVideos,
            existingPendingVideos: pendingVideos
        )
        for key in plan.ignoredKeys {
            pendingRecords.removeValue(forKey: key)
        }
        if submissionAccepted {
            for key in plan.eligibleKeys {
                pendingRecords.removeValue(forKey: key)
            }
        } else {
            let retryKeys = Set(plan.eligibleKeys)
            for item in videosToNotify where retryKeys.contains(item.video.id.id) {
                pendingRecords[item.video.id.id] = PendingNotificationRecord(
                    video: item.video,
                    channelName: item.channelName,
                    queuedAt: requestStartedAt.timeIntervalSince1970
                )
            }
        }
        settingsManager.setNotificationRefreshState(
            NotificationRefreshPersistentState(
                lastCheck: committedState.lastCheck,
                processedVideos: committedState.processedVideos,
                pendingVideos: committedState.pendingVideos,
                pendingRecords: NotificationRefreshTransaction.boundedPendingRecords(pendingRecords)
            ),
            for: scope
        )

        LoggingService.shared.info(
            "Background refresh complete | eligible: \(videosToNotify.count) | ignored: \(plan.ignoredKeys.count) | deferred: \(plan.deferredKeys.count) | submission accepted: \(submissionAccepted)",
            category: .notifications
        )
    }
}
