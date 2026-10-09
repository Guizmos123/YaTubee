//
//  TapZonePosition.swift
//  Yattee
//
//  Defines the position identifiers for tap zones.
//

import Foundation

/// Position identifier for a tap zone within a layout.
enum TapZonePosition: String, Codable, CaseIterable, Sendable, Identifiable {
    // Single layout
    case full

    // Horizontal split (2x1)
    case left
    case right

    // Vertical split (1x2)
    case top
    case bottom

    // Three columns (1x3)
    case leftThird
    case center
    case rightThird

    // Quadrants (2x2)
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    /// Display name for the zone position.
    var displayName: String {
        switch self {
        case .full:
            AppLocalization.string("gestures.zone.full", defaultValue: "Tap Zone")
        case .left:
            AppLocalization.string("gestures.zone.left", defaultValue: "Left")
        case .right:
            AppLocalization.string("gestures.zone.right", defaultValue: "Right")
        case .top:
            AppLocalization.string("gestures.zone.top", defaultValue: "Top")
        case .bottom:
            AppLocalization.string("gestures.zone.bottom", defaultValue: "Bottom")
        case .leftThird:
            AppLocalization.string("gestures.zone.leftThird", defaultValue: "Left")
        case .center:
            AppLocalization.string("gestures.zone.center", defaultValue: "Center")
        case .rightThird:
            AppLocalization.string("gestures.zone.rightThird", defaultValue: "Right")
        case .topLeft:
            AppLocalization.string("gestures.zone.topLeft", defaultValue: "Top-Left")
        case .topRight:
            AppLocalization.string("gestures.zone.topRight", defaultValue: "Top-Right")
        case .bottomLeft:
            AppLocalization.string("gestures.zone.bottomLeft", defaultValue: "Bottom-Left")
        case .bottomRight:
            AppLocalization.string("gestures.zone.bottomRight", defaultValue: "Bottom-Right")
        }
    }
}
