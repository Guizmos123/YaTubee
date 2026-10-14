//
//  InvidiousFeedShortsClassifier.swift
//  Yattee
//
//  Positively identifies Shorts in authenticated Invidious feed pages.
//

import Foundation

protocol InvidiousChannelShortsProviding: Sendable {
    func firstShortsPage(channelID: String, instance: Instance) async throws -> [Video]
}

extension ContentService: InvidiousChannelShortsProviding {
    func firstShortsPage(channelID: String, instance: Instance) async throws -> [Video] {
        try await channelShorts(id: channelID, instance: instance, continuation: nil).videos
    }
}

actor InvidiousFeedShortsClassifier {
    static let shared = InvidiousFeedShortsClassifier()
    static let freshnessInterval: TimeInterval = 6 * 60 * 60
    static let maximumConcurrentRequests = 4

    private struct Key: Hashable {
        let instanceID: UUID
        let channelID: String
    }

    private struct Entry {
        let videoIDs: Set<VideoID>
        let fetchedAt: Date
    }

    private var cache: [Key: Entry] = [:]

    func excludingConfirmedShorts(
        from videos: [Video],
        instance: Instance,
        provider: any InvidiousChannelShortsProviding,
        now: Date = Date()
    ) async throws -> [Video] {
        let channelIDs = Array(Set(videos.map(\.author.id))).sorted()
        var confirmedShortIDs = Set<VideoID>()
        var missingChannels: [String] = []

        for channelID in channelIDs {
            let key = Key(instanceID: instance.id, channelID: channelID)
            if let entry = cache[key], now.timeIntervalSince(entry.fetchedAt) < Self.freshnessInterval {
                confirmedShortIDs.formUnion(entry.videoIDs)
            } else {
                missingChannels.append(channelID)
            }
        }

        let fetched = try await fetch(
            channelIDs: missingChannels,
            instance: instance,
            provider: provider
        )
        for result in fetched {
            guard case .success(let channelID, let ids) = result else { continue }
            cache[Key(instanceID: instance.id, channelID: channelID)] = Entry(videoIDs: ids, fetchedAt: now)
            confirmedShortIDs.formUnion(ids)
        }

        return videos.filter { !confirmedShortIDs.contains($0.id) }
    }

    private func fetch(
        channelIDs: [String],
        instance: Instance,
        provider: any InvidiousChannelShortsProviding
    ) async throws -> [Outcome] {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var nextIndex = 0
            var outcomes: [Outcome] = []

            func addNext() {
                guard nextIndex < channelIDs.count else { return }
                let channelID = channelIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let shorts = try await provider.firstShortsPage(channelID: channelID, instance: instance)
                        try Task.checkCancellation()
                        return .success(channelID, Set(shorts.map(\.id)))
                    } catch {
                        try Task.checkCancellation()
                        return .failure
                    }
                }
            }

            for _ in 0..<min(Self.maximumConcurrentRequests, channelIDs.count) { addNext() }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                outcomes.append(outcome)
                addNext()
            }
            return outcomes
        }
    }

    private enum Outcome: Sendable {
        case success(String, Set<VideoID>)
        case failure
    }
}
