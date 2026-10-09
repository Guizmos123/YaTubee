//
//  PlayerInfoTab.swift
//  Yattee
//
//  Player info tab definitions.
//

import Foundation

enum PlayerInfoTab: String, CaseIterable {
    case description
    case comments

    var title: String {
        switch self {
        case .description: return AppLocalization.string("player.description")
        case .comments: return AppLocalization.string("player.comments")
        }
    }
}
