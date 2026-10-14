//
//  SubscriptionSyncSnapshot.swift
//  Yattee
//
//  Source-scoped diagnostic snapshot for subscription feed refreshes.
//

import Foundation

struct SubscriptionSyncSnapshot: Codable, Hashable, Sendable {
    struct Source: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Hashable, Sendable {
            case yatteeServer
            case invidious
        }

        let kind: Kind
        let instanceID: UUID
        let instanceURL: URL
    }

    struct Channel: Codable, Hashable, Sendable {
        enum State: String, Codable, Hashable, Sendable {
            case success
            case pending
            case failure
            case unknown
        }

        let channelID: String
        let site: String
        let channelName: String
        let state: State
        let errorDescription: String?
        let lastRequestedAt: Date?
        let lastFetchedAt: Date?
        let requestCompletedAt: Date?
        let videoCount: Int?
    }

    let source: Source
    let refreshStartedAt: Date
    let refreshFinishedAt: Date
    let channels: [Channel]
    let serverInformationObservedAt: Date?
    let observationError: String?
    let serverFeedFetchIntervalSeconds: TimeInterval?

    init(
        source: Source,
        refreshStartedAt: Date,
        refreshFinishedAt: Date,
        channels: [Channel],
        serverInformationObservedAt: Date?,
        observationError: String?,
        serverFeedFetchIntervalSeconds: TimeInterval? = nil
    ) {
        self.source = source
        self.refreshStartedAt = refreshStartedAt
        self.refreshFinishedAt = refreshFinishedAt
        self.channels = channels
        self.serverInformationObservedAt = serverInformationObservedAt
        self.observationError = observationError
        self.serverFeedFetchIntervalSeconds = serverFeedFetchIntervalSeconds
    }

    var totalChannelCount: Int { channels.count }
    var successfulChannelCount: Int { channels.filter { $0.state == .success }.count }
    var pendingChannelCount: Int { channels.filter { $0.state == .pending }.count }
    var failedChannelCount: Int { channels.filter { $0.state == .failure }.count }
    var unknownChannelCount: Int { channels.filter { $0.state == .unknown }.count }

    var cacheScopeKey: String {
        "local:\(source.kind.rawValue):\(source.instanceID.uuidString)"
    }

    /// Migrates snapshots written by the former timestamp-based Yattee Server
    /// classification without changing snapshots from other sources.
    var normalizedForCurrentSemantics: SubscriptionSyncSnapshot {
        guard source.kind == .yatteeServer else { return self }
        let normalizedChannels = channels.map { channel in
            guard channel.state == .pending else { return channel }
            let hasError = channel.errorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            return Channel(
                channelID: channel.channelID,
                site: channel.site,
                channelName: channel.channelName,
                state: hasError ? .failure : (channel.lastFetchedAt == nil ? .unknown : .success),
                errorDescription: channel.errorDescription,
                lastRequestedAt: channel.lastRequestedAt,
                lastFetchedAt: channel.lastFetchedAt,
                requestCompletedAt: channel.requestCompletedAt,
                videoCount: channel.videoCount
            )
        }
        return SubscriptionSyncSnapshot(
            source: source,
            refreshStartedAt: refreshStartedAt,
            refreshFinishedAt: refreshFinishedAt,
            channels: normalizedChannels,
            serverInformationObservedAt: serverInformationObservedAt,
            observationError: observationError,
            serverFeedFetchIntervalSeconds: serverFeedFetchIntervalSeconds
        )
    }
}

enum YatteeServerSyncClassification {
    static func snapshot(
        source: SubscriptionSyncSnapshot.Source,
        requestedChannels: [StatelessChannelRequest],
        watchedChannels: [WatchedChannelStatus],
        refreshStartedAt: Date,
        refreshFinishedAt: Date,
        observedAt: Date,
        observationError: String? = nil,
        serverFeedFetchIntervalSeconds: TimeInterval? = nil
    ) -> SubscriptionSyncSnapshot {
        let watchedByKey = Dictionary(
            watchedChannels.map { (key(site: $0.site, channelID: $0.channelId), $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        let channels = requestedChannels.map { requested in
            let watched = watchedByKey[key(site: requested.site, channelID: requested.channelId)]
            let lastFetch = watched?.lastFetch
            let error = watched?.fetchError?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasError = error?.isEmpty == false

            let state: SubscriptionSyncSnapshot.Channel.State
            if hasError {
                state = .failure
            } else if lastFetch != nil {
                state = .success
            } else {
                state = .unknown
            }

            return SubscriptionSyncSnapshot.Channel(
                channelID: requested.channelId,
                site: requested.site,
                channelName: watched?.channelName ?? requested.channelName ?? requested.channelId,
                state: state,
                errorDescription: hasError ? error : nil,
                lastRequestedAt: watched?.lastRequested,
                lastFetchedAt: watched?.lastFetch,
                requestCompletedAt: nil,
                videoCount: watched?.videoCount
            )
        }

        return SubscriptionSyncSnapshot(
            source: source,
            refreshStartedAt: refreshStartedAt,
            refreshFinishedAt: refreshFinishedAt,
            channels: channels,
            serverInformationObservedAt: observedAt,
            observationError: observationError,
            serverFeedFetchIntervalSeconds: serverFeedFetchIntervalSeconds
        )
    }

    private static func key(site: String, channelID: String) -> String {
        "\(site.lowercased())\u{1F}\(channelID)"
    }
}
