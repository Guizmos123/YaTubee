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
        // Find the instance
        guard let instance = appEnvironment.instancesManager.instances.first(where: { $0.id == instanceID }),
              instance.isEnabled else {
            LoggingService.shared.debug(
                "HomeInstanceCache.refresh: Instance \(instanceID) not found or disabled",
                category: .general
            )
            return
        }

        // Do not add a language variant here: yattee-plus does not accept
        // `lang` on Home's popular/trending endpoints, and feed is only used
        // here for Invidious/Piped. This avoids duplicate equivalent entries.
        let key = Self.cacheKey(instanceID: instanceID, contentType: contentType)
        
        LoggingService.shared.debug(
            "HomeInstanceCache.refresh: Fetching \(contentType.rawValue) from \(instance.displayName)",
            category: .general
        )

        do {
            let videos: [Video]
            
            switch contentType {
            case .popular:
                videos = try await appEnvironment.contentService.popular(for: instance)
                
            case .trending:
                videos = try await appEnvironment.contentService.trending(for: instance)
                
            case .feed:
                // Only Invidious and Piped support feed
                guard instance.supportsFeed else {
                    LoggingService.shared.debug(
                        "HomeInstanceCache.refresh: Feed not supported for \(instance.type)",
                        category: .general
                    )
                    return
                }

                // Check if user is logged in
                guard let credential = appEnvironment.credentialsManager(for: instance)?.credential(for: instance) else {
                    LoggingService.shared.debug(
                        "HomeInstanceCache.refresh: No credential for \(instance.displayName), skipping feed",
                        category: .general
                    )
                    return
                }
                
                videos = try await appEnvironment.contentService.feed(for: instance, credential: credential)
            }

            // Update cache
            cache[key] = videos
            lastUpdated[key] = Date()
            
            LoggingService.shared.info(
                "HomeInstanceCache.refresh: Cached \(videos.count) \(contentType.rawValue) videos from \(instance.displayName)",
                category: .general
            )

            // Save to disk
            await saveToDisk()

            // Prefetch DeArrow branding for YouTube videos
            let youtubeIDs = videos.compactMap { video -> String? in
                if case .global = video.id.source { return video.id.videoID }
                return nil
            }
            if !youtubeIDs.isEmpty {
                appEnvironment.deArrowBrandingProvider.prefetch(videoIDs: youtubeIDs)
            }
        } catch {
            LoggingService.shared.error(
                "HomeInstanceCache.refresh: Failed to fetch \(contentType.rawValue) from \(instance.displayName)",
                category: .general,
                details: error.localizedDescription
            )
            // Preserve existing cache on error (show stale data)
        }
    }

    /// Clears cached content for a specific instance and content type.
    func clear(instanceID: UUID, contentType: InstanceContentType) {
        let keyPrefix = Self.cacheKey(instanceID: instanceID, contentType: contentType)
        let keysToRemove = cache.keys.filter { $0 == keyPrefix || $0.hasPrefix("\(keyPrefix)_lang_") }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            lastUpdated.removeValue(forKey: key)
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
