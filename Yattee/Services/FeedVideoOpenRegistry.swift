//
//  FeedVideoOpenRegistry.swift
//  Yattee
//
//  Persistent local registry of videos that the user has actually opened.
//

import Foundation
import Observation

/// Tracks real video opens independently from feed visibility and notification novelty.
@MainActor
@Observable
final class FeedVideoOpenRegistry {
    static let shared = FeedVideoOpenRegistry()

    nonisolated static let defaultStorageKey = "feedVideoOpenRegistry.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private var openedByID: [String: Bool]

    init(defaults: UserDefaults = .standard, storageKey: String = defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        let storedIDs = defaults.stringArray(forKey: storageKey) ?? []
        openedByID = Dictionary(uniqueKeysWithValues: storedIDs.map { ($0, true) })
    }

    func isOpened(_ videoID: VideoID) -> Bool {
        openedByID[videoID.id] == true
    }

    @discardableResult
    func markOpened(_ videoID: VideoID) -> Bool {
        let key = videoID.id
        guard openedByID[key] != true else { return false }
        openedByID[key] = true
        persist()
        return true
    }

    @discardableResult
    func markOpenedFromPlayer(_ video: Video) -> Bool {
        markOpened(video.id)
    }

    @discardableResult
    func markOpenedFromDetails(_ video: Video) -> Bool {
        markOpened(video.id)
    }

    /// Existing history is positive evidence of an earlier open. Missing history
    /// is deliberately not interpreted as proof that a video was never opened.
    @discardableResult
    func seed(from watchEntries: [WatchEntry]) -> Int {
        var insertedCount = 0
        for entry in watchEntries {
            let key = entry.videoIdentifier.id
            guard openedByID[key] != true else { continue }
            openedByID[key] = true
            insertedCount += 1
        }
        if insertedCount > 0 {
            persist()
        }
        return insertedCount
    }

    private func persist() {
        defaults.set(openedByID.keys.sorted(), forKey: storageKey)
    }
}

enum FeedNoveltyThumbnailPresentation {
    static func showsBadge(isEnabled: Bool, isOpened: Bool, isWatched: Bool) -> Bool {
        isEnabled && !isOpened && !isWatched
    }
}
