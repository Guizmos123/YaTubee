//
//  FeedVideoOpenRegistryTests.swift
//  YatteeTests
//
//  Tests for persistent subscription Feed video-open tracking.
//

import Foundation
import Testing
@testable import YaTubee

@Suite("Feed video open registry", .serialized)
@MainActor
struct FeedVideoOpenRegistryTests {
    @Test("Opened videos persist across registry instances")
    func persistence() {
        withDefaults { defaults in
            let first = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")
            first.markOpened(Video.preview.id)

            let restored = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")
            #expect(restored.isOpened(Video.preview.id))
        }
    }

    @Test("Repeated opens are deduplicated")
    func deduplication() {
        withDefaults { defaults in
            let registry = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")

            #expect(registry.markOpened(Video.preview.id))
            #expect(!registry.markOpened(Video.preview.id))
            #expect(defaults.stringArray(forKey: "opened")?.count == 1)
        }
    }

    @Test("Player opening marks the video")
    func playerOpening() {
        withDefaults { defaults in
            let registry = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")
            registry.markOpenedFromPlayer(.preview)
            #expect(registry.isOpened(Video.preview.id))
        }
    }

    @Test("Details opening marks the video")
    func detailsOpening() {
        withDefaults { defaults in
            let registry = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")
            registry.markOpenedFromDetails(.preview)
            #expect(registry.isOpened(Video.preview.id))
        }
    }

    @Test("Existing watch history seeds opened videos")
    func watchHistorySeed() {
        withDefaults { defaults in
            let registry = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")
            let entry = WatchEntry.from(video: .preview)

            #expect(registry.seed(from: [entry]) == 1)
            #expect(registry.seed(from: [entry]) == 0)
            #expect(registry.isOpened(Video.preview.id))
        }
    }

    @Test("Thumbnail setting only controls presentation")
    func presentationSetting() {
        #expect(!FeedNoveltyThumbnailPresentation.showsBadge(
            isEnabled: false,
            isOpened: false,
            isWatched: false
        ))
        #expect(FeedNoveltyThumbnailPresentation.showsBadge(
            isEnabled: true,
            isOpened: false,
            isWatched: false
        ))
        #expect(!FeedNoveltyThumbnailPresentation.showsBadge(
            isEnabled: true,
            isOpened: true,
            isWatched: false
        ))
        #expect(!FeedNoveltyThumbnailPresentation.showsBadge(
            isEnabled: true,
            isOpened: false,
            isWatched: true
        ))
    }

    @Test("Open tracking does not mutate the novelty registry storage")
    func independentFromFeedNoveltyRegistry() {
        withDefaults { defaults in
            _ = FeedNoveltyRegistry(defaults: defaults, storageKey: "novelty")
            let opened = FeedVideoOpenRegistry(defaults: defaults, storageKey: "opened")

            opened.markOpened(Video.preview.id)

            #expect(defaults.data(forKey: "novelty") == nil)
            #expect(defaults.stringArray(forKey: "opened") == [Video.preview.id.id])
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "FeedVideoOpenRegistryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
