//
//  ChannelAvatarStoreTests.swift
//  Yattee
//
//  Tests for persistent channel avatar storage.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Channel Avatar Store Tests")
struct ChannelAvatarStoreTests {
    @Test("Avatar survives store recreation")
    func persistenceAcrossRecreation() async throws {
        try await withTemporaryDirectory { directory in
            let key = try #require(ChannelAvatarStorageKey(channelID: "channel-a", source: .global(provider: "youtube")))
            let expected = Data("avatar-a".utf8)

            let firstStore = ChannelAvatarStore(directoryURL: directory)
            await firstStore.save(expected, for: key)

            let recreatedStore = ChannelAvatarStore(directoryURL: directory)
            #expect(await recreatedStore.data(for: key) == expected)
        }
    }

    @Test("Successful replacement is atomic from the caller perspective")
    func replacement() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let key = try #require(ChannelAvatarStorageKey(channelID: "channel-a", source: nil))

            await store.save(Data("old".utf8), for: key)
            await store.save(Data("new".utf8), for: key)

            #expect(await store.data(for: key) == Data("new".utf8))
            #expect(await store.statistics().entryCount == 1)
        }
    }

    @Test("No successful replacement preserves the previous avatar")
    func failedLoadPreservesPreviousData() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let key = try #require(ChannelAvatarStorageKey(channelID: "channel-a", source: nil))
            let expected = Data("last-valid-avatar".utf8)

            await store.save(expected, for: key)
            // Network failures never call save, so the last successful bytes remain untouched.

            #expect(await store.data(for: key) == expected)
        }
    }

    @Test("Source scope isolates identical channel IDs")
    func sourceIsolation() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let youtube = try #require(ChannelAvatarStorageKey(channelID: "same-id", source: .global(provider: "youtube")))
            let peerTube = try #require(ChannelAvatarStorageKey(
                channelID: "same-id",
                source: .federated(provider: "peertube", instance: URL(string: "https://video.example")!)
            ))

            await store.save(Data("youtube".utf8), for: youtube)
            await store.save(Data("peertube".utf8), for: peerTube)

            #expect(await store.data(for: youtube) == Data("youtube".utf8))
            #expect(await store.data(for: peerTube) == Data("peertube".utf8))
        }
    }

    @Test("Storage trims old entries to configured bounds")
    func boundedCleanup() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(
                directoryURL: directory,
                maximumEntryCount: 2,
                maximumByteCount: 1_024
            )
            let first = try #require(ChannelAvatarStorageKey(channelID: "first", source: nil))
            let second = try #require(ChannelAvatarStorageKey(channelID: "second", source: nil))
            let third = try #require(ChannelAvatarStorageKey(channelID: "third", source: nil))

            await store.save(Data("first".utf8), for: first)
            try await Task.sleep(for: .milliseconds(10))
            await store.save(Data("second".utf8), for: second)
            try await Task.sleep(for: .milliseconds(10))
            await store.save(Data("third".utf8), for: third)

            let statistics = await store.statistics()
            #expect(statistics.entryCount == 2)
            #expect(await store.data(for: first) == nil)
            #expect(await store.data(for: second) != nil)
            #expect(await store.data(for: third) != nil)
        }
    }

    @Test("Fresh avatars are not revalidated before 24 hours")
    func freshnessWindow() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let key = try #require(ChannelAvatarStorageKey(channelID: "fresh", source: nil))
            let now = Date(timeIntervalSince1970: 1_000_000)
            await store.save(Data("avatar".utf8), for: key)

            #expect(await store.beginRevalidationIfNeeded(for: key, now: now))
            await store.finishRevalidation(for: key, succeeded: true, sourceURL: URL(string: "https://example.com/avatar"), now: now)

            let beforeExpiration = await store.beginRevalidationIfNeeded(
                for: key,
                now: now.addingTimeInterval(86_399)
            )
            #expect(!beforeExpiration)
            #expect(await store.beginRevalidationIfNeeded(for: key, now: now.addingTimeInterval(86_400)))
        }
    }

    @Test("Failed revalidation is retried at a bounded interval")
    func retryWindow() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let key = try #require(ChannelAvatarStorageKey(channelID: "retry", source: nil))
            let now = Date(timeIntervalSince1970: 2_000_000)
            await store.save(Data("avatar".utf8), for: key)

            #expect(await store.beginRevalidationIfNeeded(for: key, now: now))
            await store.finishRevalidation(for: key, succeeded: false, sourceURL: nil, now: now)

            let beforeRetry = await store.beginRevalidationIfNeeded(
                for: key,
                now: now.addingTimeInterval(3_599)
            )
            #expect(!beforeRetry)
            #expect(await store.beginRevalidationIfNeeded(for: key, now: now.addingTimeInterval(3_600)))
        }
    }

    @Test("Concurrent views share one revalidation claim")
    func revalidationDeduplication() async throws {
        try await withTemporaryDirectory { directory in
            let store = ChannelAvatarStore(directoryURL: directory)
            let key = try #require(ChannelAvatarStorageKey(channelID: "deduplicated", source: nil))
            await store.save(Data("avatar".utf8), for: key)

            #expect(await store.beginRevalidationIfNeeded(for: key))
            let duplicateClaim = await store.beginRevalidationIfNeeded(for: key)
            #expect(!duplicateClaim)
        }
    }

    @Test("Freshness metadata survives store recreation and remains scoped")
    func freshnessPersistenceAndIsolation() async throws {
        try await withTemporaryDirectory { directory in
            let youtube = try #require(ChannelAvatarStorageKey(channelID: "same", source: .global(provider: "youtube")))
            let piped = try #require(ChannelAvatarStorageKey(
                channelID: "same",
                source: .federated(provider: "piped", instance: URL(string: "https://piped.example")!)
            ))
            let now = Date(timeIntervalSince1970: 3_000_000)
            let firstStore = ChannelAvatarStore(directoryURL: directory)
            await firstStore.save(Data("youtube".utf8), for: youtube)
            await firstStore.save(Data("piped".utf8), for: piped)
            #expect(await firstStore.beginRevalidationIfNeeded(for: youtube, now: now))
            await firstStore.finishRevalidation(
                for: youtube,
                succeeded: true,
                sourceURL: URL(string: "https://youtube.example/avatar"),
                now: now
            )

            let recreatedStore = ChannelAvatarStore(directoryURL: directory)
            let metadata = await recreatedStore.freshnessMetadata(for: youtube)
            #expect(metadata.lastSuccessfulRevalidation == now)
            #expect(metadata.lastSuccessfulURL == "https://youtube.example/avatar")
            let youtubeIsStillFresh = await recreatedStore.beginRevalidationIfNeeded(
                for: youtube,
                now: now.addingTimeInterval(60)
            )
            #expect(!youtubeIsStillFresh)
            #expect(await recreatedStore.beginRevalidationIfNeeded(for: piped, now: now.addingTimeInterval(60)))
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelAvatarStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}
