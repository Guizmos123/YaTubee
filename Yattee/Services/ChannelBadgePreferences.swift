//
//  ChannelBadgePreferences.swift
//  Yattee
//
//  Local account-scoped channel inclusion preferences for novelty badges.
//

import Foundation

@MainActor
@Observable
final class ChannelBadgePreferences {
    static let shared = ChannelBadgePreferences()

    private nonisolated static let storageKey = "channelBadgePreferences.excluded.v1"
    private nonisolated static let configuredStorageKey = "channelBadgePreferences.configured.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let configuredStorageKey: String
    private var excludedChannelIDsByScope: [String: Set<String>]
    private var configuredChannelIDsByScope: [String: Set<String>]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ChannelBadgePreferences.storageKey,
        configuredStorageKey: String? = nil
    ) {
        let resolvedConfiguredStorageKey = configuredStorageKey
            ?? (storageKey == Self.storageKey ? Self.configuredStorageKey : "\(storageKey).configured.v1")
        let storedExclusions: [String: Set<String>]
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            storedExclusions = decoded
        } else {
            storedExclusions = [:]
        }
        let storedConfiguredChannels: [String: Set<String>]?
        if let data = defaults.data(forKey: resolvedConfiguredStorageKey) {
            storedConfiguredChannels = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        } else {
            storedConfiguredChannels = nil
        }

        self.defaults = defaults
        self.storageKey = storageKey
        self.configuredStorageKey = resolvedConfiguredStorageKey
        excludedChannelIDsByScope = storedExclusions
        // Every legacy exclusion was an explicit per-channel choice. Marking
        // only those entries preserves all existing inclusion behavior.
        configuredChannelIDsByScope = storedConfiguredChannels ?? storedExclusions
        if storedConfiguredChannels == nil {
            persistConfiguredChannels()
        }
    }

    func isIncluded(channelID: String, in scope: FeedNoveltyScope) -> Bool {
        !excludedChannelIDs(in: scope).contains(channelID)
    }

    func setIncluded(_ included: Bool, channelID: String, in scope: FeedNoveltyScope) {
        var excluded = excludedChannelIDs(in: scope)
        if included {
            excluded.remove(channelID)
        } else {
            excluded.insert(channelID)
        }

        if excluded.isEmpty {
            excludedChannelIDsByScope.removeValue(forKey: scope.rawValue)
        } else {
            excludedChannelIDsByScope[scope.rawValue] = excluded
        }
        configuredChannelIDsByScope[scope.rawValue, default: []].insert(channelID)
        persist()
        persistConfiguredChannels()
    }

    /// Applies the default only once, when a subscription is first observed as
    /// newly added. Existing and explicitly configured channels are untouched.
    func applyDefault(
        includeByDefault: Bool,
        channelIDs: Set<String>,
        in scope: FeedNoveltyScope
    ) {
        guard !channelIDs.isEmpty else { return }
        var configured = configuredChannelIDsByScope[scope.rawValue] ?? []
        let unconfigured = channelIDs.subtracting(configured)
        guard !unconfigured.isEmpty else { return }

        configured.formUnion(unconfigured)
        configuredChannelIDsByScope[scope.rawValue] = configured
        if !includeByDefault {
            excludedChannelIDsByScope[scope.rawValue, default: []].formUnion(unconfigured)
        }
        persist()
        persistConfiguredChannels()
    }

    func excludedChannelIDs(in scope: FeedNoveltyScope?) -> Set<String> {
        guard let scope else { return [] }
        if excludedChannelIDsByScope[scope.rawValue] == nil,
           let legacyKey = scope.legacyRawValues.first(where: { excludedChannelIDsByScope[$0] != nil }),
           let legacyExclusions = excludedChannelIDsByScope.removeValue(forKey: legacyKey) {
            excludedChannelIDsByScope[scope.rawValue] = legacyExclusions
            persist()
        }
        if configuredChannelIDsByScope[scope.rawValue] == nil,
           let legacyKey = scope.legacyRawValues.first(where: { configuredChannelIDsByScope[$0] != nil }),
           let legacyConfigured = configuredChannelIDsByScope.removeValue(forKey: legacyKey) {
            configuredChannelIDsByScope[scope.rawValue] = legacyConfigured
            persistConfiguredChannels()
        }
        return excludedChannelIDsByScope[scope.rawValue] ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(excludedChannelIDsByScope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func persistConfiguredChannels() {
        guard let data = try? JSONEncoder().encode(configuredChannelIDsByScope) else { return }
        defaults.set(data, forKey: configuredStorageKey)
    }
}
