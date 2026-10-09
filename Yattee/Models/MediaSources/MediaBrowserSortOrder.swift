//
//  MediaBrowserSortOrder.swift
//  Yattee
//
//  Sort order options for media browser file listing.
//

import Foundation

enum MediaBrowserSortOrder: String, CaseIterable, Identifiable {
    case name
    case dateModified
    case dateCreated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            AppLocalization.string("mediaBrowser.sort.name")
        case .dateModified:
            AppLocalization.string("mediaBrowser.sort.dateModified")
        case .dateCreated:
            AppLocalization.string("mediaBrowser.sort.dateCreated")
        }
    }

    var systemImage: String {
        switch self {
        case .name:
            "textformat"
        case .dateModified:
            "clock"
        case .dateCreated:
            "calendar"
        }
    }

    /// Returns available sort options for a given source type.
    /// WebDAV and SMB sources don't support creation date, so it's excluded.
    static func availableOptions(for sourceType: MediaSourceType) -> [MediaBrowserSortOrder] {
        switch sourceType {
        case .localFolder:
            allCases
        case .webdav, .smb:
            [.name, .dateModified]
        }
    }
}
