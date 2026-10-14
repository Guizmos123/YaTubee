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

    private let defaults: UserDefaults
    private let storageKey: String
    private var excludedChannelIDsByScope: [String: Set<String>]

    init(defaults: UserDefaults = .standard, storageKey: String = ChannelBadgePreferences.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            excludedChannelIDsByScope = decoded
        } else {
            excludedChannelIDsByScope = [:]
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
        persist()
    }

    func excludedChannelIDs(in scope: FeedNoveltyScope?) -> Set<String> {
        guard let scope else { return [] }
        return excludedChannelIDsByScope[scope.rawValue] ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(excludedChannelIDsByScope) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
