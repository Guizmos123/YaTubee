//
//  SubscriptionSyncSnapshotTests.swift
//  YatteeTests
//
//  Tests for subscription synchronization diagnostics and persistence.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Subscription Sync Snapshot Tests")
struct SubscriptionSyncSnapshotTests {
    @Test("Decodes watched channels with dates and null values")
    func decodesWatchedChannels() throws {
        let data = Data(#"""
        [
          {
            "channel_id": "UC1",
            "site": "youtube",
            "channel_name": "One",
            "last_requested": "2026-10-14T08:00:00Z",
            "last_fetch": "2026-10-14T08:00:05Z",
            "fetch_error": null,
            "video_count": 42
          },
          {
            "channel_id": "UC2",
            "site": "youtube",
            "channel_name": null,
            "last_requested": null,
            "last_fetch": null,
            "fetch_error": "Unavailable",
            "video_count": null
          }
        ]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let channels = try decoder.decode([WatchedChannelStatus].self, from: data)

        #expect(channels.count == 2)
        #expect(channels[0].channelId == "UC1")
        #expect(channels[0].lastRequested != nil)
        #expect(channels[0].lastFetch?.timeIntervalSince(channels[0].lastRequested!) == 5)
        #expect(channels[0].videoCount == 42)
        #expect(channels[1].channelName == nil)
        #expect(channels[1].lastFetch == nil)
        #expect(channels[1].fetchError == "Unavailable")
    }

    @Test("Decodes the optional Yattee Server collection interval")
    func decodesServerCollectionInterval() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let configured = try decoder.decode(
            YatteeServerSettings.self,
            from: Data(#"{"feed_fetch_interval":1800}"#.utf8)
        )
        let missing = try decoder.decode(YatteeServerSettings.self, from: Data("{}".utf8))
        let null = try decoder.decode(
            YatteeServerSettings.self,
            from: Data(#"{"feed_fetch_interval":null}"#.utf8)
        )
        let invalid = try decoder.decode(
            YatteeServerSettings.self,
            from: Data(#"{"feed_fetch_interval":"unknown"}"#.utf8)
        )

        #expect(configured.feedFetchInterval == 1800)
        #expect(missing.feedFetchInterval == nil)
        #expect(null.feedFetchInterval == nil)
        #expect(invalid.feedFetchInterval == nil)
    }

    @Test("Classifies known server collections independently from the YaTubee refresh")
    func classifiesKnownServerCollections() {
        let start = Date(timeIntervalSince1970: 100)
        let requests = ["success", "old", "never", "failure", "missing"].map {
            StatelessChannelRequest(
                channelId: $0,
                site: "youtube",
                channelName: $0,
                avatarUrl: nil
            )
        }
        let watched = [
            watched("success", requested: 110, fetched: 111),
            watched("old", requested: 110, fetched: 90),
            watched("never", requested: 110, fetched: nil),
            watched("failure", requested: 110, fetched: 80, error: "HTTP 500")
        ]
        let snapshot = YatteeServerSyncClassification.snapshot(
            source: source(.yatteeServer),
            requestedChannels: requests,
            watchedChannels: watched,
            refreshStartedAt: start,
            refreshFinishedAt: Date(timeIntervalSince1970: 120),
            observedAt: Date(timeIntervalSince1970: 121)
        )

        #expect(snapshot.totalChannelCount == 5)
        #expect(snapshot.successfulChannelCount == 2)
        #expect(snapshot.pendingChannelCount == 0)
        #expect(snapshot.failedChannelCount == 1)
        #expect(snapshot.unknownChannelCount == 2)
        #expect(snapshot.channels.first(where: { $0.channelID == "old" })?.state == .success)
        #expect(snapshot.channels.first(where: { $0.channelID == "never" })?.state == .unknown)
        #expect(snapshot.channels.first(where: { $0.channelID == "failure" })?.errorDescription == "HTTP 500")
        #expect(snapshot.channels.first(where: { $0.channelID == "failure" })?.lastFetchedAt == Date(timeIntervalSince1970: 80))
        #expect(snapshot.serverFeedFetchIntervalSeconds == nil)
        #expect(
            snapshot.successfulChannelCount
                + snapshot.pendingChannelCount
                + snapshot.failedChannelCount
                + snapshot.unknownChannelCount
                == snapshot.totalChannelCount
        )
    }

    @Test("A legacy snapshot decodes without a collection interval")
    func decodesLegacySnapshotWithoutCollectionInterval() throws {
        let snapshot = SubscriptionSyncSnapshot(
            source: source(.yatteeServer),
            refreshStartedAt: Date(timeIntervalSince1970: 100),
            refreshFinishedAt: Date(timeIntervalSince1970: 110),
            channels: [syncChannel("UC1", state: .success, fetched: 90)],
            serverInformationObservedAt: Date(timeIntervalSince1970: 111),
            observationError: nil,
            serverFeedFetchIntervalSeconds: 1800
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "serverFeedFetchIntervalSeconds")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SubscriptionSyncSnapshot.self, from: legacyData)

        #expect(decoded.serverFeedFetchIntervalSeconds == nil)
        #expect(decoded.successfulChannelCount == 1)
    }

    @Test("Old feed cache JSON migrates without a synchronization snapshot")
    func decodesLegacyFeedCache() throws {
        let data = Data(#"""
        {
          "videos": [],
          "lastUpdated": "2026-10-14T08:00:00Z",
          "scopeKey": "local:invidious:legacy"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let cache = try decoder.decode(FeedCacheData.self, from: data)

        #expect(cache.videos.isEmpty)
        #expect(cache.syncSnapshot == nil)
    }

    @Test("Previously persisted Yattee Server pending states use collection semantics")
    func normalizesLegacyYatteeServerPendingStates() {
        let snapshot = SubscriptionSyncSnapshot(
            source: source(.yatteeServer),
            refreshStartedAt: Date(timeIntervalSince1970: 100),
            refreshFinishedAt: Date(timeIntervalSince1970: 110),
            channels: [
                syncChannel("collected", state: .pending, fetched: 90),
                syncChannel("never", state: .pending, fetched: nil)
            ],
            serverInformationObservedAt: Date(timeIntervalSince1970: 111),
            observationError: nil
        ).normalizedForCurrentSemantics

        #expect(snapshot.successfulChannelCount == 1)
        #expect(snapshot.pendingChannelCount == 0)
        #expect(snapshot.unknownChannelCount == 1)
    }

    @Test("Synchronization snapshot persists and remains scoped by source and instance")
    func snapshotRoundTripAndScopeIsolation() throws {
        let server = source(.yatteeServer)
        let invidious = source(.invidious)
        let snapshot = SubscriptionSyncSnapshot(
            source: server,
            refreshStartedAt: Date(timeIntervalSince1970: 100),
            refreshFinishedAt: Date(timeIntervalSince1970: 110),
            channels: [
                SubscriptionSyncSnapshot.Channel(
                    channelID: "UC1",
                    site: "youtube",
                    channelName: "One",
                    state: .success,
                    errorDescription: nil,
                    lastRequestedAt: nil,
                    lastFetchedAt: nil,
                    requestCompletedAt: Date(timeIntervalSince1970: 109),
                    videoCount: nil
                )
            ],
            serverInformationObservedAt: nil,
            observationError: nil,
            serverFeedFetchIntervalSeconds: 1800
        )
        let cache = FeedCacheData(
            videos: [],
            lastUpdated: Date(timeIntervalSince1970: 110),
            scopeKey: snapshot.cacheScopeKey,
            syncSnapshot: snapshot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(FeedCacheData.self, from: encoder.encode(cache))

        #expect(decoded.syncSnapshot == snapshot)
        #expect(decoded.syncSnapshot?.serverFeedFetchIntervalSeconds == 1800)
        #expect(snapshot.cacheScopeKey != SubscriptionSyncSnapshot(
            source: invidious,
            refreshStartedAt: snapshot.refreshStartedAt,
            refreshFinishedAt: snapshot.refreshFinishedAt,
            channels: [],
            serverInformationObservedAt: nil,
            observationError: nil
        ).cacheScopeKey)
    }

    private func watched(
        _ id: String,
        requested: TimeInterval?,
        fetched: TimeInterval?,
        error: String? = nil
    ) -> WatchedChannelStatus {
        WatchedChannelStatus(
            channelId: id,
            site: "youtube",
            channelName: id,
            lastRequested: requested.map(Date.init(timeIntervalSince1970:)),
            lastFetch: fetched.map(Date.init(timeIntervalSince1970:)),
            fetchError: error,
            videoCount: nil
        )
    }

    private func source(_ kind: SubscriptionSyncSnapshot.Source.Kind) -> SubscriptionSyncSnapshot.Source {
        SubscriptionSyncSnapshot.Source(
            kind: kind,
            instanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            instanceURL: URL(string: "https://example.com")!
        )
    }

    private func syncChannel(
        _ id: String,
        state: SubscriptionSyncSnapshot.Channel.State,
        fetched: TimeInterval?
    ) -> SubscriptionSyncSnapshot.Channel {
        SubscriptionSyncSnapshot.Channel(
            channelID: id,
            site: "youtube",
            channelName: id,
            state: state,
            errorDescription: nil,
            lastRequestedAt: Date(timeIntervalSince1970: 110),
            lastFetchedAt: fetched.map(Date.init(timeIntervalSince1970:)),
            requestCompletedAt: nil,
            videoCount: nil
        )
    }
}
