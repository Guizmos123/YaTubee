//
//  FeedCache.swift
//  Yattee
//
//  Persistent on-device feed cache for subscription videos.
//  Stores feed data on disk to enable fast loading on app launch.
//

import Foundation
import CryptoKit

/// Persistent feed cache that stores subscription videos on disk.
/// This is a local-only cache (not synced to iCloud) for fast feed loading.
actor FeedCache {
    static let shared = FeedCache()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let cacheFileName = "subscription_feed.json"

    /// In-memory cache of the feed data.
    private var cachedData: FeedCacheData?

    private init() {
        // Use Caches directory - not backed up, not synced
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("FeedCache", isDirectory: true)

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private var cacheFileURL: URL {
        cacheDirectory.appendingPathComponent(cacheFileName)
    }

    private func cacheFileURL(for scopeKey: String?) -> URL {
        guard let scopeKey else { return cacheFileURL }
        let digest = SHA256.hash(data: Data(scopeKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("subscription_feed_\(digest).json")
    }

    // MARK: - Public API

    /// Loads the cached feed from disk.
    /// Returns nil if no cache exists or if it's corrupted.
    func load(scopeKey: String? = nil) async -> FeedCacheData? {
        let fileURL = cacheFileURL(for: scopeKey)
        // Return in-memory cache if available
        if let cachedData, cachedData.scopeKey == scopeKey || scopeKey == nil {
            return cachedData
        }

        // Try to load from disk
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cacheData = try decoder.decode(FeedCacheData.self, from: data)

            // Store in memory
            cachedData = cacheData
            return cacheData
        } catch {
            // Cache is corrupted, remove it
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    /// Saves the feed to disk.
    func save(
        videos: [Video],
        lastUpdated: Date,
        scopeKey: String?,
        syncSnapshot: SubscriptionSyncSnapshot? = nil
    ) async {
        let cacheData = FeedCacheData(
            videos: videos,
            lastUpdated: lastUpdated,
            scopeKey: scopeKey,
            syncSnapshot: syncSnapshot
        )

        // Update in-memory cache
        cachedData = cacheData

        // Write to disk
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(cacheData)
            let sizeMB = Double(data.count) / (1024 * 1024)
            try data.write(to: cacheFileURL(for: scopeKey), options: .atomic)
            await MainActor.run {
                LoggingService.shared.debug(
                    "FeedCache.save: Wrote \(videos.count) videos (\(String(format: "%.2f", sizeMB)) MB) to disk, lastUpdated: \(lastUpdated)",
                    category: .general
                )
            }
        } catch {
            await MainActor.run {
                LoggingService.shared.error(
                    "FeedCache.save: Failed to write to disk",
                    category: .general,
                    details: error.localizedDescription
                )
            }
        }
    }

    /// Clears the feed cache from both memory and disk.
    func clear() async {
        cachedData = nil
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Invalidates the cache by clearing the lastUpdated timestamp.
    /// The cached videos remain available but will be considered stale.
    func invalidate() async {
        guard var data = cachedData else { return }
        data.lastUpdated = .distantPast
        cachedData = data
        await save(
            videos: data.videos,
            lastUpdated: .distantPast,
            scopeKey: data.scopeKey,
            syncSnapshot: data.syncSnapshot
        )
    }
}

enum FeedCacheScopePolicy {
    static func accepts(
        storedScope: String?,
        expectedScope: String,
        allowsLegacyUnscopedCache: Bool
    ) -> Bool {
        storedScope == expectedScope || (storedScope == nil && allowsLegacyUnscopedCache)
    }
}

// MARK: - Cache Data Model

/// Data structure for the feed cache.
struct FeedCacheData: Codable {
    var videos: [Video]
    var lastUpdated: Date
    var scopeKey: String?
    var syncSnapshot: SubscriptionSyncSnapshot?

    init(
        videos: [Video],
        lastUpdated: Date,
        scopeKey: String?,
        syncSnapshot: SubscriptionSyncSnapshot? = nil
    ) {
        self.videos = videos
        self.lastUpdated = lastUpdated
        self.scopeKey = scopeKey
        self.syncSnapshot = syncSnapshot
    }
}
