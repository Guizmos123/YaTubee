//
//  SubscriptionFeedCache.swift
//  Yattee
//
//  Subscription feed cache with disk persistence.
//  Builds the main feed from local subscriptions using the selected local feed source.
//

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// State of feed loading.
enum FeedLoadState: Equatable {
    case idle
    case loading
    case loadingMore
    case ready
    case partiallyLoaded(readyCount: Int, pendingCount: Int, errorCount: Int)
    case error(FeedLoadError)

    /// Specific error types for feed loading.
    enum FeedLoadError: Equatable {
        case yatteeServerRequired
        case compatibleSourceRequired
        case notAuthenticated
        case networkError(String)
    }
}

/// Resolves Yattee Server snapshots without allowing an incomplete response to
/// replace the last complete feed.
enum YatteeServerFeedSnapshot {
    static let maximumVideoCount = 100

    static func isComplete(
        _ response: StatelessFeedResponse,
        expectedChannelCount: Int
    ) -> Bool {
        guard response.isReady,
              let readyCount = response.readyCount,
              let pendingCount = response.pendingCount,
              let errorCount = response.errorCount else {
            return false
        }

        return readyCount == expectedChannelCount
            && pendingCount == 0
            && errorCount == 0
    }

    static func videos(
        from response: StatelessFeedResponse,
        preserving cachedVideos: [Video],
        expectedChannelCount: Int
    ) -> [Video] {
        let receivedVideos = response.toVideos()
        guard !isComplete(response, expectedChannelCount: expectedChannelCount) else {
            return receivedVideos
        }

        return mergePartial(receivedVideos, with: cachedVideos)
    }

    private static func mergePartial(_ receivedVideos: [Video], with cachedVideos: [Video]) -> [Video] {
        var seen = Set<VideoID>()
        let deduplicated = (receivedVideos + cachedVideos).filter { seen.insert($0.id).inserted }

        return Array(
            deduplicated.enumerated().sorted { lhs, rhs in
                let lhsDate = lhs.element.publishedAt ?? .distantPast
                let rhsDate = rhs.element.publishedAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
            }
            .prefix(maximumVideoCount)
            .map(\.element)
        )
    }
}

/// Runs at most one feed refresh operation at a time. Concurrent callers join
/// the active task without owning or cancelling it.
@MainActor
final class FeedRefreshSingleFlight {
    private var activeTask: Task<Void, Never>?
    private var activeGeneration = 0

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let activeTask {
            await activeTask.value
            return
        }

        activeGeneration += 1
        let generation = activeGeneration
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finish(generation: generation)
        }
        activeTask = task

        await task.value
    }

    private func finish(generation: Int) {
        if activeGeneration == generation {
            activeTask = nil
        }
    }
}

/// Subscription feed cache with disk persistence.
/// Builds the main feed exclusively from local SwiftData subscriptions.
/// Yattee Server and public Invidious are interchangeable aggregation backends.
@MainActor
@Observable
final class SubscriptionFeedCache {
    static let shared = SubscriptionFeedCache()

    var videos: [Video] = []
    var lastUpdated: Date?
    var isLoading = false
    var loadingProgress: (loaded: Int, total: Int)?
    var hasLoadedOnce = false

    /// Last completed diagnostic cycle for the active source and instance.
    private(set) var syncSnapshot: SubscriptionSyncSnapshot?

    /// State of feed loading.
    var feedLoadState: FeedLoadState = .idle

    /// Whether more pages are available from Invidious feed (for infinite scroll).
    var hasMorePages = false

    /// Whether the disk cache has been loaded.
    private var diskCacheLoaded = false

    /// Identifies the account/backend that owns the in-memory and disk snapshot.
    private var cacheScopeKey: String?

    /// Current page for Invidious feed pagination (1-based).
    private var currentPage = 1

    /// Active polling task for feed status (can be cancelled).
    private var pollingTask: Task<Void, Never>?

    /// Whether app is in foreground (polling only allowed in foreground).
    private var isAppInForeground = true

    /// Owns the lifetime of the current refresh independently of its callers.
    private let refreshSingleFlight = FeedRefreshSingleFlight()

    private init() {
        setupLifecycleObservers()
    }

    // MARK: - Lifecycle

    /// Sets up observers to detect when app goes to background.
    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleAppBackgrounded()
            }
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleAppBackgrounded()
            }
        }
        #endif
    }

    /// Handles app going to background - cancels any active polling.
    private func handleAppBackgrounded() {
        isAppInForeground = false
        cancelPolling()
    }

    /// Cancels any active feed status polling.
    func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Cache Validity

    /// Returns true if the cache is valid based on the configured validity duration.
    /// Uses the setting from SettingsManager (default 30 minutes).
    func isCacheValid(using settingsManager: SettingsManager?) -> Bool {
        guard let lastUpdated, !videos.isEmpty else { return false }
        let validitySeconds = settingsManager?.feedCacheValiditySeconds
            ?? TimeInterval(SettingsManager.defaultFeedCacheValidityMinutes * 60)
        return Date().timeIntervalSince(lastUpdated) < validitySeconds
    }

    // MARK: - Disk Cache

    /// Loads cached data from disk if not already loaded.
    /// Call this early (e.g., on app launch) to populate the feed quickly.
    func loadFromDiskIfNeeded(using appEnvironment: AppEnvironment) async {
        let expectedScope = cacheScope(using: appEnvironment)
        guard !diskCacheLoaded else {
            if cacheScopeKey != expectedScope {
                await activateCacheScope(expectedScope)
            }
            LoggingService.shared.debug("Feed cache already loaded from disk, skipping", category: .general)
            return
        }
        diskCacheLoaded = true

        cacheScopeKey = expectedScope

        let scopedCache = await FeedCache.shared.load(scopeKey: expectedScope)
        let legacyCache = scopedCache == nil ? await FeedCache.shared.load() : nil
        if let cacheData = scopedCache ?? legacyCache,
           FeedCacheScopePolicy.accepts(
               storedScope: cacheData.scopeKey,
               expectedScope: expectedScope,
               allowsLegacyUnscopedCache: canAdoptLegacyCache(for: expectedScope)
           ) {
            videos = videosForActiveSubscriptions(
                cacheData.videos,
                scope: expectedScope,
                dataManager: appEnvironment.dataManager
            )
            lastUpdated = cacheData.lastUpdated
            syncSnapshot = cacheData.syncSnapshot.flatMap {
                $0.cacheScopeKey == expectedScope ? $0 : nil
            }
            hasLoadedOnce = true
            let videoCount = videos.count
            let oldestVideoDate = videos.compactMap { $0.publishedAt }.min()
            let age = Date().timeIntervalSince(cacheData.lastUpdated)
            LoggingService.shared.debug(
                "Loaded feed cache from disk: \(videoCount) videos, lastUpdated: \(cacheData.lastUpdated) (\(Int(age))s ago), oldest video: \(oldestVideoDate?.description ?? "none")",
                category: .general
            )
            if cacheData.scopeKey == nil {
                await FeedCache.shared.save(
                    videos: cacheData.videos,
                    lastUpdated: cacheData.lastUpdated,
                    scopeKey: expectedScope,
                    syncSnapshot: syncSnapshot
                )
            }
        } else {
            videos = []
            lastUpdated = nil
            syncSnapshot = nil
            hasLoadedOnce = false
            LoggingService.shared.debug("No feed cache found for active scope", category: .general)
        }
    }

    func clear() {
        cancelPolling()
        videos = []
        lastUpdated = nil
        syncSnapshot = nil
        cacheScopeKey = nil
        hasMorePages = false
        currentPage = 1
        Task {
            await FeedCache.shared.clear()
        }
    }

    func invalidate() {
        lastUpdated = nil
        Task {
            await FeedCache.shared.invalidate()
        }
    }

    /// Saves the current feed state to disk.
    private func saveToDisk() {
        guard let lastUpdated else {
            LoggingService.shared.warning("saveToDisk called but lastUpdated is nil", category: .general)
            return
        }
        LoggingService.shared.debug("Saving feed cache to disk: \(videos.count) videos, lastUpdated: \(lastUpdated)", category: .general)
        Task {
            await FeedCache.shared.save(
                videos: videos,
                lastUpdated: lastUpdated,
                scopeKey: cacheScopeKey,
                syncSnapshot: syncSnapshot
            )
        }
    }

    /// Updates the cache with new videos and persists to disk.
    func update(videos: [Video]) {
        let oldCount = self.videos.count
        let oldDate = self.lastUpdated
        self.videos = videos
        self.lastUpdated = Date()
        self.hasLoadedOnce = true
        LoggingService.shared.info(
            "Feed cache updated: \(oldCount) -> \(videos.count) videos, lastUpdated changed from \(oldDate?.description ?? "nil") to \(Date())",
            category: .general
        )
        saveToDisk()
        TopShelfSnapshotWriter.writeFeed()
    }

    /// Stores an incomplete Yattee Server snapshot without making the cache
    /// appear freshly and completely synchronized.
    private func updatePartialYatteeServerSnapshot(videos: [Video]) {
        self.videos = videos
        self.lastUpdated = lastUpdated ?? .distantPast
        self.hasLoadedOnce = true
        saveToDisk()
        TopShelfSnapshotWriter.writeFeed()
    }

    /// Stores an incomplete local Invidious snapshot without marking it fresh.
    private func updatePartialInvidiousSnapshot(videos: [Video]) {
        self.videos = videos
        self.lastUpdated = lastUpdated ?? .distantPast
        self.hasLoadedOnce = true
        saveToDisk()
        TopShelfSnapshotWriter.writeFeed()
    }

    /// Appends videos to the existing cache (for pagination).
    private func appendVideos(_ newVideos: [Video]) {
        let existingIDs = Set(videos.map { $0.id })
        let uniqueNewVideos = newVideos.filter { !existingIDs.contains($0.id) }
        videos.append(contentsOf: uniqueNewVideos)
        lastUpdated = Date()
        LoggingService.shared.debug(
            "Appended \(uniqueNewVideos.count) videos to feed cache (total: \(videos.count))",
            category: .general
        )
        saveToDisk()
    }

    // MARK: - Feed Context Change Handling

    /// Releases the active snapshot when a setting affecting the feed context changes.
    func handleAccountChange() {
        LoggingService.shared.info("Feed context changed, releasing active feed snapshot", category: .general)
        cancelPolling()
        videos = []
        lastUpdated = nil
        cacheScopeKey = nil
        syncSnapshot = nil
        diskCacheLoaded = false
        hasLoadedOnce = false
        hasMorePages = false
        currentPage = 1
        feedLoadState = .idle
    }

    // MARK: - Refresh

    /// Refreshes the feed from network.
    /// Concurrent callers await the same unstructured task. Cancelling one
    /// caller therefore does not cancel the shared network operation.
    func refresh(using appEnvironment: AppEnvironment) async {
        await refreshSingleFlight.run { [self] in
            repeat {
                let requestedScope = cacheScope(using: appEnvironment)
                LoggingService.shared.debug("Starting feed refresh from local subscriptions", category: .general)
                await activateCacheScope(requestedScope)
                await refreshLocalAccount(using: appEnvironment)

                // A source changed while the request was running. Serialize one
                // refresh for the newly selected scope instead of letting the
                // obsolete result become the active snapshot.
                if cacheScope(using: appEnvironment) == requestedScope { break }
            } while !Task.isCancelled
        }
    }

    /// Refreshes the local subscription feed using the selected aggregation backend.
    private func refreshLocalAccount(using appEnvironment: AppEnvironment) async {
        switch LocalFeedSource.resolve(
            from: appEnvironment.instancesManager.instances,
            preference: appEnvironment.settingsManager.localFeedSourcePreference
        ) {
        case .yatteeServer(let serverInstance):
            await activateCacheScope("local:yatteeServer:\(serverInstance.id.uuidString)")
            LoggingService.shared.info("Refreshing feed using Yattee Server: \(serverInstance.url.absoluteString)", category: .general)
            await refreshFromStatelessServer(instance: serverInstance, using: appEnvironment)

        case .invidious(let instance):
            await activateCacheScope("local:invidious:\(instance.id.uuidString)")
            await refreshLocalAccountFromInvidious(instance: instance, using: appEnvironment)

        case .unavailable:
            LoggingService.shared.warning("The selected local feed source is unavailable", category: .general)
            feedLoadState = .error(.compatibleSourceRequired)
            isLoading = false
        }
    }

    private func refreshLocalAccountFromInvidious(
        instance: Instance,
        using appEnvironment: AppEnvironment
    ) async {
        let subscriptions = appEnvironment.dataManager.subscriptions()
        let compatibleSubscriptions = subscriptions.compactMap { subscription -> InvidiousLocalFeedSubscription? in
            guard case .global(let provider) = subscription.contentSource,
                  provider == ContentSource.youtubeProvider else {
                return nil
            }
            return InvidiousLocalFeedSubscription(
                channelID: subscription.channelID,
                channelName: subscription.name
            )
        }

        let refreshStartedAt = Date()
        isLoading = true
        let previousLoadState = feedLoadState
        feedLoadState = .loading
        loadingProgress = nil
        hasMorePages = false
        let compatibleChannelIDs = Set(compatibleSubscriptions.map(\.channelID))
        let cachedVideos = videos.filter { compatibleChannelIDs.contains($0.author.id) }

        do {
            let aggregator = InvidiousLocalFeedAggregator(videoProvider: appEnvironment.contentService)
            let aggregation = try await aggregator.aggregate(
                subscriptions: compatibleSubscriptions,
                instance: instance,
                cachedVideos: cachedVideos
            )
            let resolvedVideos = InvidiousLocalFeedSnapshot.videos(
                from: aggregation,
                preserving: cachedVideos
            )
            await registerNovelties(
                aggregation.videos,
                baselineSupplement: cachedVideos,
                scope: FeedNoveltyScope.localFeed(invidious: instance),
                observedAt: refreshStartedAt,
                isCompleteSnapshot: aggregation.status == .complete,
                settings: appEnvironment.settingsManager
            )
            await storeSyncSnapshot(
                invidiousSnapshot(
                    aggregation: aggregation,
                    instance: instance,
                    refreshStartedAt: refreshStartedAt,
                    refreshFinishedAt: Date()
                )
            )

            if aggregation.status == .complete {
                update(videos: resolvedVideos)
                feedLoadState = .ready
            } else if aggregation.successfulChannelCount > 0 {
                updatePartialInvidiousSnapshot(videos: resolvedVideos)
                feedLoadState = .partiallyLoaded(
                    readyCount: aggregation.successfulChannelCount,
                    pendingCount: 0,
                    errorCount: aggregation.failedChannelCount
                )
            } else {
                feedLoadState = .error(.networkError("All Invidious channel requests failed"))
            }

            if aggregation.successfulChannelCount > 0 || compatibleSubscriptions.isEmpty {
                appEnvironment.dataManager.updateLastVideoPublishedDates(from: aggregation.videos)
                prefetchDeArrow(for: aggregation.videos, using: appEnvironment)
            }
        } catch is CancellationError {
            LoggingService.shared.debug("Local Invidious feed aggregation cancelled", category: .general)
            feedLoadState = previousLoadState
        } catch {
            LoggingService.shared.error(
                "Local Invidious feed aggregation failed: \(error.localizedDescription)",
                category: .general
            )
            feedLoadState = .error(.networkError(error.localizedDescription))
            await storeSyncSnapshot(
                invidiousFailureSnapshot(
                    subscriptions: compatibleSubscriptions,
                    instance: instance,
                    refreshStartedAt: refreshStartedAt,
                    refreshFinishedAt: Date(),
                    error: error
                )
            )
        }

        isLoading = false
    }

    /// Refreshes feed for Invidious account using authenticated feed endpoint.
    private func refreshInvidiousAccount(using appEnvironment: AppEnvironment) async {
        guard let (instance, sid) = getInvidiousAuth(using: appEnvironment) else {
            LoggingService.shared.warning("Invidious account not authenticated", category: .general)
            feedLoadState = .error(.notAuthenticated)
            isLoading = false
            return
        }

        LoggingService.shared.info("Refreshing feed using Invidious account: \(instance.url.absoluteString)", category: .general)
        
        // Reset pagination for fresh refresh
        currentPage = 1
        
        await refreshFromInvidiousFeed(instance: instance, sid: sid, using: appEnvironment)
    }

    /// Gets the authenticated Invidious instance and session ID.
    private func getInvidiousAuth(using appEnvironment: AppEnvironment) -> (Instance, String)? {
        // Get the instance ID from subscription account settings
        let account = appEnvironment.settingsManager.subscriptionAccount
        
        let instance: Instance?
        if let instanceID = account.instanceID {
            // Use the specific instance from account settings
            instance = appEnvironment.instancesManager.instances.first { $0.id == instanceID }
        } else {
            // Fall back to first enabled Invidious instance
            instance = appEnvironment.instancesManager.instances.first {
                $0.type == .invidious && $0.isEnabled
            }
        }
        
        guard let instance else {
            LoggingService.shared.debug("No Invidious instance found for subscription account", category: .general)
            return nil
        }
        
        guard let sid = appEnvironment.invidiousCredentialsManager.sid(for: instance) else {
            LoggingService.shared.debug("No session ID found for Invidious instance: \(instance.id)", category: .general)
            return nil
        }
        
        return (instance, sid)
    }

    // MARK: - Piped Account

    /// Refreshes feed for Piped account using authenticated feed endpoint.
    private func refreshPipedAccount(using appEnvironment: AppEnvironment) async {
        guard let (instance, authToken) = getPipedAuth(using: appEnvironment) else {
            LoggingService.shared.warning("Piped account not authenticated", category: .general)
            feedLoadState = .error(.notAuthenticated)
            isLoading = false
            return
        }

        LoggingService.shared.info("Refreshing feed using Piped account: \(instance.url.absoluteString)", category: .general)

        isLoading = true
        feedLoadState = .loading
        loadingProgress = nil
        hasMorePages = false // Piped doesn't support pagination
        let requestStartedAt = Date()
        let cachedVideos = videos

        do {
            let pipedAPI = PipedAPI(httpClient: appEnvironment.httpClient)
            let feedVideos = try await pipedAPI.feed(instance: instance, authToken: authToken)

            LoggingService.shared.info("Piped feed: Received \(feedVideos.count) videos", category: .general)

            await registerNovelties(
                feedVideos,
                baselineSupplement: cachedVideos,
                scope: FeedNoveltyScope.key(
                    for: appEnvironment.settingsManager.subscriptionAccount,
                    credential: authToken
                ),
                observedAt: requestStartedAt,
                isCompleteSnapshot: true,
                settings: appEnvironment.settingsManager
            )
            update(videos: feedVideos)
            appEnvironment.dataManager.updateLastVideoPublishedDates(from: feedVideos)
            prefetchDeArrow(for: feedVideos, using: appEnvironment)
            feedLoadState = .ready
        } catch {
            LoggingService.shared.error("Failed to fetch Piped feed: \(error.localizedDescription)", category: .general)
            feedLoadState = .error(.networkError(error.localizedDescription))
        }

        isLoading = false
    }

    /// Gets the authenticated Piped instance and auth token.
    private func getPipedAuth(using appEnvironment: AppEnvironment) -> (Instance, String)? {
        let account = appEnvironment.settingsManager.subscriptionAccount

        guard let instanceID = account.instanceID,
              let instance = appEnvironment.instancesManager.instances.first(where: { $0.id == instanceID }),
              let authToken = appEnvironment.pipedCredentialsManager.credential(for: instance) else {
            LoggingService.shared.debug("No authenticated Piped instance found for subscription account", category: .general)
            return nil
        }

        return (instance, authToken)
    }

    // MARK: - Invidious Feed

    /// Refreshes feed from authenticated Invidious feed API.
    private func refreshFromInvidiousFeed(
        instance: Instance,
        sid: String,
        using appEnvironment: AppEnvironment
    ) async {
        isLoading = true
        feedLoadState = .loading
        loadingProgress = nil
        let requestStartedAt = Date()
        let cachedVideos = videos

        do {
            let response = try await appEnvironment.invidiousAPI.feed(
                instance: instance,
                sid: sid,
                page: currentPage,
                maxResults: 50
            )

            let feedVideos = try await InvidiousFeedShortsClassifier.shared.excludingConfirmedShorts(
                from: response.videos,
                instance: instance,
                provider: appEnvironment.contentService
            )
            LoggingService.shared.info(
                "Invidious feed: Received \(feedVideos.count) videos (page \(currentPage))",
                category: .general
            )

            // For first page, replace all videos. For subsequent pages, this shouldn't be called.
            await registerNovelties(
                feedVideos,
                baselineSupplement: cachedVideos,
                scope: FeedNoveltyScope.key(
                    for: appEnvironment.settingsManager.subscriptionAccount,
                    credential: sid
                ),
                observedAt: requestStartedAt,
                isCompleteSnapshot: !response.hasMore,
                settings: appEnvironment.settingsManager
            )
            update(videos: feedVideos)
            appEnvironment.dataManager.updateLastVideoPublishedDates(from: feedVideos)

            // Update pagination state
            hasMorePages = response.hasMore
            currentPage = 1

            // Prefetch DeArrow branding for YouTube videos
            prefetchDeArrow(for: feedVideos, using: appEnvironment)

            feedLoadState = .ready
        } catch {
            LoggingService.shared.error(
                "Failed to fetch Invidious feed: \(error.localizedDescription)",
                category: .general
            )
            feedLoadState = .error(.networkError(error.localizedDescription))
        }

        isLoading = false
    }

    /// Loads the next page of Invidious feed (for infinite scroll).
    func loadMoreInvidiousFeed(using appEnvironment: AppEnvironment) async {
        guard !isLoading else { return }
        guard hasMorePages else { return }
        guard appEnvironment.settingsManager.subscriptionAccount.type == .invidious else { return }

        guard let (instance, sid) = getInvidiousAuth(using: appEnvironment) else {
            return
        }

        isLoading = true
        feedLoadState = .loadingMore

        let nextPage = currentPage + 1
        let requestStartedAt = Date()
        let cachedVideos = videos

        do {
            let response = try await appEnvironment.invidiousAPI.feed(
                instance: instance,
                sid: sid,
                page: nextPage,
                maxResults: 50
            )

            let feedVideos = try await InvidiousFeedShortsClassifier.shared.excludingConfirmedShorts(
                from: response.videos,
                instance: instance,
                provider: appEnvironment.contentService
            )
            LoggingService.shared.info(
                "Invidious feed: Loaded page \(nextPage), received \(feedVideos.count) videos",
                category: .general
            )

            // Append new videos to existing cache
            await registerNovelties(
                feedVideos,
                baselineSupplement: cachedVideos,
                scope: FeedNoveltyScope.key(
                    for: appEnvironment.settingsManager.subscriptionAccount,
                    credential: sid
                ),
                observedAt: requestStartedAt,
                isCompleteSnapshot: !response.hasMore,
                settings: appEnvironment.settingsManager
            )
            appendVideos(feedVideos)

            // Update pagination state
            hasMorePages = response.hasMore
            currentPage = nextPage

            // Prefetch DeArrow branding for new videos
            prefetchDeArrow(for: feedVideos, using: appEnvironment)

            feedLoadState = .ready
        } catch {
            LoggingService.shared.error(
                "Failed to load more Invidious feed: \(error.localizedDescription)",
                category: .general
            )
            // Don't show error state for pagination failures, just stop loading
            feedLoadState = .ready
        }

        isLoading = false
    }

    // MARK: - Yattee Server Feed

    /// Refreshes feed from Yattee Server's stateless POST feed API.
    private func refreshFromStatelessServer(instance: Instance, using appEnvironment: AppEnvironment) async {
        let subscriptions = appEnvironment.dataManager.subscriptions()
        let requestStartedAt = Date()
        LoggingService.shared.debug("refreshFromStatelessServer: Found \(subscriptions.count) subscriptions", category: .general)
        guard !subscriptions.isEmpty else {
            await registerNovelties(
                [],
                baselineSupplement: videos,
                scope: FeedNoveltyScope.localFeed(yatteeServer: instance),
                observedAt: Date(),
                isCompleteSnapshot: true,
                settings: appEnvironment.settingsManager
            )
            videos = []
            isLoading = false
            hasLoadedOnce = true
            feedLoadState = .ready
            await storeSyncSnapshot(
                unknownYatteeServerSnapshot(
                    instance: instance,
                    requestedChannels: [],
                    refreshStartedAt: requestStartedAt,
                    refreshFinishedAt: Date(),
                    observationError: nil
                )
            )
            LoggingService.shared.debug("refreshFromStatelessServer: No subscriptions, clearing feed", category: .general)
            return
        }

        isLoading = true
        feedLoadState = .loading
        loadingProgress = nil

        let channelRequests = subscriptions.map { subscription in
            StatelessChannelRequest(
                channelId: subscription.channelID,
                site: subscription.site,
                channelName: subscription.name,
                channelUrl: subscription.channelURLString,
                avatarUrl: subscription.avatarURLString
            )
        }

        do {
            let cachedVideos = videos
            let httpClient = appEnvironment.httpClientFactory.createClient(for: instance)
            if let authHeader = appEnvironment.basicAuthCredentialsManager.basicAuthHeader(for: instance) {
                await httpClient.setDefaultHeaders(["Authorization": authHeader])
            }
            let yatteeServerAPI = YatteeServerAPI(httpClient: httpClient)
            LoggingService.shared.debug("refreshFromStatelessServer: Calling postFeed for \(channelRequests.count) channels", category: .general)
            let response = try await yatteeServerAPI.postFeed(
                channels: channelRequests,
                limit: 100,
                offset: 0,
                instance: instance
            )

            let serverVideos = response.toVideos()
            LoggingService.shared.info(
                "refreshFromStatelessServer: Received \(serverVideos.count) videos from server, status: \(response.status), ready: \(response.isReady)",
                category: .general
            )
            let isComplete = await applyYatteeServerResponse(
                response,
                cachedVideos: cachedVideos,
                baselineSupplement: cachedVideos,
                expectedChannelCount: channelRequests.count,
                requestStartedAt: requestStartedAt,
                instance: instance,
                appEnvironment: appEnvironment
            )

            if isComplete {
                isLoading = false
            } else if response.isReady {
                // The server finished processing, but missing/error counts mean
                // this is not a complete successful snapshot. Do not poll again.
                isLoading = false
            } else {
                // Show partial results and poll for completion
                feedLoadState = .partiallyLoaded(
                    readyCount: response.readyCount ?? 0,
                    pendingCount: response.pendingCount ?? 0,
                    errorCount: response.errorCount ?? 0
                )
                // Reset foreground flag since this is a user-initiated action
                isAppInForeground = true
                pollingTask = Task {
                    await pollUntilReady(
                        channels: channelRequests,
                        instance: instance,
                        baselineSupplement: cachedVideos,
                        requestStartedAt: requestStartedAt,
                        appEnvironment: appEnvironment
                    )
                }
                await pollingTask?.value
                pollingTask = nil
            }

            await captureYatteeServerSyncSnapshot(
                api: yatteeServerAPI,
                instance: instance,
                requestedChannels: channelRequests,
                refreshStartedAt: requestStartedAt
            )
        } catch {
            LoggingService.shared.error(
                "Yattee Server feed failed: \(error.localizedDescription)",
                category: .general
            )
            feedLoadState = .error(.networkError(error.localizedDescription))
            isLoading = false
            await storeSyncSnapshot(
                unknownYatteeServerSnapshot(
                    instance: instance,
                    requestedChannels: channelRequests,
                    refreshStartedAt: requestStartedAt,
                    refreshFinishedAt: Date(),
                    observationError: error.localizedDescription
                )
            )
        }
    }

    /// Polls server until all channels are cached, then refreshes.
    /// Stops polling after max retries, consecutive errors, or when app is backgrounded.
    private func pollUntilReady(
        channels: [StatelessChannelRequest],
        instance: Instance,
        baselineSupplement: [Video],
        requestStartedAt: Date,
        appEnvironment: AppEnvironment
    ) async {
        let statusChannels = channels.map {
            StatelessChannelStatusRequest(channelId: $0.channelId, site: $0.site)
        }
        let httpClient = appEnvironment.httpClientFactory.createClient(for: instance)
        if let authHeader = appEnvironment.basicAuthCredentialsManager.basicAuthHeader(for: instance) {
            await httpClient.setDefaultHeaders(["Authorization": authHeader])
        }
        let yatteeServerAPI = YatteeServerAPI(httpClient: httpClient)

        let maxRetries = 5
        var retryCount = 0
        let maxConsecutiveErrors = 3
        var consecutiveErrors = 0

        while retryCount < maxRetries {
            // Check for cancellation before sleep
            guard !Task.isCancelled else {
                LoggingService.shared.debug("Feed status polling cancelled", category: .general)
                break
            }

            // Check if app is still in foreground
            guard isAppInForeground else {
                LoggingService.shared.debug("Feed status polling stopped - app backgrounded", category: .general)
                break
            }

            try? await Task.sleep(for: .seconds(5))

            // Check again after sleep
            guard !Task.isCancelled, isAppInForeground else {
                LoggingService.shared.debug("Feed status polling cancelled during sleep", category: .general)
                break
            }

            retryCount += 1

            do {
                let status = try await yatteeServerAPI.postFeedStatus(
                    channels: statusChannels,
                    instance: instance
                )
                consecutiveErrors = 0 // Reset on success

                if status.isReady {
                    // Fetch full feed now that all channels are cached
                    do {
                        let response = try await yatteeServerAPI.postFeed(
                            channels: channels,
                            limit: 100,
                            offset: 0,
                            instance: instance
                        )
                        _ = await applyYatteeServerResponse(
                            response,
                            cachedVideos: videos,
                            baselineSupplement: baselineSupplement,
                            expectedChannelCount: channels.count,
                            requestStartedAt: requestStartedAt,
                            instance: instance,
                            appEnvironment: appEnvironment
                        )
                    } catch {
                        LoggingService.shared.error(
                            "Yattee Server final feed fetch failed: \(error.localizedDescription)",
                            category: .general
                        )
                        feedLoadState = .error(.networkError(error.localizedDescription))
                    }
                    isLoading = false
                    return
                }

                // Update progress UI
                feedLoadState = .partiallyLoaded(
                    readyCount: status.readyCount,
                    pendingCount: status.pendingCount,
                    errorCount: status.errorCount
                )
            } catch {
                consecutiveErrors += 1
                LoggingService.shared.debug(
                    "Feed status poll error (\(consecutiveErrors)/\(maxConsecutiveErrors)): \(error.localizedDescription)",
                    category: .general
                )

                if consecutiveErrors >= maxConsecutiveErrors {
                    LoggingService.shared.warning(
                        "Feed status polling stopped after \(maxConsecutiveErrors) consecutive errors",
                        category: .general
                    )
                    break
                }
            }
        }

        if retryCount >= maxRetries {
            LoggingService.shared.warning(
                "Feed status polling timed out after \(retryCount) attempts",
                category: .general
            )
        }

        // Keep the last partial/error state and its merged snapshot. A timeout,
        // cancellation, or background transition is not a complete refresh.
        isLoading = false
    }

    // MARK: - Cache Warming

    /// Warms the cache if expired.
    func warmIfNeeded(using appEnvironment: AppEnvironment) {
        guard !isLoading else { return }

        Task { @MainActor in
            // Load disk cache first to get accurate lastUpdated timestamp
            await loadFromDiskIfNeeded(using: appEnvironment)

            guard !isCacheValid(using: appEnvironment.settingsManager) else { return }

            // Use the same routing logic as refresh()
            await refresh(using: appEnvironment)
        }
    }

    // MARK: - Helpers

    private func storeSyncSnapshot(_ snapshot: SubscriptionSyncSnapshot) async {
        syncSnapshot = snapshot
        await FeedCache.shared.save(
            videos: videos,
            lastUpdated: lastUpdated ?? .distantPast,
            scopeKey: cacheScopeKey,
            syncSnapshot: snapshot
        )
    }

    private func invidiousSnapshot(
        aggregation: InvidiousLocalFeedAggregation,
        instance: Instance,
        refreshStartedAt: Date,
        refreshFinishedAt: Date
    ) -> SubscriptionSyncSnapshot {
        let channels = aggregation.channelResults.map { result in
            SubscriptionSyncSnapshot.Channel(
                channelID: result.channelID,
                site: ContentSource.youtubeProvider,
                channelName: result.channelName,
                state: result.status == .success ? .success : .failure,
                errorDescription: result.errorDescription,
                lastRequestedAt: nil,
                lastFetchedAt: nil,
                requestCompletedAt: result.completedAt,
                videoCount: nil
            )
        }
        return SubscriptionSyncSnapshot(
            source: syncSource(kind: .invidious, instance: instance),
            refreshStartedAt: refreshStartedAt,
            refreshFinishedAt: refreshFinishedAt,
            channels: channels,
            serverInformationObservedAt: nil,
            observationError: nil
        )
    }

    private func invidiousFailureSnapshot(
        subscriptions: [InvidiousLocalFeedSubscription],
        instance: Instance,
        refreshStartedAt: Date,
        refreshFinishedAt: Date,
        error: Error
    ) -> SubscriptionSyncSnapshot {
        SubscriptionSyncSnapshot(
            source: syncSource(kind: .invidious, instance: instance),
            refreshStartedAt: refreshStartedAt,
            refreshFinishedAt: refreshFinishedAt,
            channels: subscriptions.map {
                SubscriptionSyncSnapshot.Channel(
                    channelID: $0.channelID,
                    site: ContentSource.youtubeProvider,
                    channelName: $0.channelName,
                    state: .unknown,
                    errorDescription: nil,
                    lastRequestedAt: nil,
                    lastFetchedAt: nil,
                    requestCompletedAt: nil,
                    videoCount: nil
                )
            },
            serverInformationObservedAt: nil,
            observationError: error.localizedDescription
        )
    }

    private func captureYatteeServerSyncSnapshot(
        api: YatteeServerAPI,
        instance: Instance,
        requestedChannels: [StatelessChannelRequest],
        refreshStartedAt: Date
    ) async {
        let refreshFinishedAt = Date()
        var feedFetchIntervalSeconds: TimeInterval?
        do {
            feedFetchIntervalSeconds = try await api.settings(instance: instance).feedFetchInterval
        } catch {
            LoggingService.shared.debug(
                "Failed to fetch Yattee Server collection settings: \(error.localizedDescription)",
                category: .general
            )
        }

        do {
            let watchedChannels = try await api.watchedChannels(instance: instance)
            let observedAt = Date()
            await storeSyncSnapshot(
                YatteeServerSyncClassification.snapshot(
                    source: syncSource(kind: .yatteeServer, instance: instance),
                    requestedChannels: requestedChannels,
                    watchedChannels: watchedChannels,
                    refreshStartedAt: refreshStartedAt,
                    refreshFinishedAt: refreshFinishedAt,
                    observedAt: observedAt,
                    serverFeedFetchIntervalSeconds: feedFetchIntervalSeconds
                )
            )
        } catch {
            LoggingService.shared.debug(
                "Failed to fetch Yattee Server channel sync details: \(error.localizedDescription)",
                category: .general
            )
            await storeSyncSnapshot(
                unknownYatteeServerSnapshot(
                    instance: instance,
                    requestedChannels: requestedChannels,
                    refreshStartedAt: refreshStartedAt,
                    refreshFinishedAt: refreshFinishedAt,
                    observationError: error.localizedDescription,
                    serverFeedFetchIntervalSeconds: feedFetchIntervalSeconds
                )
            )
        }
    }

    private func unknownYatteeServerSnapshot(
        instance: Instance,
        requestedChannels: [StatelessChannelRequest],
        refreshStartedAt: Date,
        refreshFinishedAt: Date,
        observationError: String?,
        serverFeedFetchIntervalSeconds: TimeInterval? = nil
    ) -> SubscriptionSyncSnapshot {
        let previousByKey = Dictionary(
            (syncSnapshot?.channels ?? []).map { (syncChannelKey(site: $0.site, channelID: $0.channelID), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let channels = requestedChannels.map { requested in
            let previous = previousByKey[syncChannelKey(site: requested.site, channelID: requested.channelId)]
            return SubscriptionSyncSnapshot.Channel(
                channelID: requested.channelId,
                site: requested.site,
                channelName: requested.channelName ?? previous?.channelName ?? requested.channelId,
                state: .unknown,
                errorDescription: nil,
                lastRequestedAt: previous?.lastRequestedAt,
                lastFetchedAt: previous?.lastFetchedAt,
                requestCompletedAt: nil,
                videoCount: previous?.videoCount
            )
        }
        return SubscriptionSyncSnapshot(
            source: syncSource(kind: .yatteeServer, instance: instance),
            refreshStartedAt: refreshStartedAt,
            refreshFinishedAt: refreshFinishedAt,
            channels: channels,
            serverInformationObservedAt: nil,
            observationError: observationError,
            serverFeedFetchIntervalSeconds: serverFeedFetchIntervalSeconds
        )
    }

    private func syncSource(
        kind: SubscriptionSyncSnapshot.Source.Kind,
        instance: Instance
    ) -> SubscriptionSyncSnapshot.Source {
        SubscriptionSyncSnapshot.Source(
            kind: kind,
            instanceID: instance.id,
            instanceURL: instance.url
        )
    }

    private func syncChannelKey(site: String, channelID: String) -> String {
        "\(site.lowercased())\u{1F}\(channelID)"
    }

    private func registerNovelties(
        _ videos: [Video],
        baselineSupplement: [Video],
        scope: FeedNoveltyScope,
        observedAt: Date,
        isCompleteSnapshot: Bool,
        settings: SettingsManager
    ) async {
        await FeedNoveltyRegistry.shared.ingest(
            videos: videos,
            baselineSupplement: baselineSupplement,
            scope: scope,
            observedAt: observedAt,
            isCompleteSnapshot: isCompleteSnapshot,
            includeShorts: settings.badgesIncludeShorts
        )
    }

    private func cacheScope(using appEnvironment: AppEnvironment) -> String {
        switch LocalFeedSource.resolve(
            from: appEnvironment.instancesManager.instances,
            preference: appEnvironment.settingsManager.localFeedSourcePreference
        ) {
            case .yatteeServer(let instance):
                return "local:yatteeServer:\(instance.id.uuidString)"
            case .invidious(let instance):
                return "local:invidious:\(instance.id.uuidString)"
            case .unavailable:
                return "local:unavailable"
            }
    }

    private func canAdoptLegacyCache(for scope: String) -> Bool {
        !scope.hasPrefix("local:invidious:")
    }

    private func videosForActiveSubscriptions(
        _ cachedVideos: [Video],
        scope: String,
        dataManager: DataManager
    ) -> [Video] {
        guard scope.hasPrefix("local:") else { return cachedVideos }
        let channelIDs = Set(dataManager.subscriptions().map(\.channelID))
        return cachedVideos.filter { channelIDs.contains($0.author.id) }
    }

    private func activateCacheScope(_ scope: String) async {
        guard cacheScopeKey != scope else { return }

        cancelPolling()
        videos = []
        lastUpdated = nil
        syncSnapshot = nil
        hasLoadedOnce = false
        hasMorePages = false
        currentPage = 1
        cacheScopeKey = scope
        diskCacheLoaded = true

        if let cacheData = await FeedCache.shared.load(scopeKey: scope), cacheData.scopeKey == scope {
            videos = cacheData.videos
            lastUpdated = cacheData.lastUpdated
            hasLoadedOnce = true
            syncSnapshot = cacheData.syncSnapshot.flatMap {
                $0.cacheScopeKey == scope ? $0 : nil
            }
        }
    }

    @discardableResult
    private func applyYatteeServerResponse(
        _ response: StatelessFeedResponse,
        cachedVideos: [Video],
        baselineSupplement: [Video],
        expectedChannelCount: Int,
        requestStartedAt: Date,
        instance: Instance,
        appEnvironment: AppEnvironment
    ) async -> Bool {
        let serverVideos = response.toVideos()
        let isComplete = YatteeServerFeedSnapshot.isComplete(
            response,
            expectedChannelCount: expectedChannelCount
        )
        let resolvedVideos = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: cachedVideos,
            expectedChannelCount: expectedChannelCount
        )

        await registerNovelties(
            serverVideos,
            baselineSupplement: baselineSupplement,
            scope: FeedNoveltyScope.localFeed(yatteeServer: instance),
            observedAt: requestStartedAt,
            isCompleteSnapshot: isComplete,
            settings: appEnvironment.settingsManager
        )

        if isComplete {
            update(videos: resolvedVideos)
            feedLoadState = .ready
        } else {
            updatePartialYatteeServerSnapshot(videos: resolvedVideos)
            feedLoadState = .partiallyLoaded(
                readyCount: response.readyCount ?? 0,
                pendingCount: response.pendingCount ?? 0,
                errorCount: response.errorCount ?? 0
            )
        }

        appEnvironment.dataManager.updateLastVideoPublishedDates(from: serverVideos)
        prefetchDeArrow(for: serverVideos, using: appEnvironment)
        return isComplete
    }

    /// Prefetches DeArrow branding for YouTube videos.
    private func prefetchDeArrow(for videos: [Video], using appEnvironment: AppEnvironment) {
        let youtubeIDs = videos.compactMap { video -> String? in
            if case .global = video.id.source { return video.id.videoID }
            return nil
        }
        appEnvironment.deArrowBrandingProvider.prefetch(videoIDs: youtubeIDs)
    }
}
