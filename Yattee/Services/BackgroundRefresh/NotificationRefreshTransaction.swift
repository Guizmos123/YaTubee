//
//  NotificationRefreshTransaction.swift
//  Yattee
//
//  Pure transaction planning for background feed notifications.
//

import Foundation

struct NotificationRefreshCandidate: Equatable, Sendable {
    let deduplicationKey: String
    let legacyVideoID: String
    let publishedAt: Date?
    let isUpcoming: Bool
    let isWatched: Bool
    let contentKind: VideoContentKind
}

struct PendingNotificationRecord: Codable, Sendable {
    let video: Video
    let channelName: String
    let queuedAt: TimeInterval
}

struct NotificationRefreshRunState: Sendable {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func end() {
        isRunning = false
    }
}

struct NotificationRefreshPersistentState: Codable, Sendable {
    var lastCheck: Date?
    var processedVideos: [String: TimeInterval]
    var pendingVideos: [String: TimeInterval]
    var pendingRecords: [String: PendingNotificationRecord]
}

/// Stable storage partition for one subscription account and its selected instance.
enum NotificationRefreshScope {
    static func key(for account: SubscriptionAccount) -> String {
        switch account.type {
        case .local:
            return "local"
        case .invidious, .piped:
            return "\(account.type.rawValue):\(account.instanceID?.uuidString ?? "unconfigured")"
        }
    }
}

struct NotificationRefreshPlan: Equatable, Sendable {
    let requestStartedAt: Date
    let previousCheck: Date?
    let eligibleKeys: [String]
    let ignoredKeys: [String]
    let deferredKeys: [String]
    let isInitialBaseline: Bool
}

enum NotificationRefreshTransaction {
    static let maximumProcessedVideoCount = 512

    static func isCompleteYatteeServerResponse(_ response: StatelessFeedResponse) -> Bool {
        response.isReady
            && (response.pendingCount ?? 0) == 0
            && (response.errorCount ?? 0) == 0
    }

    static func boundedPendingRecords(
        _ records: [String: PendingNotificationRecord]
    ) -> [String: PendingNotificationRecord] {
        Dictionary(
            uniqueKeysWithValues: records
                .sorted { lhs, rhs in
                    if lhs.value.queuedAt == rhs.value.queuedAt { return lhs.key < rhs.key }
                    return lhs.value.queuedAt > rhs.value.queuedAt
                }
                .prefix(maximumProcessedVideoCount)
                .map { ($0.key, $0.value) }
        )
    }

    static func plan(
        candidates: [NotificationRefreshCandidate],
        requestStartedAt: Date,
        previousCheck: Date?,
        processedKeys: Set<String>,
        legacyProcessedVideoIDs: Set<String>,
        pendingKeys: Set<String>,
        includeShorts: Bool
    ) -> NotificationRefreshPlan {
        guard let previousCheck else {
            return NotificationRefreshPlan(
                requestStartedAt: requestStartedAt,
                previousCheck: nil,
                eligibleKeys: [],
                ignoredKeys: [],
                deferredKeys: [],
                isInitialBaseline: true
            )
        }

        var seenKeys = processedKeys
        var eligibleKeys: [String] = []
        var ignoredKeys: [String] = []
        var deferredKeys: [String] = []

        for candidate in candidates.sorted(by: candidateOrdering) {
            guard let publishedAt = candidate.publishedAt else {
                if seenKeys.insert(candidate.deduplicationKey).inserted {
                    ignoredKeys.append(candidate.deduplicationKey)
                }
                continue
            }
            let isPending = pendingKeys.contains(candidate.deduplicationKey)
            guard isPending || publishedAt > previousCheck else { continue }
            guard publishedAt <= requestStartedAt else {
                // Published while this request was in flight. The next request starts
                // from requestStartedAt, so this candidate remains inside its window.
                continue
            }
            guard !seenKeys.contains(candidate.deduplicationKey),
                  !legacyProcessedVideoIDs.contains(candidate.legacyVideoID) else {
                continue
            }
            guard includeShorts || candidate.contentKind != .short else {
                seenKeys.insert(candidate.deduplicationKey)
                ignoredKeys.append(candidate.deduplicationKey)
                continue
            }
            guard !candidate.isUpcoming else {
                deferredKeys.append(candidate.deduplicationKey)
                continue
            }
            guard !candidate.isWatched else {
                seenKeys.insert(candidate.deduplicationKey)
                ignoredKeys.append(candidate.deduplicationKey)
                continue
            }

            seenKeys.insert(candidate.deduplicationKey)
            eligibleKeys.append(candidate.deduplicationKey)
        }

        return NotificationRefreshPlan(
            requestStartedAt: requestStartedAt,
            previousCheck: previousCheck,
            eligibleKeys: eligibleKeys,
            ignoredKeys: ignoredKeys,
            deferredKeys: deferredKeys,
            isInitialBaseline: false
        )
    }

    static func committedState(
        for plan: NotificationRefreshPlan,
        submissionAccepted: Bool,
        existingProcessedVideos: [String: TimeInterval],
        existingPendingVideos: [String: TimeInterval]
    ) -> (
        lastCheck: Date?,
        processedVideos: [String: TimeInterval],
        pendingVideos: [String: TimeInterval]
    ) {
        if plan.isInitialBaseline {
            return (plan.requestStartedAt, existingProcessedVideos, existingPendingVideos)
        }

        var processedVideos = existingProcessedVideos
        var pendingVideos = existingPendingVideos
        for key in plan.ignoredKeys {
            processedVideos[key] = plan.requestStartedAt.timeIntervalSince1970
            pendingVideos.removeValue(forKey: key)
        }
        for key in plan.deferredKeys {
            pendingVideos[key] = plan.requestStartedAt.timeIntervalSince1970
        }
        if submissionAccepted {
            for key in plan.eligibleKeys {
                processedVideos[key] = plan.requestStartedAt.timeIntervalSince1970
                pendingVideos.removeValue(forKey: key)
            }
        } else {
            for key in plan.eligibleKeys {
                pendingVideos[key] = plan.requestStartedAt.timeIntervalSince1970
            }
        }

        processedVideos = bounded(processedVideos)
        pendingVideos = bounded(pendingVideos)
        return (plan.requestStartedAt, processedVideos, pendingVideos)
    }

    private static func bounded(_ values: [String: TimeInterval]) -> [String: TimeInterval] {
        Dictionary(
            uniqueKeysWithValues: values
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(maximumProcessedVideoCount)
                .map { ($0.key, $0.value) }
        )
    }

    private static func candidateOrdering(
        _ lhs: NotificationRefreshCandidate,
        _ rhs: NotificationRefreshCandidate
    ) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        default:
            return lhs.deduplicationKey < rhs.deduplicationKey
        }
    }
}
