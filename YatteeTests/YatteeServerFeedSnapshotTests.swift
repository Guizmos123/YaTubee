//
//  YatteeServerFeedSnapshotTests.swift
//  YatteeTests
//
//  Tests for safe replacement and merging of Yattee Server feed snapshots.
//

import Foundation
import Testing
@testable import YaTubee

@Suite("Yattee Server Feed Snapshot Tests")
struct YatteeServerFeedSnapshotTests {
    @Test("A complete successful response replaces the cached snapshot")
    func completeResponseReplacesCache() {
        let cached = [video(id: "stale", published: 100)]
        let response = response(
            status: "ready",
            videos: [serverVideo(id: "current", published: 200)],
            ready: 2,
            pending: 0,
            errors: 0
        )

        let resolved = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: cached,
            expectedChannelCount: 2
        )

        #expect(YatteeServerFeedSnapshot.isComplete(response, expectedChannelCount: 2))
        #expect(resolved.map(\.id.videoID) == ["current"])
    }

    @Test("A partial response preserves cached videos")
    func partialResponsePreservesCache() {
        let cached = [video(id: "cached", published: 100)]
        let response = response(
            status: "pending",
            videos: [],
            ready: 1,
            pending: 1,
            errors: 0
        )

        let resolved = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: cached,
            expectedChannelCount: 2
        )

        #expect(!YatteeServerFeedSnapshot.isComplete(response, expectedChannelCount: 2))
        #expect(resolved.map(\.id.videoID) == ["cached"])
    }

    @Test("A partial response merges a newly discovered video")
    func partialResponseAddsNewVideo() {
        let cached = [video(id: "cached", published: 100)]
        let response = response(
            status: "pending",
            videos: [serverVideo(id: "new", published: 200)],
            ready: 1,
            pending: 1,
            errors: 0
        )

        let resolved = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: cached,
            expectedChannelCount: 2
        )

        #expect(resolved.map(\.id.videoID) == ["new", "cached"])
    }

    @Test("A first partial synchronization exposes available videos")
    func firstPartialResponseIsVisible() {
        let response = response(
            status: "pending",
            videos: [serverVideo(id: "available", published: 100)],
            ready: 1,
            pending: 1,
            errors: 0
        )

        let resolved = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: [],
            expectedChannelCount: 2
        )

        #expect(resolved.map(\.id.videoID) == ["available"])
    }

    @Test("Ready responses with errors or missing counts remain partial")
    func readyDoesNotAloneMeanComplete() {
        let withError = response(
            status: "ready",
            videos: [],
            ready: 1,
            pending: 0,
            errors: 1
        )
        let missingCounts = response(
            status: "ready",
            videos: [],
            ready: nil,
            pending: nil,
            errors: nil
        )

        #expect(!YatteeServerFeedSnapshot.isComplete(withError, expectedChannelCount: 2))
        #expect(!YatteeServerFeedSnapshot.isComplete(missingCounts, expectedChannelCount: 2))
    }

    @Test("Partial merging removes duplicates and keeps stable chronological order")
    func partialMergeDeduplicatesAndSorts() {
        let cached = [
            video(id: "same-date-a", published: 200),
            video(id: "duplicate", published: 100),
            video(id: "undated", published: nil)
        ]
        let response = response(
            status: "pending",
            videos: [
                serverVideo(id: "newest", published: 300),
                serverVideo(id: "duplicate", published: 250),
                serverVideo(id: "same-date-b", published: 200)
            ],
            ready: 1,
            pending: 1,
            errors: 0
        )

        let resolved = YatteeServerFeedSnapshot.videos(
            from: response,
            preserving: cached,
            expectedChannelCount: 2
        )

        #expect(resolved.map(\.id.videoID) == [
            "newest", "duplicate", "same-date-b", "same-date-a", "undated"
        ])
    }

    private func response(
        status: String,
        videos: [ServerFeedVideo],
        ready: Int?,
        pending: Int?,
        errors: Int?
    ) -> StatelessFeedResponse {
        StatelessFeedResponse(
            status: status,
            videos: videos,
            total: videos.count,
            hasMore: false,
            readyCount: ready,
            pendingCount: pending,
            errorCount: errors,
            etaSeconds: nil
        )
    }

    private func serverVideo(id: String, published: Int64?) -> ServerFeedVideo {
        ServerFeedVideo(
            type: "video",
            videoId: id,
            title: id,
            author: "Author",
            authorId: "channel",
            lengthSeconds: 60,
            published: published,
            publishedText: nil,
            viewCount: nil,
            videoThumbnails: nil,
            extractor: "youtube",
            videoUrl: nil,
            isUpcoming: false,
            premiereTimestamp: nil
        )
    }

    private func video(id: String, published: Int64?) -> Video {
        serverVideo(id: id, published: published).toVideo()!
    }
}
