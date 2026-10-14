//
//  MiniPlayerSettings.swift
//  Yattee
//
//  Settings for the mini player component.
//

import Foundation
import SwiftUI

// MARK: - Mini Player Style

/// Visual presentation used by the mini player.
enum MiniPlayerStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case bar
    case video
    case bubble

    /// Whether Settings should expose the shared customizable button list.
    var supportsCustomizableButtons: Bool {
        self != .bubble
    }
}

// MARK: - Mini Player Presentation

/// The single container that should host the mini player for the current style.
enum MiniPlayerPresentation: Equatable, Sendable {
    case tabAccessory
    case prominentTab
    case rootOverlay

    /// Resolves the presentation without changing the selected visual style.
    /// Bubble temporarily follows Bar until its dedicated renderer is implemented.
    static func resolve(
        style: MiniPlayerStyle,
        supportsTabAccessory: Bool,
        supportsProminentTab: Bool = false
    ) -> MiniPlayerPresentation {
        if style == .bubble, supportsProminentTab {
            return .prominentTab
        }
        guard supportsTabAccessory, style != .video else {
            return .rootOverlay
        }
        return .tabAccessory
    }
}

/// Shared geometry for the non-bar mini player styles.
/// Bar metrics remain owned by the existing bar implementation.
enum MiniPlayerStyleMetrics {
    static let videoAspectRatio: CGFloat = 16.0 / 9.0
    static let recommendedBubbleDiameter: CGFloat = 72
}

// MARK: - MiniPlayerSettings

/// Complete settings for the mini player component.
/// Note: Minimize behavior is intentionally NOT stored here as it's a system UI setting
/// that configures the tab bar and needs to be available synchronously at view creation time.
/// The minimize behavior remains in SettingsManager for the tab bar to access directly.
struct MiniPlayerSettings: Codable, Hashable, Sendable {
    /// Visual presentation of the mini player.
    var style: MiniPlayerStyle

    /// Whether to show video preview in the mini player.
    var showVideo: Bool

    /// Action to perform when tapping on the video preview.
    var videoTapAction: MiniPlayerVideoTapAction

    /// Ordered list of buttons to display in the mini player.
    var buttons: [ControlButtonConfiguration]

    /// Ordered subset supported by the floating Video presentation.
    /// Bar keeps using the complete configurable list.
    var videoButtons: [ControlButtonConfiguration] {
        Self.videoButtons(from: buttons)
    }

    static func videoButtons(
        from buttons: [ControlButtonConfiguration]
    ) -> [ControlButtonConfiguration] {
        buttons.filter { configuration in
            switch configuration.buttonType {
            case .playPause, .close, .pictureInPicture, .airplay:
                true
            default:
                false
            }
        }
    }

    // MARK: - Initialization

    init(
        style: MiniPlayerStyle = .bar,
        showVideo: Bool = true,
        videoTapAction: MiniPlayerVideoTapAction = .startPiP,
        buttons: [ControlButtonConfiguration] = MiniPlayerSettings.defaultButtons
    ) {
        self.style = style
        self.showVideo = showVideo
        self.videoTapAction = videoTapAction
        self.buttons = buttons
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case style
        case showVideo
        case videoTapAction
        case buttons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decodeIfPresent(MiniPlayerStyle.self, forKey: .style)) ?? .bar
        showVideo = try container.decode(Bool.self, forKey: .showVideo)
        videoTapAction = try container.decode(MiniPlayerVideoTapAction.self, forKey: .videoTapAction)
        buttons = try container.decode([ControlButtonConfiguration].self, forKey: .buttons)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encode(showVideo, forKey: .showVideo)
        try container.encode(videoTapAction, forKey: .videoTapAction)
        try container.encode(buttons, forKey: .buttons)
    }

    // MARK: - Mutation Helpers

    /// Adds a button of the given type to the mini player.
    /// - Parameter buttonType: The type of button to add.
    mutating func add(buttonType: ControlButtonType) {
        let config = ControlButtonConfiguration(buttonType: buttonType)
        buttons.append(config)
    }

    /// Removes the button at the given index.
    /// - Parameter index: The index of the button to remove.
    mutating func remove(at index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons.remove(at: index)
    }

    /// Moves buttons within the list.
    /// - Parameters:
    ///   - source: Source indices to move from.
    ///   - destination: Destination index to move to.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        buttons.move(fromOffsets: source, toOffset: destination)
    }

    /// Updates a button configuration by matching ID.
    /// - Parameter configuration: The updated configuration.
    mutating func update(_ configuration: ControlButtonConfiguration) {
        guard let index = buttons.firstIndex(where: { $0.id == configuration.id }) else { return }
        buttons[index] = configuration
    }

    // MARK: - Default Configuration

    /// Default buttons for the mini player: play/pause and play next.
    private static let defaultButtons: [ControlButtonConfiguration] = [
        ControlButtonConfiguration(buttonType: .playPause),
        ControlButtonConfiguration(buttonType: .playNext),
        ControlButtonConfiguration(buttonType: .close)
    ]

    /// Default mini player settings.
    static let `default` = MiniPlayerSettings()

    /// Cached settings for instant access (avoids flash on view recreation).
    /// Updated whenever settings are loaded from the active preset.
    nonisolated(unsafe) static var cached: MiniPlayerSettings = .default
}
