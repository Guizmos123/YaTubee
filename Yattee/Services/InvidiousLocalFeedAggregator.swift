//
//  InvidiousLocalFeedAggregator.swift
//  Yattee
//
//  Aggregates channel latestVideos for local subscriptions via Invidious.
//

import Foundation

struct InvidiousLocalFeedSubscription: Hashable, Sendable {
    let channelID: String
}

protocol InvidiousLocalFeedVideoProviding: Sendable {
    func latestVideos(channelID: String, instance: Instance) async throws -> [Video]
    func video(id: String, instance: Instance) async throws -> Video
}

extension ContentService: InvidiousLocalFeedVideoProviding {
    func latestVideos(channelID: String, instance: Instance) async throws -> [Video] {
        try await channelLatestVideos(id: channelID, instance: instance)
    }
}

struct InvidiousLocalFeedAggregation: Sendable {
    enum Status: Sendable {
        case complete
        case partial
    }

    let videos: [Video]
    let requestedChannelCount: Int
    let successfulChannelCount: Int
    let failedChannelCount: Int
    let status: Status
    let unreliablePublishedDateIDs: Set<VideoID>

    init(
        videos: [Video],
        requestedChannelCount: Int,
        successfulChannelCount: Int,
        failedChannelCount: Int,
        status: Status,
        unreliablePublishedDateIDs: Set<VideoID> = []
    ) {
        self.videos = videos
        self.requestedChannelCount = requestedChannelCount
        self.successfulChannelCount = successfulChannelCount
        self.failedChannelCount = failedChannelCount
        self.status = status
        self.unreliablePublishedDateIDs = unreliablePublishedDateIDs
    }
}

enum LocalFeedSource: Equatable, Sendable {
    case yatteeServer(Instance)
    case invidious(Instance)
    case unavailable

    static func resolve(
        from instances: [Instance],
        preference: LocalFeedSourcePreference = .automatic
    ) -> LocalFeedSource {
        switch preference {
        case .yatteeServer(let id):
            return instances.first(where: { $0.id == id && $0.type == .yatteeServer && $0.isEnabled })
                .map(Self.yatteeServer) ?? .unavailable
        case .invidious(let id):
            return instances.first(where: { $0.id == id && $0.type == .invidious && $0.isEnabled })
                .map(Self.invidious) ?? .unavailable
        case .automatic:
            break
        }
        if let server = instances.first(where: { $0.type == .yatteeServer && $0.isEnabled }) {
            return .yatteeServer(server)
        }
        if let invidious = instances.first(where: { $0.type == .invidious && $0.isEnabled }) {
            return .invidious(invidious)
        }
        return .unavailable
    }
}

enum InvidiousLocalFeedSnapshot {
    static func videos(
        from aggregation: InvidiousLocalFeedAggregation,
        preserving cachedVideos: [Video]
    ) -> [Video] {
        guard aggregation.status == .partial else {
            return aggregation.videos
        }
        guard aggregation.successfulChannelCount > 0 else {
            return cachedVideos
        }

        var seen = Set<VideoID>()
        return Array(
            (aggregation.videos + cachedVideos)
                .filter { seen.insert($0.id).inserted }
                .sorted {
                    InvidiousLocalFeedAggregator.isOrderedBefore(
                        $0,
                        $1,
                        ignoringPublishedDatesFor: aggregation.unreliablePublishedDateIDs
                    )
                }
                .prefix(InvidiousLocalFeedAggregator.maximumVideoCount)
        )
    }
}

struct InvidiousLocalFeedAggregator: Sendable {
    static let maximumConcurrentRequests = 4
    static let maximumConcurrentEnrichmentRequests = 4
    static let maximumEnrichmentCount = 20
    static let maximumVideoCount = 100

    private static let futureDateTolerance: TimeInterval = 5 * 60
    private static let refreshDateProximity: TimeInterval = 15 * 60
    private static let meaningfulCachedDateDifference: TimeInterval = 60 * 60

    private let videoProvider: any InvidiousLocalFeedVideoProviding
    private let now: @Sendable () -> Date

    init(
        videoProvider: any InvidiousLocalFeedVideoProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.videoProvider = videoProvider
        self.now = now
    }

    func aggregate(
        subscriptions: [InvidiousLocalFeedSubscription],
        instance: Instance,
        cachedVideos: [Video] = []
    ) async throws -> InvidiousLocalFeedAggregation {
        try Task.checkCancellation()
        let refreshDate = now()

        guard !subscriptions.isEmpty else {
            return InvidiousLocalFeedAggregation(
                videos: [],
                requestedChannelCount: 0,
                successfulChannelCount: 0,
                failedChannelCount: 0,
                status: .complete
            )
        }

        let outcomes = try await fetchLatestVideos(subscriptions: subscriptions, instance: instance)
        let successfulOutcomes = outcomes.compactMap { outcome -> SuccessfulFetch? in
            if case .success(let fetch) = outcome { return fetch }
            return nil
        }
        let failedCount = outcomes.count - successfulOutcomes.count

        var seen = Set<VideoID>()
        var videos = successfulOutcomes
            .sorted { $0.subscriptionIndex < $1.subscriptionIndex }
            .flatMap(\.videos)
            .filter { seen.insert($0.id).inserted }

        let enrichment = try await enrichSuspiciousVideos(
            videos,
            cachedVideos: cachedVideos,
            instance: instance,
            refreshDate: refreshDate
        )
        videos = enrichment.videos.sorted {
            Self.isOrderedBefore(
                $0,
                $1,
                ignoringPublishedDatesFor: enrichment.unreliablePublishedDateIDs
            )
        }

        return InvidiousLocalFeedAggregation(
            videos: Array(videos.prefix(Self.maximumVideoCount)),
            requestedChannelCount: subscriptions.count,
            successfulChannelCount: successfulOutcomes.count,
            failedChannelCount: failedCount,
            status: failedCount == 0 ? .complete : .partial,
            unreliablePublishedDateIDs: enrichment.unreliablePublishedDateIDs
        )
    }

    private func enrichSuspiciousVideos(
        _ sourceVideos: [Video],
        cachedVideos: [Video],
        instance: Instance,
        refreshDate: Date
    ) async throws -> EnrichmentResult {
        let cachedByID = Dictionary(cachedVideos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var videos = sourceVideos
        var candidateIndexes: [Int] = []

        for index in videos.indices where Self.isSuspicious(videos[index], relativeTo: refreshDate) {
            if let cached = cachedByID[videos[index].id],
               Self.hasReliableCachedMetadata(cached, replacing: videos[index], relativeTo: refreshDate) {
                videos[index] = videos[index].replacingFeedMetadata(with: cached)
            } else {
                candidateIndexes.append(index)
            }
        }

        var unreliablePublishedDateIDs = Set(
            candidateIndexes.dropFirst(Self.maximumEnrichmentCount).map { videos[$0].id }
        )
        candidateIndexes = Array(candidateIndexes.prefix(Self.maximumEnrichmentCount))
        guard !candidateIndexes.isEmpty else {
            return EnrichmentResult(videos: videos, unreliablePublishedDateIDs: [])
        }

        let outcomes = try await fetchVideoDetails(
            for: candidateIndexes.map { (index: $0, video: videos[$0]) },
            instance: instance
        )
        for outcome in outcomes {
            switch outcome {
            case .success(let index, let details):
                guard details.id == videos[index].id,
                      details.publishedAt != nil,
                      !Self.isSuspicious(details, relativeTo: refreshDate) else {
                    unreliablePublishedDateIDs.insert(videos[index].id)
                    continue
                }
                videos[index] = videos[index].replacingFeedMetadata(with: details)
            case .failure(let index):
                unreliablePublishedDateIDs.insert(videos[index].id)
            }
        }

        return EnrichmentResult(
            videos: videos,
            unreliablePublishedDateIDs: unreliablePublishedDateIDs
        )
    }

    private func fetchVideoDetails(
        for candidates: [(index: Int, video: Video)],
        instance: Instance
    ) async throws -> [EnrichmentOutcome] {
        try await withThrowingTaskGroup(of: EnrichmentOutcome.self) { group in
            var nextIndex = 0
            var outcomes: [EnrichmentOutcome] = []

            func addNextTask() {
                guard nextIndex < candidates.count else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let details = try await videoProvider.video(
                            id: candidate.video.id.videoID,
                            instance: instance
                        )
                        try Task.checkCancellation()
                        return .success(index: candidate.index, video: details)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .failure(index: candidate.index)
                    }
                }
            }

            for _ in 0..<min(Self.maximumConcurrentEnrichmentRequests, candidates.count) {
                addNextTask()
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                outcomes.append(outcome)
                addNextTask()
            }
            return outcomes
        }
    }

    private static func isSuspicious(_ video: Video, relativeTo refreshDate: Date) -> Bool {
        guard !video.isLive, !video.isUpcoming, let publishedAt = video.publishedAt else { return false }
        if publishedAt.timeIntervalSince(refreshDate) > futureDateTolerance { return true }
        return video.viewCount == 0
            && abs(publishedAt.timeIntervalSince(refreshDate)) <= refreshDateProximity
    }

    private static func hasReliableCachedMetadata(
        _ cached: Video,
        replacing suspect: Video,
        relativeTo refreshDate: Date
    ) -> Bool {
        guard cached.id == suspect.id,
              cached.publishedAt != nil,
              !isSuspicious(cached, relativeTo: refreshDate) else { return false }
        if let cachedViews = cached.viewCount, cachedViews > 0 { return true }
        guard let cachedDate = cached.publishedAt, let suspectDate = suspect.publishedAt else { return false }
        return abs(cachedDate.timeIntervalSince(suspectDate)) >= meaningfulCachedDateDifference
    }

    private func fetchLatestVideos(
        subscriptions: [InvidiousLocalFeedSubscription],
        instance: Instance
    ) async throws -> [FetchOutcome] {
        try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
            var nextIndex = 0
            var outcomes: [FetchOutcome] = []

            func addNextTask() {
                guard nextIndex < subscriptions.count else { return }
                let index = nextIndex
                let channelID = subscriptions[index].channelID
                nextIndex += 1

                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let videos = try await videoProvider.latestVideos(
                            channelID: channelID,
                            instance: instance
                        )
                        try Task.checkCancellation()
                        return .success(
                            SuccessfulFetch(subscriptionIndex: index, videos: videos)
                        )
                    } catch {
                        try Task.checkCancellation()
                        return .failure
                    }
                }
            }

            for _ in 0..<min(Self.maximumConcurrentRequests, subscriptions.count) {
                addNextTask()
            }

            while let outcome = try await group.next() {
                try Task.checkCancellation()
                outcomes.append(outcome)
                addNextTask()
            }

            return outcomes
        }
    }

    fileprivate static func isOrderedBefore(_ lhs: Video, _ rhs: Video) -> Bool {
        isOrderedBefore(lhs, rhs, ignoringPublishedDatesFor: [])
    }

    fileprivate static func isOrderedBefore(
        _ lhs: Video,
        _ rhs: Video,
        ignoringPublishedDatesFor unreliableIDs: Set<VideoID>
    ) -> Bool {
        let lhsDate = unreliableIDs.contains(lhs.id) ? nil : lhs.publishedAt
        let rhsDate = unreliableIDs.contains(rhs.id) ? nil : rhs.publishedAt
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.id.id < rhs.id.id
        }
    }
}

private extension InvidiousLocalFeedAggregator {
    struct EnrichmentResult: Sendable {
        let videos: [Video]
        let unreliablePublishedDateIDs: Set<VideoID>
    }

    enum EnrichmentOutcome: Sendable {
        case success(index: Int, video: Video)
        case failure(index: Int)
    }

    struct SuccessfulFetch: Sendable {
        let subscriptionIndex: Int
        let videos: [Video]
    }

    enum FetchOutcome: Sendable {
        case success(SuccessfulFetch)
        case failure
    }
}

private extension Video {
    func replacingFeedMetadata(with source: Video) -> Video {
        Video(
            id: id,
            title: title,
            description: description,
            author: author,
            duration: duration,
            publishedAt: source.publishedAt,
            publishedText: source.publishedText,
            viewCount: source.viewCount,
            likeCount: likeCount,
            thumbnails: thumbnails,
            isLive: isLive,
            isUpcoming: isUpcoming,
            contentKind: contentKind,
            scheduledStartTime: scheduledStartTime,
            relatedVideos: relatedVideos
        )
    }
}
