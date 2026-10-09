//
//  ControlButtonType.swift
//  Yattee
//
//  Defines all available control button types for player customization.
//

import Foundation

/// All available control button types for player layout customization.
enum ControlButtonType: String, Codable, Hashable, Sendable, CaseIterable {
    case close
    case airplay
    case mpvDebug
    case brightness
    case volume
    case pictureInPicture
    case fullscreen
    case playbackSpeed
    case videoTrack
    case audioTrack
    case captions
    case chapters
    case share
    case addToPlaylist
    case contextMenu
    case spacer
    case timeDisplay
    case seekBackward
    case seekForward
    case playPause
    case orientationLock
    case panelToggle
    case playPrevious
    case playNext
    case queue
    case settings
    case controlsLock
    case titleAuthor
    case panscan
    case autoPlayNext
    case audioMode
    case seek
    case keepOnTop

    // MARK: - Version Tracking

    /// The app version when this button was added.
    /// Used for showing "NEW" badges on recently added buttons.
    var versionAdded: Int {
        // No need to add versions yet
        return 1
    }

    // MARK: - Display Properties

    /// Localized display name for the button.
    var displayName: String {
        switch self {
        case .close:
            return AppLocalization.string("controls.button.close")
        case .airplay:
            return AppLocalization.string("controls.button.airplay")
        case .mpvDebug:
            return AppLocalization.string("controls.button.debug")
        case .brightness:
            return AppLocalization.string("controls.button.brightness")
        case .volume:
            return AppLocalization.string("controls.button.volume")
        case .pictureInPicture:
            return AppLocalization.string("controls.button.pip")
        case .fullscreen:
            return AppLocalization.string("controls.button.fullscreen")
        case .playbackSpeed:
            return AppLocalization.string("controls.button.speed")
        case .videoTrack:
            return AppLocalization.string("controls.button.videoTrack")
        case .audioTrack:
            return AppLocalization.string("controls.button.audioTrack")
        case .captions:
            return AppLocalization.string("controls.button.captions")
        case .chapters:
            return AppLocalization.string("controls.button.chapters")
        case .share:
            return AppLocalization.string("controls.button.share")
        case .addToPlaylist:
            return AppLocalization.string("controls.button.addToPlaylist")
        case .contextMenu:
            return AppLocalization.string("controls.button.more")
        case .spacer:
            return AppLocalization.string("controls.button.spacer")
        case .timeDisplay:
            return AppLocalization.string("controls.button.time")
        case .seekBackward:
            return AppLocalization.string("controls.button.seekBackward")
        case .seekForward:
            return AppLocalization.string("controls.button.seekForward")
        case .playPause:
            return AppLocalization.string("controls.button.playPause")
        case .orientationLock:
            return AppLocalization.string("controls.button.orientationLock")
        case .panelToggle:
            return AppLocalization.string("controls.button.panelToggle")
        case .playPrevious:
            return AppLocalization.string("controls.button.playPrevious")
        case .playNext:
            return AppLocalization.string("controls.button.playNext")
        case .queue:
            return AppLocalization.string("controls.button.queue")
        case .settings:
            return AppLocalization.string("controls.button.settings")
        case .controlsLock:
            return AppLocalization.string("controls.button.controlsLock")
        case .titleAuthor:
            return AppLocalization.string("controls.button.titleAuthor")
        case .panscan:
            return AppLocalization.string("controls.button.panscan")
        case .autoPlayNext:
            return AppLocalization.string("controls.button.autoPlayNext")
        case .audioMode:
            return AppLocalization.string("controls.button.audioMode")
        case .seek:
            return AppLocalization.string("controls.button.seek")
        case .keepOnTop:
            return AppLocalization.string("controls.button.keepOnTop")
        }
    }

    /// SF Symbol name for the button icon.
    var systemImage: String {
        switch self {
        case .close:
            return "xmark"
        case .airplay:
            return "airplayaudio"
        case .mpvDebug:
            return "info.circle"
        case .brightness:
            return "sun.max.fill"
        case .volume:
            return "speaker.wave.2.fill"
        case .pictureInPicture:
            return "pip.enter"
        case .fullscreen:
            return "arrow.up.left.and.arrow.down.right"
        case .playbackSpeed:
            return "gauge.with.needle"
        case .videoTrack:
            return "film"
        case .audioTrack:
            return "waveform"
        case .captions:
            return "captions.bubble"
        case .chapters:
            return "list.bullet.rectangle"
        case .share:
            return "square.and.arrow.up"
        case .addToPlaylist:
            return "text.badge.plus"
        case .contextMenu:
            return "ellipsis"
        case .spacer:
            return "arrow.left.and.right"
        case .timeDisplay:
            return "clock"
        case .seekBackward:
            return "10.arrow.trianglehead.counterclockwise"
        case .seekForward:
            return "10.arrow.trianglehead.clockwise"
        case .playPause:
            return "play.fill"
        case .orientationLock:
            return "lock.rotation"
        case .panelToggle:
            return "sidebar.trailing"
        case .playPrevious:
            return "backward.fill"
        case .playNext:
            return "forward.fill"
        case .queue:
            return "list.bullet"
        case .settings:
            return "gearshape"
        case .controlsLock:
            return "lock"
        case .titleAuthor:
            return "text.below.photo"
        case .panscan:
            return "arrow.left.and.right.square"
        case .autoPlayNext:
            return "play.square.stack.fill"
        case .audioMode:
            return "music.note"
        case .seek:
            return "goforward.10" // Default icon, actual icon is determined by settings
        case .keepOnTop:
            return "pin"
        }
    }

    // MARK: - Configuration

    /// Whether this button type has configurable settings.
    var hasSettings: Bool {
        switch self {
        case .spacer, .brightness, .volume, .seekBackward, .seekForward, .timeDisplay, .titleAuthor, .seek:
            return true
        default:
            return false
        }
    }

    /// Default settings for this button type, if applicable.
    var defaultSettings: ButtonSettings? {
        switch self {
        case .spacer:
            return .spacer(SpacerSettings())
        case .brightness, .volume:
            return .slider(SliderSettings())
        case .seekBackward, .seekForward:
            return .seek(SeekSettings())
        case .timeDisplay:
            return .timeDisplay(TimeDisplaySettings())
        case .titleAuthor:
            return .titleAuthor(TitleAuthorSettings())
        case .seek:
            return .seek(SeekSettings())
        default:
            return nil
        }
    }

    // MARK: - Section Availability

    /// Button types available for top/bottom sections.
    static var availableForHorizontalSections: [ControlButtonType] {
        #if os(macOS)
        [
            .spacer,
            .timeDisplay,
            .titleAuthor,
            .playPrevious,
            .playPause,
            .playNext,
            .seek,
            .queue,
            .close,
            .keepOnTop,
            .volume,
            .pictureInPicture,
            .fullscreen,
            .controlsLock,
            .settings,
            .playbackSpeed,
            .share,
            .contextMenu,
            .autoPlayNext,
            .audioMode,
            .mpvDebug
        ]
        #else
        [
            .spacer,
            .timeDisplay,
            .titleAuthor,
            .playPrevious,
            .playPause,
            .playNext,
            .seek,
            .queue,
            .close,
            .brightness,
            .volume,
            .pictureInPicture,
            .fullscreen,
            .orientationLock,
            .controlsLock,
            .settings,
            .videoTrack,
            .audioTrack,
            .captions,
            .chapters,
            .playbackSpeed,
            .addToPlaylist,
            .contextMenu,
            .share,
            .panelToggle,
            .panscan,
            .autoPlayNext,
            .audioMode,
            .airplay,
            .mpvDebug
        ]
        #endif
    }

    /// Button types for center section (play/pause, seek).
    static var availableForCenterSection: [ControlButtonType] {
        [.playPause, .seekBackward, .seekForward]
    }

    /// Button types available for the player pill (curated subset).
    static var availableForPill: [ControlButtonType] {
        [
            // Transport
            .playPause,
            .playPrevious,
            .playNext,
            .seek,
            // Queue & Playlist
            .queue,
            .addToPlaylist,
            // Player Actions
            .close,
            .share,
            .airplay,
            .pictureInPicture,
            // Utility
            .orientationLock,
            .playbackSpeed,
            .fullscreen
        ]
    }

    /// Button types available for the mini player (curated subset for compact UI).
    static var availableForMiniPlayer: [ControlButtonType] {
        #if os(macOS)
        [
            // Transport
            .playPause,
            .playPrevious,
            .playNext,
            .seek,
            // Queue & Actions
            .queue,
            .close,
            // Player Actions
            .share,
            .addToPlaylist,
            .pictureInPicture,
            // Utility
            .playbackSpeed,
            .audioMode
        ]
        #else
        [
            // Transport
            .playPause,
            .playPrevious,
            .playNext,
            .seek,
            // Queue & Actions
            .queue,
            .close,
            // Player Actions
            .share,
            .addToPlaylist,
            .airplay,
            .pictureInPicture,
            // Utility
            .playbackSpeed,
            .audioMode
        ]
        #endif
    }
}
