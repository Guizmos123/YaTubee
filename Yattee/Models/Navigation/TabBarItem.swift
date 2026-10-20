//
//  TabBarItem.swift
//  Yattee
//
//  Configurable tab bar item definitions for compact size class navigation.
//

import Foundation

/// Represents a configurable tab bar item for compact width (iPhone, iPad small window).
enum TabBarItem: String, CaseIterable, Codable, Identifiable, Sendable {
    case subscriptions
    case channels
    case hub
    case bookmarks
    case playlists
    case history
    case downloads
    case sources
    case settings
    case continueWatching

    var id: String { rawValue }

    /// Default order for tab bar items.
    static var defaultOrder: [TabBarItem] {
        [.subscriptions, .channels, .hub, .bookmarks, .playlists, .history, .continueWatching, .sources, .downloads, .settings]
    }

    /// Default visibility (only subscriptions visible by default).
    static var defaultVisibility: [TabBarItem: Bool] {
        [.subscriptions: false, .channels: false, .hub: true, .bookmarks: false, .playlists: false, .history: false, .downloads: true, .sources: true, .settings: false, .continueWatching: false]
    }

    /// SF Symbol icon name.
    var icon: String {
        switch self {
        case .subscriptions: "list.bullet.rectangle.fill"
        case .channels: "person.crop.rectangle.stack.fill"
        case .hub: "circle.grid.2x2"
        case .bookmarks: "bookmark.fill"
        case .playlists: "list.bullet.rectangle"
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .sources: "server.rack"
        case .settings: "gear"
        case .continueWatching: "play.circle"
        }
    }

    /// Localized display title.
    var localizedTitle: String {
        switch self {
        case .subscriptions: AppLocalization.string("tabBar.item.subscriptions")
        case .channels: AppLocalization.string("tabBar.item.channels")
        case .hub: AppLocalization.string("tabs.hub")
        case .bookmarks: AppLocalization.string("tabBar.item.bookmarks")
        case .playlists: AppLocalization.string("tabBar.item.playlists")
        case .history: AppLocalization.string("tabBar.item.history")
        case .downloads: AppLocalization.string("tabBar.item.downloads")
        case .sources: AppLocalization.string("tabBar.item.sources")
        case .settings: AppLocalization.string("tabBar.item.settings")
        case .continueWatching: AppLocalization.string("tabBar.item.continueWatching")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let storedValue = try container.decode(String.self)
        let rawValue = storedValue == "more" ? "hub" : storedValue

        guard let item = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown tab bar item: \(storedValue)"
            )
        }
        self = item
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
