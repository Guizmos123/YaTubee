//
//  FeedNoveltyRegistry.swift
//  Yattee
//
//  Persistent, account-scoped registry of subscription feed novelties.
//

import CryptoKit
import Foundation
import Observation

/// Stable local partition for one subscription account session.
struct FeedNoveltyScope: Hashable, Sendable {
    let rawValue: String

    static func key(for account: SubscriptionAccount, credential: String? = nil) -> FeedNoveltyScope {
        switch account.type {
        case .local:
            return FeedNoveltyScope(rawValue: "local")
        case .invidious, .piped:
            let instance = account.instanceID?.uuidString ?? "unconfigured"
            guard let credential, !credential.isEmpty else {
                return FeedNoveltyScope(rawValue: "\(account.type.rawValue):\(instance):unauthenticated")
            }
            let digest = SHA256.hash(data: Data(credential.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return FeedNoveltyScope(rawValue: "\(account.type.rawValue):\(instance):\(digest)")
        }
    }

    @MainActor
    static func active(in appEnvironment: AppEnvironment?) -> FeedNoveltyScope? {
        guard let appEnvironment else { return nil }
        let account = appEnvironment.settingsManager.subscriptionAccount
        guard let instanceID = account.instanceID else {
            return key(for: account)
        }
        guard let instance = appEnvironment.instancesManager.instances.first(where: {
            $0.id == instanceID
        }) else {
            return key(for: account)
        }

        switch account.type {
        case .local:
            return key(for: account)
        case .invidious:
            return key(
                for: account,
                credential: appEnvironment.invidiousCredentialsManager.sid(for: instance)
            )
        case .piped:
            return key(
                for: account,
                credential: appEnvironment.pipedCredentialsManager.credential(for: instance)
            )
        }
    }
}

struct FeedNoveltyEntry: Codable, Equatable, Sendable {
    let videoID: String
    let channelID: String?
    let publishedAt: Date
    let discoveredAt: Date
    let contentKind: VideoContentKind
}

struct FeedNoveltySnapshot: Equatable, Sendable {
    let isInitialized: Bool
    let referenceDate: Date?
    let unconsulted: [FeedNoveltyEntry]

    var count: Int { unconsulted.count }
}

@MainActor
@Observable
final class FeedNoveltyBadgeState {
    static let shared = FeedNoveltyBadgeState()

    private var snapshots: [FeedNoveltyScope: FeedNoveltySnapshot] = [:]

    func count(for scope: FeedNoveltyScope?) -> Int {
        guard let scope else { return 0 }
        return snapshots[scope]?.count ?? 0
    }

    func count(for scope: FeedNoveltyScope?, excluding channelIDs: Set<String>) -> Int {
        guard let scope, let snapshot = snapshots[scope] else { return 0 }
        return snapshot.unconsulted.count { entry in
            guard let channelID = entry.channelID else { return true }
            return !channelIDs.contains(channelID)
        }
    }

    func update(_ snapshot: FeedNoveltySnapshot, for scope: FeedNoveltyScope) {
        snapshots[scope] = snapshot
    }
}

#if DEBUG
@MainActor
@Observable
final class FeedNoveltyBadgeDiagnosticState {
    static let shared = FeedNoveltyBadgeDiagnosticState()

    private(set) var scope: FeedNoveltyScope?
    private(set) var selectedVideoIDs: Set<String> = []
    private(set) var remainingVideoIDs: Set<String> = []

    var isActive: Bool { scope != nil }
    var selectedCount: Int { selectedVideoIDs.count }
    var remainingCount: Int { remainingVideoIDs.count }

    @discardableResult
    func start(videos: [Video], scope: FeedNoveltyScope, limit: Int = 10) -> Int {
        var uniqueIDs: [String] = []
        var seen = Set<String>()
        for video in videos where seen.insert(video.id.id).inserted {
            uniqueIDs.append(video.id.id)
            if uniqueIDs.count == limit { break }
        }

        self.scope = scope
        selectedVideoIDs = Set(uniqueIDs)
        remainingVideoIDs = Set(uniqueIDs)
        return uniqueIDs.count
    }

    func markVisible(videoIDs: Set<String>, in scope: FeedNoveltyScope) {
        guard self.scope == scope else { return }
        remainingVideoIDs.subtract(videoIDs)
    }

    func finish() {
        scope = nil
        selectedVideoIDs.removeAll()
        remainingVideoIDs.removeAll()
    }

    func finishIfContextChanged(
        scope: FeedNoveltyScope?,
        availableVideoIDs: Set<String>
    ) {
        guard isActive else { return }
        guard self.scope == scope, selectedVideoIDs.isSubset(of: availableVideoIDs) else {
            finish()
            return
        }
    }
}
#endif

enum FeedNoveltyConsultationPolicy {
    static func shouldConsult(
        isTabActive: Bool,
        isSceneActive: Bool,
        visibleVideoIDs: Set<String>
    ) -> Bool {
        isTabActive && isSceneActive && !visibleVideoIDs.isEmpty
    }
}

enum FeedNoveltyBadgePresentation {
    static func count(registryCount: Int, isEnabled: Bool) -> Int {
        isEnabled ? registryCount : 0
    }
}

private struct FeedNoveltyPersistentState: Codable, Sendable {
    var isInitialized = false
    var referenceDate: Date?
    var lastUpdatedAt: Date?
    var knownVideoIDs: [String: Date] = [:]
    var unconsulted: [String: FeedNoveltyEntry] = [:]
}

actor FeedNoveltyRegistry {
    static let shared = FeedNoveltyRegistry()

    static let maximumKnownVideoCount = 2_048
    static let maximumUnconsultedVideoCount = 512
    static let maximumScopeCount = 16

    private let defaults: UserDefaults
    private let storageKey: String
    private var states: [String: FeedNoveltyPersistentState]

    init(defaults: UserDefaults = .standard, storageKey: String = "feedNoveltyRegistry.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: FeedNoveltyPersistentState].self,
               from: data
           ) {
            states = decoded
        } else {
            states = [:]
        }
    }

    /// Ingests an existing feed response without performing any network work.
    /// Partial responses can add novelties after initialization, but can neither
    /// initialize a scope nor advance its reference date.
    func ingest(
        videos: [Video],
        baselineSupplement: [Video] = [],
        scope: FeedNoveltyScope,
        observedAt: Date,
        isCompleteSnapshot: Bool,
        includeShorts: Bool
    ) async {
        var state = states[scope.rawValue] ?? FeedNoveltyPersistentState()
        removeExcludedShorts(from: &state, includeShorts: includeShorts)

        if !state.isInitialized {
            guard isCompleteSnapshot else {
                state.lastUpdatedAt = observedAt
                states[scope.rawValue] = state
                pruneScopes(retaining: scope.rawValue)
                persist()
                await publishSnapshot(for: scope)
                return
            }

            for video in deduplicated(baselineSupplement + videos) {
                guard isPublished(video, at: observedAt) else { continue }
                state.knownVideoIDs[video.id.id] = observedAt
            }
            state.isInitialized = true
            state.referenceDate = observedAt
            state.lastUpdatedAt = observedAt
            prune(&state)
            states[scope.rawValue] = state
            pruneScopes(retaining: scope.rawValue)
            persist()
            await publishSnapshot(for: scope)
            return
        }

        let referenceDate = state.referenceDate ?? .distantPast
        for video in deduplicated(videos) {
            let key = video.id.id
            if let existing = state.unconsulted[key],
               existing.channelID == nil,
               !video.author.id.isEmpty {
                state.unconsulted[key] = FeedNoveltyEntry(
                    videoID: existing.videoID,
                    channelID: video.author.id,
                    publishedAt: existing.publishedAt,
                    discoveredAt: existing.discoveredAt,
                    contentKind: existing.contentKind
                )
            }
            guard state.knownVideoIDs[key] == nil else { continue }
            guard isPublished(video, at: observedAt), let publishedAt = video.publishedAt else {
                continue
            }

            // Late historical discoveries become known without becoming novelties.
            state.knownVideoIDs[key] = observedAt
            guard publishedAt > referenceDate else { continue }
            guard video.contentKind.isIncluded(whenIncludingShorts: includeShorts) else { continue }

            state.unconsulted[key] = FeedNoveltyEntry(
                videoID: key,
                channelID: video.author.id.isEmpty ? nil : video.author.id,
                publishedAt: publishedAt,
                discoveredAt: observedAt,
                contentKind: video.contentKind
            )
        }

        if isCompleteSnapshot {
            state.referenceDate = max(state.referenceDate ?? .distantPast, observedAt)
        }
        state.lastUpdatedAt = observedAt
        prune(&state)
        states[scope.rawValue] = state
        pruneScopes(retaining: scope.rawValue)
        persist()
        await publishSnapshot(for: scope)
    }

    /// Removes only the supplied visible identifiers from the unconsulted set.
    func markConsulted(videoIDs: Set<String>, in scope: FeedNoveltyScope) async {
        guard !videoIDs.isEmpty, var state = states[scope.rawValue] else { return }
        let previousCount = state.unconsulted.count
        for videoID in videoIDs {
            state.unconsulted.removeValue(forKey: videoID)
        }
        guard state.unconsulted.count != previousCount else { return }
        state.lastUpdatedAt = Date()
        states[scope.rawValue] = state
        pruneScopes(retaining: scope.rawValue)
        persist()
        await publishSnapshot(for: scope)
    }

    func synchronizeBadgeState(for scope: FeedNoveltyScope) async {
        await publishSnapshot(for: scope)
    }

    func snapshot(for scope: FeedNoveltyScope) -> FeedNoveltySnapshot {
        let state = states[scope.rawValue] ?? FeedNoveltyPersistentState()
        return FeedNoveltySnapshot(
            isInitialized: state.isInitialized,
            referenceDate: state.referenceDate,
            unconsulted: state.unconsulted.values.sorted {
                if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
                return $0.videoID < $1.videoID
            }
        )
    }

    private func isPublished(_ video: Video, at observedAt: Date) -> Bool {
        guard !video.isUpcoming, let publishedAt = video.publishedAt else { return false }
        return publishedAt <= observedAt
    }

    private func deduplicated(_ videos: [Video]) -> [Video] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.id.id).inserted }
    }

    private func removeExcludedShorts(
        from state: inout FeedNoveltyPersistentState,
        includeShorts: Bool
    ) {
        guard !includeShorts else { return }
        state.unconsulted = state.unconsulted.filter { $0.value.contentKind != .short }
    }

    private func prune(_ state: inout FeedNoveltyPersistentState) {
        state.unconsulted = Dictionary(
            uniqueKeysWithValues: state.unconsulted
                .sorted {
                    if $0.value.discoveredAt != $1.value.discoveredAt {
                        return $0.value.discoveredAt > $1.value.discoveredAt
                    }
                    return $0.key < $1.key
                }
                .prefix(Self.maximumUnconsultedVideoCount)
                .map { ($0.key, $0.value) }
        )

        let unconsultedKeys = Set(state.unconsulted.keys)
        let retainedKnown = state.knownVideoIDs
            .filter { !unconsultedKeys.contains($0.key) }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(max(0, Self.maximumKnownVideoCount - unconsultedKeys.count))

        state.knownVideoIDs = Dictionary(
            uniqueKeysWithValues: retainedKnown.map { ($0.key, $0.value) }
        )
        for key in unconsultedKeys {
            state.knownVideoIDs[key] = state.unconsulted[key]?.discoveredAt
        }
    }

    private func pruneScopes(retaining retainedScope: String) {
        guard states.count > Self.maximumScopeCount else { return }
        let removableScopes = states
            .filter { $0.key != retainedScope }
            .sorted {
                ($0.value.lastUpdatedAt ?? .distantPast) >
                    ($1.value.lastUpdatedAt ?? .distantPast)
            }
            .dropFirst(Self.maximumScopeCount - 1)
            .map(\.key)
        for scope in removableScopes {
            states.removeValue(forKey: scope)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func publishSnapshot(for scope: FeedNoveltyScope) async {
        let snapshot = snapshot(for: scope)
        await FeedNoveltyBadgeState.shared.update(snapshot, for: scope)
    }
}
