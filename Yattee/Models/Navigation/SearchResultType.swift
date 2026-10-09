//
//  SearchResultType.swift
//  Yattee
//
//  Search result type filter definitions.
//

import Foundation

/// Search result type filter.
enum SearchResultType: String, CaseIterable, Identifiable {
    case all
    case videos
    case channels
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return AppLocalization.string("search.filter.all")
        case .videos: return AppLocalization.string("search.filter.videos")
        case .channels: return AppLocalization.string("search.filter.channels")
        case .playlists: return AppLocalization.string("search.filter.playlists")
        }
    }
}
