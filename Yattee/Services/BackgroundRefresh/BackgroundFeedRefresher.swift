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
    private static let serverPollingAttempts = 4
    private static let serverPollingInterval: Duration = .seconds(3)

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

        let globalSettingEnabled = appEnvironment.settingsManager.backgroundNotificationsEnabled
        guard globalSettingEnabled else {
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

        await notificationManager.refreshAuthorizationStatus()
        let account = appEnvironment.settingsManager.subscriptionAccount
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordContext(
            runID: runID,
            account: NotificationRefreshScope.key(for: account),
            source: account.type.rawValue,
            instanceID: account.instanceID,
            authorizationStatus: notificationManager.authorizationStatus.rawValue,
            globalSettingEnabled: globalSettingEnabled
        )
        #endif
        guard notificationManager.isAuthorized else {
            LoggingService.shared.info(
                "Background refresh skipped: notification authorization status is \(notificationManager.authorizationStatus.rawValue)",
                category: .notifications
            )
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:notAuthorized", runID: runID)
            NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: true)
            #endif
            return true
        }

        // Route based on subscription account type
        let scope = NotificationRefreshScope.key(for: account)
        let succeeded: Bool
        switch account.type {
        case .local:
            succeeded = await performLocalAccountRefresh(scope: scope, runID: runID)
        case .invidious:
            succeeded = await performInvidiousAccountRefresh(account: account, scope: scope, runID: runID)
        case .piped:
            succeeded = await performPipedAccountRefresh(account: account, scope: scope, runID: runID)
        }
        #if DEBUG
        NotificationPipelineDiagnostic.shared.finish(runID: runID, succeeded: succeeded)
        #endif
        return succeeded
    }

    // MARK: - Local Account Refresh

    /// Performs background refresh for local (Yattee/iCloud) subscription account.
    /// Requires Yattee Server - uses stateless feed endpoint for efficient single-request fetching.
    private func performLocalAccountRefresh(scope: String, runID: UUID) async -> Bool {
        guard let appEnvironment else { return false }

        // Require Yattee Server for local account background refresh
        guard let yatteeServer = appEnvironment.instancesManager.instances
            .first(where: { $0.type == .yatteeServer && $0.isEnabled }) else {
            LoggingService.shared.debug("Background refresh requires Yattee Server for local subscriptions", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "configurationError:noYatteeServer", runID: runID)
            #endif
            return false
        }

        // Get channel IDs with notifications enabled from ChannelNotificationSettings
        let notifiableChannelIDs = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())

        // Filter subscriptions to only those with notifications enabled
        let notifiableSubscriptions = appEnvironment.dataManager.subscriptions().filter {
            notifiableChannelIDs.contains($0.channelID)
        }
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordEnabledChannels(notifiableSubscriptions.count, runID: runID)
        NotificationPipelineDiagnostic.shared.recordBaseline(
            appEnvironment.settingsManager.notificationRefreshState(for: scope).lastCheck != nil,
            runID: runID
        )
        #endif

        LoggingService.shared.info(
            "Background refresh starting (local account) | scope: \(scope) | channels with notifications: \(notifiableSubscriptions.count)",
            category: .notifications
        )

        guard !notifiableSubscriptions.isEmpty else {
            LoggingService.shared.debug("No subscriptions with notifications enabled", category: .notifications)
            advanceBaseline(for: scope, using: appEnvironment.settingsManager)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:noEnabledChannels", videoCount: 0, runID: runID)
            #endif
            return true
        }

        LoggingService.shared.debug("Fetching feed from Yattee Server: \(yatteeServer.url)", category: .notifications)

        // Convert subscriptions to channel requests
        let channelRequests = notifiableSubscriptions.map { subscription in
            StatelessChannelRequest(
                channelId: subscription.channelID,
                site: subscription.site,
                channelName: subscription.name,
                channelUrl: subscription.channelURLString,
                avatarUrl: subscription.avatarURLString
            )
        }

        let requestStartedAt = Date()
        do {
            let httpClient = HTTPClient()
            if let authHeader = appEnvironment.basicAuthCredentialsManager.basicAuthHeader(for: yatteeServer) {
                await httpClient.setDefaultHeaders(["Authorization": authHeader])
            }
            let yatteeServerAPI = YatteeServerAPI(httpClient: httpClient)
            let response = try await fetchCompleteYatteeServerFeed(
                api: yatteeServerAPI,
                channels: channelRequests,
                limit: 5 * notifiableSubscriptions.count,
                instance: yatteeServer,
                runID: runID
            )

            LoggingService.shared.debug("API returned \(response.videos.count) total videos", category: .notifications)

            let videos = response.videos.compactMap { serverVideo -> (video: Video, channelName: String)? in
                guard let video = serverVideo.toVideo() else { return nil }
                return (video, serverVideo.author)
            }
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "success", videoCount: videos.count, runID: runID)
            #endif
            await processFetchedVideos(videos, requestStartedAt: requestStartedAt, scope: scope, runID: runID)
            return true
        } catch is CancellationError {
            LoggingService.shared.debug("Background refresh cancelled (local account)", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "cancelled", runID: runID)
            #endif
            return false
        } catch {
            LoggingService.shared.logNotificationError("Background refresh failed (local account)", error: error)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "error:\(String(describing: type(of: error)))", runID: runID)
            #endif
            return false
        }
    }

    private func fetchCompleteYatteeServerFeed(
        api: YatteeServerAPI,
        channels: [StatelessChannelRequest],
        limit: Int,
        instance: Instance,
        runID: UUID
    ) async throws -> StatelessFeedResponse {
        var response = try await api.postFeed(
            channels: channels,
            limit: limit,
            offset: 0,
            instance: instance
        )
        guard !NotificationRefreshTransaction.isCompleteYatteeServerResponse(response) else {
            return response
        }
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordFeed(result: "partial", videoCount: response.videos.count, runID: runID)
        #endif

        let statusChannels = channels.map {
            StatelessChannelStatusRequest(channelId: $0.channelId, site: $0.site)
        }
        for attempt in 1...Self.serverPollingAttempts {
            try Task.checkCancellation()
            try await Task.sleep(for: Self.serverPollingInterval)
            try Task.checkCancellation()

            let status = try await api.postFeedStatus(channels: statusChannels, instance: instance)
            guard status.isReady, status.pendingCount == 0, status.errorCount == 0 else {
                LoggingService.shared.debug(
                    "Background feed remains incomplete (attempt \(attempt)/\(Self.serverPollingAttempts), pending: \(status.pendingCount), errors: \(status.errorCount))",
                    category: .notifications
                )
                continue
            }

            response = try await api.postFeed(
                channels: channels,
                limit: limit,
                offset: 0,
                instance: instance
            )
            if NotificationRefreshTransaction.isCompleteYatteeServerResponse(response) {
                return response
            }
        }

        throw BackgroundFeedRefreshError.incompleteYatteeServerResponse
    }

    // MARK: - Invidious Account Refresh

    /// Performs background refresh for Invidious subscription account.
    /// Fetches the full Invidious feed and filters to channels with notifications enabled.
    private func performInvidiousAccountRefresh(
        account: SubscriptionAccount,
        scope: String,
        runID: UUID
    ) async -> Bool {
        guard let appEnvironment else { return false }

        // Use the exact instance selected by the active subscription account,
        // matching SubscriptionFeedCache and the subscription provider.
        guard let instanceID = account.instanceID,
              let invidiousInstance = appEnvironment.instancesManager.instances
              .first(where: { $0.id == instanceID && $0.type == .invidious && $0.isEnabled }),
              let sid = appEnvironment.invidiousCredentialsManager.sid(for: invidiousInstance) else {
            LoggingService.shared.debug("Background refresh requires authenticated Invidious instance", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "configurationError:invidiousAuthentication", runID: runID)
            #endif
            return false
        }

        // Get channel IDs with notifications enabled from ChannelNotificationSettings
        let notifiableChannelIDs = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordEnabledChannels(notifiableChannelIDs.count, runID: runID)
        NotificationPipelineDiagnostic.shared.recordBaseline(
            appEnvironment.settingsManager.notificationRefreshState(for: scope).lastCheck != nil,
            runID: runID
        )
        #endif

        LoggingService.shared.info(
            "Background refresh starting (Invidious account) | scope: \(scope) | channels with notifications: \(notifiableChannelIDs.count)",
            category: .notifications
        )

        guard !notifiableChannelIDs.isEmpty else {
            LoggingService.shared.debug("No channels with notifications enabled", category: .notifications)
            advanceBaseline(for: scope, using: appEnvironment.settingsManager)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:noEnabledChannels", videoCount: 0, runID: runID)
            #endif
            return true
        }

        LoggingService.shared.debug("Fetching feed from Invidious: \(invidiousInstance.url)", category: .notifications)

        let requestStartedAt = Date()
        do {
            // Fetch the Invidious feed - fetch enough to cover recent videos from notifiable channels
            // Use a reasonable limit since we're filtering client-side
            let feedResponse = try await appEnvironment.invidiousAPI.feed(
                instance: invidiousInstance,
                sid: sid,
                page: 1,
                maxResults: 100
            )

            LoggingService.shared.debug("API returned \(feedResponse.videos.count) total videos", category: .notifications)

            let videos = feedResponse.videos
                .filter { notifiableChannelIDs.contains($0.author.id) }
                .map { (video: $0, channelName: $0.author.name) }
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "success", videoCount: videos.count, runID: runID)
            #endif
            await processFetchedVideos(videos, requestStartedAt: requestStartedAt, scope: scope, runID: runID)
            return true
        } catch is CancellationError {
            LoggingService.shared.debug("Background refresh cancelled (Invidious account)", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "cancelled", runID: runID)
            #endif
            return false
        } catch {
            LoggingService.shared.logNotificationError("Background refresh failed (Invidious account)", error: error)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "error:\(String(describing: type(of: error)))", runID: runID)
            #endif
            return false
        }
    }

    // MARK: - Piped Account Refresh

    /// Performs background refresh for Piped subscription account.
    /// Fetches the Piped feed and filters to channels with notifications enabled.
    private func performPipedAccountRefresh(
        account: SubscriptionAccount,
        scope: String,
        runID: UUID
    ) async -> Bool {
        guard let appEnvironment else { return false }

        guard let instanceID = account.instanceID,
              let pipedInstance = appEnvironment.instancesManager.instances.first(where: {
                  $0.id == instanceID && $0.type == .piped && $0.isEnabled
              }),
              let authToken = appEnvironment.pipedCredentialsManager.credential(for: pipedInstance) else {
            LoggingService.shared.debug("Background refresh requires authenticated Piped instance", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "configurationError:pipedAuthentication", runID: runID)
            #endif
            return false
        }

        // Get channel IDs with notifications enabled from ChannelNotificationSettings
        let notifiableChannelIDs = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())
        #if DEBUG
        NotificationPipelineDiagnostic.shared.recordEnabledChannels(notifiableChannelIDs.count, runID: runID)
        NotificationPipelineDiagnostic.shared.recordBaseline(
            appEnvironment.settingsManager.notificationRefreshState(for: scope).lastCheck != nil,
            runID: runID
        )
        #endif

        LoggingService.shared.info(
            "Background refresh starting (Piped account) | scope: \(scope) | channels with notifications: \(notifiableChannelIDs.count)",
            category: .notifications
        )

        guard !notifiableChannelIDs.isEmpty else {
            LoggingService.shared.debug("No channels with notifications enabled", category: .notifications)
            advanceBaseline(for: scope, using: appEnvironment.settingsManager)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "skipped:noEnabledChannels", videoCount: 0, runID: runID)
            #endif
            return true
        }

        LoggingService.shared.debug("Fetching feed from Piped: \(pipedInstance.url)", category: .notifications)

        let requestStartedAt = Date()
        do {
            // Fetch the Piped feed
            let pipedAPI = PipedAPI(httpClient: appEnvironment.httpClient)
            let feedVideos = try await pipedAPI.feed(instance: pipedInstance, authToken: authToken)

            LoggingService.shared.debug("API returned \(feedVideos.count) total videos", category: .notifications)

            let videos = feedVideos
                .filter { notifiableChannelIDs.contains($0.author.id) }
                .map { (video: $0, channelName: $0.author.name) }
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "success", videoCount: videos.count, runID: runID)
            #endif
            await processFetchedVideos(videos, requestStartedAt: requestStartedAt, scope: scope, runID: runID)
            return true
        } catch is CancellationError {
            LoggingService.shared.debug("Background refresh cancelled (Piped account)", category: .notifications)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "cancelled", runID: runID)
            #endif
            return false
        } catch {
            LoggingService.shared.logNotificationError("Background refresh failed (Piped account)", error: error)
            #if DEBUG
            NotificationPipelineDiagnostic.shared.recordFeed(result: "error:\(String(describing: type(of: error)))", runID: runID)
            #endif
            return false
        }
    }

    // MARK: - Transaction Processing

    private func advanceBaseline(for scope: String, using settingsManager: SettingsManager) {
        var state = settingsManager.notificationRefreshState(for: scope)
        state.lastCheck = Date()
        settingsManager.setNotificationRefreshState(state, for: scope)
    }

    /// Plans, submits, then commits a refresh. Only videos accepted by the
    /// notification center (plus permanently ignored videos) enter the ledger.
    private func processFetchedVideos(
        _ fetchedVideos: [(video: Video, channelName: String)],
        requestStartedAt: Date,
        scope: String,
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
            submissionAccepted = await notificationManager.sendNotification(for: videosToNotify, diagnosticRunID: runID)
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

private enum BackgroundFeedRefreshError: LocalizedError {
    case incompleteYatteeServerResponse

    var errorDescription: String? {
        switch self {
        case .incompleteYatteeServerResponse:
            return "Yattee Server feed remained incomplete within the background refresh budget"
        }
    }
}
