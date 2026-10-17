//
//  InvidiousFeedShortsClassifierTests.swift
//  YatteeTests
//

import Foundation
import Testing
@testable import YaTubee

@Suite("Authenticated Invidious Shorts classification")
struct InvidiousFeedShortsClassifierTests {
    @Test func excludesOnlyPositivelyConfirmedShorts() async throws {
        let provider = Provider(shorts: ["channel": [video("GewIAgqQ0bo", author: "channel")]])
        let classifier = InvidiousFeedShortsClassifier()
        let videos = [
            video("GewIAgqQ0bo", author: "channel", duration: 30),
            video("Bo1ZeFAHsbk", author: "channel", duration: 1_200),
            video("short-classic", author: "channel", duration: 30)
        ]

        let result = try await classifier.excludingConfirmedShorts(
            from: videos, instance: instance(), provider: provider
        )

        #expect(result.map(\.id.videoID) == ["Bo1ZeFAHsbk", "short-classic"])
    }

    @Test func networkFailureKeepsUnclassifiedVideos() async throws {
        let provider = Provider(shorts: [:], failingChannels: ["channel"])
        let input = [video("unknown", author: "channel")]
        let result = try await InvidiousFeedShortsClassifier().excludingConfirmedShorts(
            from: input, instance: instance(), provider: provider
        )
        #expect(result == input)
    }

    @Test func deduplicatesChannelRequestsAndUsesFreshCache() async throws {
        let provider = Provider(shorts: ["channel": []])
        let classifier = InvidiousFeedShortsClassifier()
        let input = [video("one", author: "channel"), video("two", author: "channel")]
        let instance = instance()

        _ = try await classifier.excludingConfirmedShorts(from: input, instance: instance, provider: provider)
        _ = try await classifier.excludingConfirmedShorts(from: input, instance: instance, provider: provider)

        #expect(await provider.requestCount == 1)
    }

    private func instance() -> Instance {
        Instance(type: .invidious, url: URL(string: "https://invidious.example")!)
    }

    private func video(_ id: String, author: String, duration: TimeInterval = 600) -> Video {
        Video(
            id: .global(id), title: id, description: nil,
            author: Author(id: author, name: author), duration: duration,
            publishedAt: Date(), publishedText: nil, viewCount: nil,
            likeCount: nil, thumbnails: [], isLive: false,
            isUpcoming: false, scheduledStartTime: nil
        )
    }
}

private extension InvidiousFeedShortsClassifierTests {
    actor Provider: InvidiousChannelShortsProviding {
        let shorts: [String: [Video]]
        let failingChannels: Set<String>
        private(set) var requestCount = 0

        init(shorts: [String: [Video]], failingChannels: Set<String> = []) {
            self.shorts = shorts
            self.failingChannels = failingChannels
        }

        func firstShortsPage(channelID: String, instance: Instance) async throws -> [Video] {
            requestCount += 1
            if failingChannels.contains(channelID) { throw TestError.failed }
            return shorts[channelID] ?? []
        }
    }

    enum TestError: Error { case failed }
}
