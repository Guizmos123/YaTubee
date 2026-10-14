//
//  ChannelAvatarStore.swift
//  Yattee
//
//  Persistent, bounded storage for the last successfully loaded channel avatar.
//

import CryptoKit
import Foundation

/// Stable identity for a persisted channel avatar.
struct ChannelAvatarStorageKey: Hashable, Sendable {
    let channelID: String
    let sourceScope: String

    init?(channelID: String, source: ContentSource?) {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return nil }

        self.channelID = normalizedChannelID
        self.sourceScope = Self.scope(for: source)
    }

    private static func scope(for source: ContentSource?) -> String {
        guard let source else { return "unknown" }

        switch source {
        case .global(let provider):
            return "global:\(provider.lowercased())"
        case .federated(let provider, let instance):
            return "federated:\(provider.lowercased()):\(normalizedHost(for: instance))"
        case .extracted(let extractor, let originalURL):
            return "extracted:\(extractor.lowercased()):\(normalizedHost(for: originalURL))"
        }
    }

    private static func normalizedHost(for url: URL) -> String {
        var value = url.host?.lowercased() ?? url.absoluteString.lowercased()
        if let port = url.port {
            value += ":\(port)"
        }
        return value
    }

    fileprivate var fileName: String {
        let identity = "\(sourceScope)|\(channelID)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".avatar"
    }
}

/// Stores avatar bytes outside the purgeable system caches.
actor ChannelAvatarStore {
    static let shared = ChannelAvatarStore()

    static let defaultFreshnessInterval: TimeInterval = 24 * 60 * 60
    static let defaultRetryInterval: TimeInterval = 60 * 60

    struct Statistics: Equatable, Sendable {
        let entryCount: Int
        let totalBytes: Int
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let maximumEntryCount: Int
    private let maximumByteCount: Int
    private var activeRevalidations = Set<ChannelAvatarStorageKey>()

    init(
        directoryURL: URL? = nil,
        maximumEntryCount: Int = 2_000,
        maximumByteCount: Int = 200 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumByteCount = max(1, maximumByteCount)

        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directoryURL = applicationSupport
                .appendingPathComponent("YaTubee", isDirectory: true)
                .appendingPathComponent("ChannelAvatars", isDirectory: true)
        }
    }

    func data(for key: ChannelAvatarStorageKey) -> Data? {
        try? Data(contentsOf: fileURL(for: key), options: [.mappedIfSafe])
    }

    /// Claims a due revalidation. The claim is persisted before network work so
    /// repeated view construction and relaunches don't create retry loops.
    func beginRevalidationIfNeeded(
        for key: ChannelAvatarStorageKey,
        now: Date = Date(),
        freshnessInterval: TimeInterval = defaultFreshnessInterval,
        retryInterval: TimeInterval = defaultRetryInterval
    ) -> Bool {
        guard fileManager.fileExists(atPath: fileURL(for: key).path),
              !activeRevalidations.contains(key) else {
            return false
        }

        var metadata = loadMetadata(for: key)
        if let lastSuccessfulRevalidation = metadata.lastSuccessfulRevalidation,
           now.timeIntervalSince(lastSuccessfulRevalidation) < freshnessInterval {
            return false
        }
        if let lastAttempt = metadata.lastAttempt,
           now.timeIntervalSince(lastAttempt) < retryInterval {
            return false
        }

        activeRevalidations.insert(key)
        metadata.lastAttempt = now
        saveMetadata(metadata, for: key)
        return true
    }

    func finishRevalidation(
        for key: ChannelAvatarStorageKey,
        succeeded: Bool,
        sourceURL: URL?,
        now: Date = Date()
    ) {
        activeRevalidations.remove(key)
        guard succeeded else { return }

        var metadata = loadMetadata(for: key)
        metadata.lastSuccessfulRevalidation = now
        metadata.lastSuccessfulURL = sourceURL?.absoluteString
        saveMetadata(metadata, for: key)
    }

    func freshnessMetadata(for key: ChannelAvatarStorageKey) -> FreshnessMetadata {
        loadMetadata(for: key)
    }

    /// Atomically replaces the previous avatar. Identical data is not rewritten.
    @discardableResult
    func save(_ data: Data, for key: ChannelAvatarStorageKey) -> Bool {
        guard !data.isEmpty else { return false }

        do {
            try prepareDirectory()
            let destination = fileURL(for: key)
            if let existing = try? Data(contentsOf: destination, options: [.mappedIfSafe]),
               existing == data {
                return true
            }

            try data.write(to: destination, options: .atomic)
            try trimIfNeeded(preserving: destination)
            return true
        } catch {
            Task { @MainActor in
                LoggingService.shared.error(
                    "Failed to persist channel avatar",
                    category: .general,
                    details: error.localizedDescription
                )
            }
            return false
        }
    }

    func statistics() -> Statistics {
        let entries = storedEntries()
        return Statistics(
            entryCount: entries.count,
            totalBytes: entries.reduce(0) { $0 + $1.byteCount }
        )
    }

    private func fileURL(for key: ChannelAvatarStorageKey) -> URL {
        directoryURL.appendingPathComponent(key.fileName, isDirectory: false)
    }

    private func metadataURL(for key: ChannelAvatarStorageKey) -> URL {
        fileURL(for: key).appendingPathExtension("json")
    }

    private func loadMetadata(for key: ChannelAvatarStorageKey) -> FreshnessMetadata {
        guard let data = try? Data(contentsOf: metadataURL(for: key), options: [.mappedIfSafe]),
              let metadata = try? JSONDecoder().decode(FreshnessMetadata.self, from: data) else {
            return FreshnessMetadata()
        }
        return metadata
    }

    private func saveMetadata(_ metadata: FreshnessMetadata, for key: ChannelAvatarStorageKey) {
        do {
            try prepareDirectory()
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL(for: key), options: .atomic)
        } catch {
            Task { @MainActor in
                LoggingService.shared.error(
                    "Failed to persist channel avatar freshness metadata",
                    category: .general,
                    details: error.localizedDescription
                )
            }
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func trimIfNeeded(preserving preservedURL: URL) throws {
        var entries = storedEntries().sorted { $0.modificationDate < $1.modificationDate }
        var totalBytes = entries.reduce(0) { $0 + $1.byteCount }

        while entries.count > maximumEntryCount || totalBytes > maximumByteCount {
            guard let index = entries.firstIndex(where: { $0.url != preservedURL }) else { break }
            let entry = entries.remove(at: index)
            try fileManager.removeItem(at: entry.url)
            try? fileManager.removeItem(at: entry.url.appendingPathExtension("json"))
            totalBytes -= entry.byteCount
        }
    }

    private func storedEntries() -> [StoredEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "avatar",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                return nil
            }

            return StoredEntry(
                url: url,
                byteCount: values.fileSize ?? 0,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private struct StoredEntry {
        let url: URL
        let byteCount: Int
        let modificationDate: Date
    }

    struct FreshnessMetadata: Codable, Equatable, Sendable {
        var lastSuccessfulRevalidation: Date?
        var lastAttempt: Date?
        var lastSuccessfulURL: String?
    }
}
