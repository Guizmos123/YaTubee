//
//  HomeInstanceCache.swift
//  Yattee
//
//  Home instance content cache with disk persistence.
//  Caches Popular and Trending content from instances for fast Home view loading.
//

import Foundation

/// Home instance content cache with disk persistence.
/// Loads cached content from disk on startup for instant display, then refreshes from network.
@MainActor
@Observable
final class HomeInstanceCache {
    static let shared = HomeInstanceCache()

    /// Cached videos by cache key (format: "instanceID_contentType[_lang_language]").
    private(set) var cache: [String: [Video]] = [:]
    
    /// Last updated timestamps by cache key.
    private(set) var lastUpdated: [String: Date] = [:]
    
    /// Whether the disk cache has been loaded.
    private var diskCacheLoaded = false

    /// Latest refresh generation by cache key, used to discard superseded responses.
    private var refreshGenerations: [String: Int] = [:]

    /// Active refresh generation by cache key, used to avoid duplicate requests.
    private var inFlightGenerations: [String: Int] = [:]

    private struct RefreshRequest: Sendable {
        let key: String
        let host: String
        let generation: Int
        let instance: Instance
        let contentType: InstanceContentType
        let credential: String?
    }

    private enum RefreshOutcome: Sendable {
        case success(RefreshRequest, [Video])
        case failure(RefreshRequest, String)
        case cancelled(RefreshRequest)
    }

    private actor HostRequestLimiter {
        private let limit: Int
        private var activeByHost: [String: Int] = [:]
        private var waitersByHost: [String: [CheckedContinuation<Void, Never>]] = [:]

        init(limit: Int) {
            self.limit = limit
        }

        func acquire(for host: String) async {
            if activeByHost[host, default: 0] < limit {
                activeByHost[host, default: 0] += 1
                return
            }

            await withCheckedContinuation { continuation in
                waitersByHost[host, default: []].append(continuation)
            }
        }

        func release(for host: String) {
            if var waiters = waitersByHost[host], !waiters.isEmpty {
                let continuation = waiters.removeFirst()
                waitersByHost[host] = waiters.isEmpty ? nil : waiters
                continuation.resume()
            } else {
                activeByHost[host, default: 1] -= 1
                if activeByHost[host] == 0 {
                    activeByHost.removeValue(forKey: host)
                }
            }
        }
    }

    private static let hostRequestLimiter = HostRequestLimiter(limit: 3)

    private init() {}

    // MARK: - Cache Key Management

    /// Generates a cache key. Language is optional because the Home endpoints
    /// currently exposed by yattee-plus (`popular` and `trending`) are not
    /// localized, while this cache is also used by source-specific content.
    static func cacheKey(
        instanceID: UUID,
        contentType: InstanceContentType,
        metadataLanguage: String? = nil
    ) -> String {
        let base = "\(instanceID.uuidString)_\(contentType.rawValue)"
        guard let metadataLanguage else { return base }
        return "\(base)_lang_\(metadataLanguage)"
    }

    // MARK: - Public API

    /// Returns cached videos for a specific instance and content type.
    func videos(
        for instanceID: UUID,
        contentType: InstanceContentType,
        metadataLanguage: String? = nil
    ) -> [Video]? {
        let key = Self.cacheKey(
            instanceID: instanceID,
            contentType: contentType,
            metadataLanguage: metadataLanguage
        )
        return cache[key]
    }

    /// Returns true if the cache is valid based on 30-minute validity duration.
    func isCacheValid(
        for instanceID: UUID,
        contentType: InstanceContentType,
        metadataLanguage: String? = nil
    ) -> Bool {
        let key = Self.cacheKey(
            instanceID: instanceID,
            contentType: contentType,
            metadataLanguage: metadataLanguage
        )
        guard let timestamp = lastUpdated[key], !cache[key, default: []].isEmpty else {
            return false
        }
        let validitySeconds = TimeInterval(30 * 60) // 30 minutes
        return Date().timeIntervalSince(timestamp) < validitySeconds
    }

    /// Loads cached data from disk if not already loaded.
    /// Call this early (e.g., on app launch) to populate the cache quickly.
    func loadFromDiskIfNeeded() async {
        guard !diskCacheLoaded else {
            LoggingService.shared.debug("Home instance cache already loaded from disk, skipping", category: .general)
            return
        }
        diskCacheLoaded = true

        if let cacheData = await HomeInstanceDiskCache.shared.load() {
            cache = cacheData.videos
            lastUpdated = cacheData.lastUpdated
            let totalVideos = cache.values.map { $0.count }.reduce(0, +)
            LoggingService.shared.debug(
                "Loaded home instance cache from disk: \(cache.count) keys, \(totalVideos) total videos",
                category: .general
            )
        } else {
            LoggingService.shared.debug("No home instance cache found on disk", category: .general)
        }
    }

    /// Refreshes content from network for a specific instance and content type.
    /// On success, updates cache and saves to disk. On failure, preserves existing cache.
    func refresh(
        instanceID: UUID,
        contentType: InstanceContentType,
        using appEnvironment: AppEnvironment
    ) async {
        await refresh(
            sections: [(instanceID, contentType)],
            using: appEnvironment
        )
    }

    /// Refreshes multiple sections and persists their combined state once.
    func refresh(
        sections: [(instanceID: UUID, contentType: InstanceContentType)],
        using appEnvironment: AppEnvironment
    ) async {
        let requests = prepareRefreshRequests(sections: sections, using: appEnvironment)
        guard !requests.isEmpty else { return }

        var cacheChanged = false
        var pendingRequests = requests
        var activeByHost: [String: Int] = [:]
        let contentService = appEnvironment.contentService

        await withTaskGroup(of: RefreshOutcome.self) { group in
            func addAvailableRequests() {
                while let index = pendingRequests.firstIndex(where: {
                    activeByHost[$0.host, default: 0] < 3
                }) {
                    let request = pendingRequests.remove(at: index)
                    activeByHost[request.host, default: 0] += 1
                    group.addTask {
                        await Self.fetch(request, using: contentService)
                    }
                }
            }

            addAvailableRequests()

            while let outcome = await group.next() {
                let request: RefreshRequest
                switch outcome {
                case .success(let completedRequest, let videos):
                    request = completedRequest
                    if publish(videos, for: completedRequest, using: appEnvironment) {
                        cacheChanged = true
                    }
                case .failure(let failedRequest, let details):
                    request = failedRequest
                    LoggingService.shared.error(
                        "HomeInstanceCache.refresh: Failed to fetch \(failedRequest.contentType.rawValue) from \(failedRequest.instance.displayName)",
                        category: .general,
                        details: details
                    )
                case .cancelled(let cancelledRequest):
                    request = cancelledRequest
                }

                activeByHost[request.host, default: 1] -= 1
                if inFlightGenerations[request.key] == request.generation {
                    inFlightGenerations.removeValue(forKey: request.key)
                }

                if Task.isCancelled {
                    pendingRequests.removeAll()
                    group.cancelAll()
                } else {
                    addAvailableRequests()
                }
            }
        }

        for request in requests where inFlightGenerations[request.key] == request.generation {
            inFlightGenerations.removeValue(forKey: request.key)
        }

        if cacheChanged {
            await saveToDisk()
        }
    }

    private func prepareRefreshRequests(
        sections: [(instanceID: UUID, contentType: InstanceContentType)],
        using appEnvironment: AppEnvironment
    ) -> [RefreshRequest] {
        var requests: [RefreshRequest] = []
        var seenKeys: Set<String> = []

        for section in sections {
            guard let instance = appEnvironment.instancesManager.instances.first(where: { $0.id == section.instanceID }),
                  instance.isEnabled else {
                LoggingService.shared.debug(
                    "HomeInstanceCache.refresh: Instance \(section.instanceID) not found or disabled",
                    category: .general
                )
                continue
            }

            let key = Self.cacheKey(instanceID: section.instanceID, contentType: section.contentType)
            guard seenKeys.insert(key).inserted else { continue }
            if let inFlightGeneration = inFlightGenerations[key],
               inFlightGeneration == refreshGenerations[key] {
                continue
            }

            let credential: String?
            if section.contentType == .feed {
                guard instance.supportsFeed else {
                    LoggingService.shared.debug(
                        "HomeInstanceCache.refresh: Feed not supported for \(instance.type)",
                        category: .general
                    )
                    continue
                }
                guard let feedCredential = appEnvironment.credentialsManager(for: instance)?.credential(for: instance) else {
                    LoggingService.shared.debug(
                        "HomeInstanceCache.refresh: No credential for \(instance.displayName), skipping feed",
                        category: .general
                    )
                    continue
                }
                credential = feedCredential
            } else {
                credential = nil
            }

            let generation = refreshGenerations[key, default: 0] + 1
            refreshGenerations[key] = generation
            inFlightGenerations[key] = generation

            LoggingService.shared.debug(
                "HomeInstanceCache.refresh: Fetching \(section.contentType.rawValue) from \(instance.displayName)",
                category: .general
            )

            requests.append(RefreshRequest(
                key: key,
                host: instance.url.host?.lowercased() ?? instance.url.absoluteString,
                generation: generation,
                instance: instance,
                contentType: section.contentType,
                credential: credential
            ))
        }

        return requests
    }

    nonisolated private static func fetch(
        _ request: RefreshRequest,
        using contentService: ContentService
    ) async -> RefreshOutcome {
        await hostRequestLimiter.acquire(for: request.host)

        let outcome: RefreshOutcome
        if Task.isCancelled {
            outcome = .cancelled(request)
        } else {
            outcome = await performFetch(request, using: contentService)
        }

        await hostRequestLimiter.release(for: request.host)
        return outcome
    }

    nonisolated private static func performFetch(
        _ request: RefreshRequest,
        using contentService: ContentService
    ) async -> RefreshOutcome {
        do {
            let videos: [Video]
            switch request.contentType {
            case .popular:
                videos = try await contentService.popular(for: request.instance)
            case .trending:
                videos = try await contentService.trending(for: request.instance)
            case .feed:
                guard let credential = request.credential else {
                    return .failure(request, "Missing feed credential")
                }
                videos = try await contentService.feed(for: request.instance, credential: credential)
            }
            return .success(request, videos)
        } catch is CancellationError {
            return .cancelled(request)
        } catch {
            return .failure(request, error.localizedDescription)
        }
    }

    private func publish(
        _ videos: [Video],
        for request: RefreshRequest,
        using appEnvironment: AppEnvironment
    ) -> Bool {
        guard refreshGenerations[request.key] == request.generation,
              appEnvironment.instancesManager.instances.contains(request.instance) else {
            return false
        }

        cache[request.key] = videos
        lastUpdated[request.key] = Date()

        LoggingService.shared.info(
            "HomeInstanceCache.refresh: Cached \(videos.count) \(request.contentType.rawValue) videos from \(request.instance.displayName)",
            category: .general
        )

        let youtubeIDs = videos.compactMap { video -> String? in
            if case .global = video.id.source { return video.id.videoID }
            return nil
        }
        if !youtubeIDs.isEmpty {
            appEnvironment.deArrowBrandingProvider.prefetch(videoIDs: youtubeIDs)
        }
        return true
    }

    /// Clears cached content for a specific instance and content type.
    func clear(instanceID: UUID, contentType: InstanceContentType) {
        let keyPrefix = Self.cacheKey(instanceID: instanceID, contentType: contentType)
        let keysToRemove = cache.keys.filter { $0 == keyPrefix || $0.hasPrefix("\(keyPrefix)_lang_") }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            lastUpdated.removeValue(forKey: key)
        }
        let generationKeys = Set(keysToRemove).union([keyPrefix])
        for key in generationKeys {
            refreshGenerations[key, default: 0] += 1
        }
        
        LoggingService.shared.debug(
            "HomeInstanceCache.clear: Cleared \(keysToRemove.count) cache entries for \(keyPrefix)",
            category: .general
        )
        
        Task {
            await saveToDisk()
        }
    }

    /// Clears all cached content for a specific instance.
    func clearAllForInstance(_ instanceID: UUID) {
        let keysToRemove = cache.keys.filter { $0.hasPrefix(instanceID.uuidString) }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            lastUpdated.removeValue(forKey: key)
        }
        let generationKeys = refreshGenerations.keys.filter { $0.hasPrefix(instanceID.uuidString) }
        for key in generationKeys {
            refreshGenerations[key, default: 0] += 1
        }
        
        if !keysToRemove.isEmpty {
            LoggingService.shared.debug(
                "HomeInstanceCache.clearAllForInstance: Cleared \(keysToRemove.count) cache entries for instance \(instanceID)",
                category: .general
            )
            
            Task {
                await saveToDisk()
            }
        }
    }

    // MARK: - Private Helpers

    /// Saves the current cache state to disk.
    private func saveToDisk() async {
        let cacheData = HomeInstanceDiskCache.CacheData(
            videos: cache,
            lastUpdated: lastUpdated
        )
        await HomeInstanceDiskCache.shared.save(cacheData)
    }
}
