//
//  InvidiousLocalFeedIntegrationPolicyTests.swift
//  YatteeTests
//
//  Tests for local feed source selection and safe snapshot integration.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Invidious Local Feed Integration Policy Tests")
struct InvidiousLocalFeedIntegrationPolicyTests {
    @Test("An enabled Yattee Server has priority over Invidious")
    func yatteeServerHasPriority() {
        let invidious = instance(.invidious)
        let server = instance(.yatteeServer)

        #expect(LocalFeedSource.resolve(from: [invidious, server]) == .yatteeServer(server))
    }

    @Test("Enabled Invidious is selected when Yattee Server is disabled")
    func invidiousFallback() {
        let server = instance(.yatteeServer, enabled: false)
        let invidious = instance(.invidious)

        #expect(LocalFeedSource.resolve(from: [server, invidious]) == .invidious(invidious))
    }

    @Test("A manual Invidious choice overrides automatic Yattee Server priority")
    func manualInvidiousSelection() {
        let server = instance(.yatteeServer)
        let invidious = instance(.invidious)

        #expect(LocalFeedSource.resolve(
            from: [server, invidious],
            preference: .invidious(invidious.id)
        ) == .invidious(invidious))
    }

    @Test("An unavailable manual source never silently falls back")
    func unavailableManualSelection() {
        let server = instance(.yatteeServer)

        #expect(LocalFeedSource.resolve(
            from: [server],
            preference: .invidious(UUID())
        ) == .unavailable)
    }

    @Test("No compatible enabled source is explicit")
    func noCompatibleSource() {
        #expect(LocalFeedSource.resolve(from: [instance(.piped)]) == .unavailable)
        #expect(LocalFeedSource.resolve(from: [instance(.invidious, enabled: false)]) == .unavailable)
    }

    @Test("A complete aggregate replaces the reliable snapshot")
    func completeSnapshotReplacesCache() {
        let aggregation = aggregate(videos: [video("new", 20)], requested: 1, succeeded: 1)

        let resolved = InvidiousLocalFeedSnapshot.videos(
            from: aggregation,
            preserving: [video("old", 10)]
        )

        #expect(resolved.map(\.id.videoID) == ["new"])
    }

    @Test("A partial aggregate merges new videos with the reliable snapshot")
    func partialSnapshotPreservesCache() {
        let aggregation = aggregate(
            videos: [video("new", 30), video("shared", 20)],
            requested: 2,
            succeeded: 1
        )

        let resolved = InvidiousLocalFeedSnapshot.videos(
            from: aggregation,
            preserving: [video("shared", 20), video("old", 10)]
        )

        #expect(resolved.map(\.id.videoID) == ["new", "shared", "old"])
    }

    @Test("A total failure preserves the reliable snapshot")
    func totalFailurePreservesCache() {
        let cached = [video("cached", 10)]
        let aggregation = aggregate(videos: [], requested: 2, succeeded: 0)

        #expect(InvidiousLocalFeedSnapshot.videos(from: aggregation, preserving: cached).map(\.id.videoID) == ["cached"])
    }

    @Test("A first partial synchronization exposes its available videos")
    func firstPartialSnapshotIsVisible() {
        let aggregation = aggregate(videos: [video("available", 10)], requested: 2, succeeded: 1)

        #expect(InvidiousLocalFeedSnapshot.videos(from: aggregation, preserving: []).map(\.id.videoID) == ["available"])
    }

    @Test("Different source scopes cannot reuse each other's snapshots")
    func sourceScopesDoNotMix() {
        let serverScope = "local:yatteeServer:server"
        let firstInvidiousScope = "local:invidious:first"
        let secondInvidiousScope = "local:invidious:second"

        #expect(!FeedCacheScopePolicy.accepts(
            storedScope: serverScope,
            expectedScope: firstInvidiousScope,
            allowsLegacyUnscopedCache: false
        ))
        #expect(!FeedCacheScopePolicy.accepts(
            storedScope: firstInvidiousScope,
            expectedScope: secondInvidiousScope,
            allowsLegacyUnscopedCache: false
        ))
        #expect(FeedCacheScopePolicy.accepts(
            storedScope: firstInvidiousScope,
            expectedScope: firstInvidiousScope,
            allowsLegacyUnscopedCache: false
        ))
    }

    @Test("Legacy unscoped cache can be rejected for local Invidious")
    func localInvidiousRejectsLegacyCache() {
        #expect(!FeedCacheScopePolicy.accepts(
            storedScope: nil,
            expectedScope: "local:invidious:instance",
            allowsLegacyUnscopedCache: false
        ))
    }

    private func aggregate(
        videos: [Video],
        requested: Int,
        succeeded: Int
    ) -> InvidiousLocalFeedAggregation {
        InvidiousLocalFeedAggregation(
            videos: videos,
            requestedChannelCount: requested,
            successfulChannelCount: succeeded,
            failedChannelCount: requested - succeeded,
            status: succeeded == requested ? .complete : .partial
        )
    }

    private func instance(_ type: InstanceType, enabled: Bool = true) -> Instance {
        Instance(type: type, url: URL(string: "https://\(type.rawValue).example")!, isEnabled: enabled)
    }

    private func video(_ id: String, _ published: TimeInterval) -> Video {
        Video(
            id: .global(id),
            title: id,
            description: nil,
            author: Author(id: "channel", name: "Channel"),
            duration: 60,
            publishedAt: Date(timeIntervalSince1970: published),
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}
