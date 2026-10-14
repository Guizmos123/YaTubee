//
//  InvidiousLocalFeedAggregatorTests.swift
//  YatteeTests
//
//  Tests for isolated local-subscription aggregation through Invidious.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Invidious Local Feed Aggregator Tests")
struct InvidiousLocalFeedAggregatorTests {
    @Test("Aggregates one first page from multiple channels")
    func aggregatesMultipleChannels() async throws {
        let provider = Provider(responses: [
            "a": .success([video("a1", published: 20)]),
            "b": .success([video("b1", published: 10)])
        ])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a", "b"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == ["a1", "b1"])
        #expect(result.requestedChannelCount == 2)
        #expect(result.successfulChannelCount == 2)
        #expect(result.failedChannelCount == 0)
        #expect(result.status == .complete)
        #expect(await provider.requestedContinuations() == [nil, nil])
    }

    @Test("Deduplicates by the existing business identifier")
    func deduplicatesVideos() async throws {
        let provider = Provider(responses: [
            "a": .success([video("shared", published: 20)]),
            "b": .success([video("shared", published: 20), video("unique", published: 10)])
        ])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a", "b"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == ["shared", "unique"])
    }

    @Test("Sorts deterministically with equal and missing dates")
    func deterministicSort() async throws {
        let provider = Provider(responses: [
            "a": .success([
                video("z-undated", published: nil),
                video("b-equal", published: 10),
                video("a-equal", published: 10),
                video("a-undated", published: nil),
                video("newest", published: 20)
            ])
        ])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == [
            "newest", "a-equal", "b-equal", "a-undated", "z-undated"
        ])
    }

    @Test("Limits the aggregate to one hundred videos")
    func limitsToOneHundredVideos() async throws {
        let videos = (0..<125).map { video("video-\($0)", published: TimeInterval($0)) }
        let provider = Provider(responses: ["a": .success(videos)])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(result.videos.count == 100)
        #expect(result.videos.first?.id.videoID == "video-124")
        #expect(result.videos.last?.id.videoID == "video-25")
    }

    @Test("One failed channel produces a partial result")
    func individualFailureIsPartial() async throws {
        let provider = Provider(responses: [
            "a": .success([video("available", published: 10)]),
            "b": .failure(TestError.failed)
        ])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a", "b"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == ["available"])
        #expect(result.successfulChannelCount == 1)
        #expect(result.failedChannelCount == 1)
        #expect(result.status == .partial)
        #expect(result.channelResults.map(\.channelID) == ["a", "b"])
        #expect(result.channelResults[0].status == .success)
        #expect(result.channelResults[1].status == .failure)
        #expect(result.channelResults[1].errorDescription != nil)
        #expect(result.channelResults.allSatisfy { $0.completedAt <= Date() })
    }

    @Test("All failed channels never produce a complete result")
    func allFailuresArePartial() async throws {
        let provider = Provider(responses: [
            "a": .failure(TestError.failed),
            "b": .failure(TestError.failed)
        ])

        let result = try await aggregator(provider).aggregate(
            subscriptions: subscriptions("a", "b"),
            instance: instance
        )

        #expect(result.videos.isEmpty)
        #expect(result.successfulChannelCount == 0)
        #expect(result.failedChannelCount == 2)
        #expect(result.status == .partial)
    }

    @Test("Runs no more than four channel requests concurrently")
    func limitsConcurrency() async throws {
        let provider = Provider(
            responses: Dictionary(uniqueKeysWithValues: (0..<12).map {
                ("channel-\($0)", .success([video("video-\($0)", published: TimeInterval($0))]))
            }),
            suspendRequests: true
        )
        let task = Task {
            try await aggregator(provider).aggregate(
                subscriptions: (0..<12).map { .init(channelID: "channel-\($0)") },
                instance: instance
            )
        }

        await provider.waitUntilStarted(4)
        #expect(await provider.maximumConcurrentRequestCount() == 4)
        #expect(await provider.startedRequestCount() == 4)
        await provider.resumeAll()
        _ = try await task.value
        #expect(await provider.maximumConcurrentRequestCount() == 4)
    }

    @Test("Cancellation propagates instead of returning a partial success")
    func cancellationPropagates() async {
        let provider = Provider(
            responses: ["a": .success([video("a", published: 1)])],
            suspendRequests: true
        )
        let task = Task {
            try await aggregator(provider).aggregate(
                subscriptions: subscriptions("a"),
                instance: instance
            )
        }

        await provider.waitUntilStarted(1)
        task.cancel()
        await provider.resumeAll()

        do {
            _ = try await task.value
            Issue.record("Expected aggregation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An empty subscription list is a complete empty aggregate")
    func emptySubscriptions() async throws {
        let provider = Provider(responses: [:])
        let result = try await aggregator(provider).aggregate(subscriptions: [], instance: instance)

        #expect(result.videos.isEmpty)
        #expect(result.requestedChannelCount == 0)
        #expect(result.successfulChannelCount == 0)
        #expect(result.failedChannelCount == 0)
        #expect(result.status == .complete)
        #expect(result.channelResults.isEmpty)
        #expect(await provider.startedRequestCount() == 0)
    }

    @Test("Enriches suspicious metadata before sorting")
    func enrichesSuspiciousMetadata() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let suspect = video("suspect", published: 10_000, viewCount: 0)
        let corrected = video(
            "suspect",
            published: 1_000,
            publishedText: "3 months ago",
            viewCount: 1_370_000
        )
        let provider = Provider(
            responses: ["a": .success([suspect, video("recent", published: 9_000, viewCount: 10)])],
            detailResponses: ["suspect": .success(corrected)]
        )

        let result = try await aggregator(provider, now: refreshDate).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == ["recent", "suspect"])
        #expect(result.videos.last?.publishedAt == corrected.publishedAt)
        #expect(result.videos.last?.publishedText == "3 months ago")
        #expect(result.videos.last?.viewCount == 1_370_000)
        #expect(await provider.detailRequestCount() == 1)
    }

    @Test("Enriches a future-dated video even when it has views")
    func enrichesFutureDate() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let provider = Provider(
            responses: ["a": .success([video("future", published: 11_000, viewCount: 50)])],
            detailResponses: ["future": .success(video("future", published: 1_000, viewCount: 50))]
        )

        let result = try await aggregator(provider, now: refreshDate).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(result.videos.first?.publishedAt == Date(timeIntervalSince1970: 1_000))
        #expect(await provider.detailRequestCount() == 1)
    }

    @Test("Does not request details for normal videos")
    func normalVideoNeedsNoEnrichment() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let provider = Provider(responses: [
            "a": .success([video("normal", published: 9_000, viewCount: 0)])
        ])

        _ = try await aggregator(provider, now: refreshDate).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(await provider.detailRequestCount() == 0)
    }

    @Test("Reuses reliable cached metadata without a detail request")
    func reusesCachedCorrection() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let provider = Provider(responses: [
            "a": .success([video("suspect", published: 10_000, viewCount: 0)])
        ])
        let cached = video("suspect", published: 1_000, viewCount: 500)

        let result = try await aggregator(provider, now: refreshDate).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance,
            cachedVideos: [cached]
        )

        #expect(result.videos.first?.publishedAt == cached.publishedAt)
        #expect(result.videos.first?.viewCount == 500)
        #expect(await provider.detailRequestCount() == 0)
    }

    @Test("Limits suspicious detail requests to twenty and four concurrently")
    func limitsEnrichmentBudgetAndConcurrency() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let suspects = (0..<25).map { video("suspect-\($0)", published: 10_000, viewCount: 0) }
        let details = Dictionary(uniqueKeysWithValues: suspects.map {
            ($0.id.videoID, Result<Video, Error>.success(video($0.id.videoID, published: 1_000, viewCount: 100)))
        })
        let provider = Provider(
            responses: ["a": .success(suspects)],
            detailResponses: details,
            suspendDetailRequests: true
        )
        let task = Task {
            try await aggregator(provider, now: refreshDate).aggregate(
                subscriptions: subscriptions("a"),
                instance: instance
            )
        }

        await provider.waitUntilDetailStarted(4)
        #expect(await provider.maximumConcurrentDetailRequestCount() == 4)
        await provider.resumeAllDetails()
        _ = try await task.value
        #expect(await provider.detailRequestCount() == 20)
        #expect(await provider.maximumConcurrentDetailRequestCount() == 4)
    }

    @Test("A failed enrichment keeps the video but ignores its suspect date for sorting")
    func failedEnrichmentUsesSafeSort() async throws {
        let refreshDate = Date(timeIntervalSince1970: 10_000)
        let provider = Provider(
            responses: ["a": .success([
                video("suspect", published: 10_000, viewCount: 0),
                video("reliable", published: 9_000, viewCount: 10)
            ])],
            detailResponses: ["suspect": .failure(TestError.failed)]
        )

        let result = try await aggregator(provider, now: refreshDate).aggregate(
            subscriptions: subscriptions("a"),
            instance: instance
        )

        #expect(result.videos.map(\.id.videoID) == ["reliable", "suspect"])
        #expect(result.videos.last?.publishedAt == refreshDate)
    }

    private var instance: Instance {
        Instance(type: .invidious, url: URL(string: "https://invidious.example")!)
    }

    private func aggregator(_ provider: Provider, now: Date? = nil) -> InvidiousLocalFeedAggregator {
        InvidiousLocalFeedAggregator(videoProvider: provider, now: { now ?? Date() })
    }

    private func subscriptions(_ channelIDs: String...) -> [InvidiousLocalFeedSubscription] {
        channelIDs.map { InvidiousLocalFeedSubscription(channelID: $0) }
    }

    private func video(
        _ id: String,
        published: TimeInterval?,
        publishedText: String? = nil,
        viewCount: Int? = nil
    ) -> Video {
        Video(
            id: .global(id),
            title: id,
            description: nil,
            author: Author(id: "channel", name: "Channel"),
            duration: 60,
            publishedAt: published.map(Date.init(timeIntervalSince1970:)),
            publishedText: publishedText,
            viewCount: viewCount,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}

private extension InvidiousLocalFeedAggregatorTests {
    enum TestError: Error {
        case failed
    }

    actor Provider: InvidiousLocalFeedVideoProviding {
        private let responses: [String: Result<[Video], Error>]
        private let detailResponses: [String: Result<Video, Error>]
        private let suspendRequests: Bool
        private let suspendDetailRequests: Bool
        private var requestsReleased = false
        private var detailRequestsReleased = false
        private var activeRequests = 0
        private var maximumActiveRequests = 0
        private var requestedContinuationValues: [String?] = []
        private var startedCount = 0
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var requestWaiters: [CheckedContinuation<Void, Never>] = []
        private var activeDetailRequests = 0
        private var maximumActiveDetailRequests = 0
        private var detailStartedCount = 0
        private var detailStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var detailRequestWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            responses: [String: Result<[Video], Error>],
            detailResponses: [String: Result<Video, Error>] = [:],
            suspendRequests: Bool = false,
            suspendDetailRequests: Bool = false
        ) {
            self.responses = responses
            self.detailResponses = detailResponses
            self.suspendRequests = suspendRequests
            self.suspendDetailRequests = suspendDetailRequests
        }

        func latestVideos(channelID: String, instance: Instance) async throws -> [Video] {
            requestedContinuationValues.append(nil)
            activeRequests += 1
            startedCount += 1
            maximumActiveRequests = max(maximumActiveRequests, activeRequests)
            resumeSatisfiedStartWaiters()

            if suspendRequests && !requestsReleased {
                await withCheckedContinuation { continuation in
                    requestWaiters.append(continuation)
                }
            }

            activeRequests -= 1
            try Task.checkCancellation()
            let videos = try responses[channelID, default: .failure(TestError.failed)].get()
            return videos
        }

        func video(id: String, instance: Instance) async throws -> Video {
            activeDetailRequests += 1
            detailStartedCount += 1
            maximumActiveDetailRequests = max(maximumActiveDetailRequests, activeDetailRequests)
            resumeSatisfiedDetailStartWaiters()

            if suspendDetailRequests && !detailRequestsReleased {
                await withCheckedContinuation { continuation in
                    detailRequestWaiters.append(continuation)
                }
            }

            activeDetailRequests -= 1
            try Task.checkCancellation()
            return try detailResponses[id, default: .failure(TestError.failed)].get()
        }

        func waitUntilStarted(_ count: Int) async {
            guard startedCount < count else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append((count, continuation))
            }
        }

        func resumeAll() {
            requestsReleased = true
            suspendAllWaiters()
        }

        func waitUntilDetailStarted(_ count: Int) async {
            guard detailStartedCount < count else { return }
            await withCheckedContinuation { continuation in
                detailStartWaiters.append((count, continuation))
            }
        }

        func resumeAllDetails() {
            detailRequestsReleased = true
            let waiters = detailRequestWaiters
            detailRequestWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func startedRequestCount() -> Int { startedCount }
        func maximumConcurrentRequestCount() -> Int { maximumActiveRequests }
        func requestedContinuations() -> [String?] { requestedContinuationValues }
        func detailRequestCount() -> Int { detailStartedCount }
        func maximumConcurrentDetailRequestCount() -> Int { maximumActiveDetailRequests }

        private func resumeSatisfiedStartWaiters() {
            let satisfied = startWaiters.filter { startedCount >= $0.count }
            startWaiters.removeAll { startedCount >= $0.count }
            for waiter in satisfied {
                waiter.continuation.resume()
            }
        }

        private func suspendAllWaiters() {
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func resumeSatisfiedDetailStartWaiters() {
            let satisfied = detailStartWaiters.filter { detailStartedCount >= $0.count }
            detailStartWaiters.removeAll { detailStartedCount >= $0.count }
            for waiter in satisfied { waiter.continuation.resume() }
        }
    }
}
