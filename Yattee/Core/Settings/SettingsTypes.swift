//
//  SettingsTypes.swift
//  Yattee
//
//  Type definitions for settings values.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Language

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case french = "fr"

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .english: "settings.language.english"
        case .french: "settings.language.french"
        }
    }
}

enum VideoMetadataLanguage: String, CaseIterable, Codable, Sendable {
    case original
    case application
    case french
    case english

    var displayName: LocalizedStringKey {
        switch self {
        case .original: "settings.language.video.original"
        case .application: "settings.language.video.application"
        case .french: "settings.language.french"
        case .english: "settings.language.english"
        }
    }

    func resolvedValue(appLanguage: AppLanguage) -> String {
        switch self {
        case .original: "original"
        case .application: appLanguage.rawValue
        case .french: AppLanguage.french.rawValue
        case .english: AppLanguage.english.rawValue
        }
    }
}

// MARK: - Theme & Appearance

enum AppTheme: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    #if canImport(UIKit)
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
    #elseif canImport(AppKit)
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

enum AccentColor: String, CaseIterable, Codable {
    case `default`
    case red
    case pink
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case indigo
    case custom

    /// Fixed swatches shown in the settings grid; `.custom` is rendered
    /// separately as a color picker, and `.indigo` is retired from the grid
    /// but still resolves for users who selected it before it was removed.
    static var presets: [AccentColor] {
        allCases.filter { $0 != .custom && $0 != .indigo }
    }

    /// The color for `.custom` lives in settings storage — resolve through
    /// `SettingsManager.resolvedAccentColor` instead of this property.
    var color: Color {
        switch self {
        case .default, .custom: return .blue  // System default accent color
        case .red: return .red
        case .pink: return .pink
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return Color(red: 0.082, green: 0.396, blue: 0.753)  // Darker blue #1565c0
        case .purple: return .purple
        case .indigo: return .indigo
        }
    }
}

enum AppIcon: String, CaseIterable, Codable {
    case `default`
    case classic
    case mascot

    var alternateIconName: String? {
        switch self {
        case .default: return nil
        case .classic: return "YatteeClassic"
        case .mascot: return "YatteeMascot"
        }
    }

    var previewImageName: String {
        switch self {
        case .default: return "AppIconPreview"
        case .classic: return "AppIconPreviewClassic"
        case .mascot: return "AppIconPreviewMascot"
        }
    }

    var displayName: String {
        switch self {
        case .default: return AppLocalization.string("settings.appearance.appIcon.default")
        case .classic: return AppLocalization.string("settings.appearance.appIcon.classic")
        case .mascot: return AppLocalization.string("settings.appearance.appIcon.mascot")
        }
    }

    var author: String? {
        switch self {
        case .mascot: return "by Carolus Vitalis"
        default: return nil
        }
    }
}

// MARK: - Video Quality

/// Playback quality preference.
enum VideoQuality: String, CaseIterable, Codable {
    case auto
    case hd4k = "4k"
    case hd1440p = "1440p"
    case hd1080p = "1080p"
    case hd720p = "720p"
    case sd480p = "480p"
    case sd360p = "360p"

    // Custom decoding to migrate legacy values
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        // Migrate legacy values
        switch rawValue {
        case "medium":
            self = .sd480p
        case "low":
            self = .sd360p
        default:
            if let quality = VideoQuality(rawValue: rawValue) {
                self = quality
            } else {
                self = .auto
            }
        }
    }

    /// Returns the recommended quality for the current platform
    static var recommendedForPlatform: VideoQuality {
        #if os(tvOS)
        return .hd4k
        #elseif os(macOS)
        return .hd1080p
        #elseif os(iOS)
        // iPad vs iPhone would be determined at runtime
        return .hd720p
        #endif
    }

    /// Returns the maximum resolution for this quality setting
    var maxResolution: StreamResolution? {
        switch self {
        case .auto:
            return nil
        case .hd4k:
            return .p2160
        case .hd1440p:
            return .p1440
        case .hd1080p:
            return .p1080
        case .hd720p:
            return .p720
        case .sd480p:
            return .p480
        case .sd360p:
            return .p360
        }
    }
}

// MARK: - Download Quality

/// Download quality preference.
enum DownloadQuality: String, CaseIterable, Codable, Sendable {
    case ask           // Show stream selection sheet (current behavior)
    case best          // Best available quality
    case hd4k = "4k"
    case hd1440p = "1440p"
    case hd1080p = "1080p"
    case hd720p = "720p"
    case sd480p = "480p"
    case sd360p = "360p"

    var displayName: String {
        switch self {
        case .ask: return AppLocalization.string("settings.downloads.quality.ask")
        case .best: return AppLocalization.string("settings.downloads.quality.best")
        case .hd4k: return "4K"
        case .hd1440p: return "1440p"
        case .hd1080p: return "1080p"
        case .hd720p: return "720p"
        case .sd480p: return "480p"
        case .sd360p: return "360p"
        }
    }

    /// Returns the maximum resolution for this quality setting.
    var maxResolution: StreamResolution? {
        switch self {
        case .ask, .best:
            return nil
        case .hd4k:
            return .p2160
        case .hd1440p:
            return .p1440
        case .hd1080p:
            return .p1080
        case .hd720p:
            return .p720
        case .sd480p:
            return .p480
        case .sd360p:
            return .p360
        }
    }
}

// MARK: - Haptic Feedback

/// Intensity levels for haptic feedback.
enum HapticFeedbackIntensity: String, CaseIterable, Codable {
    case off
    case light
    case medium
    case heavy

    var displayName: String {
        switch self {
        case .off: return AppLocalization.string("settings.haptics.intensity.off")
        case .light: return AppLocalization.string("settings.haptics.intensity.light")
        case .medium: return AppLocalization.string("settings.haptics.intensity.medium")
        case .heavy: return AppLocalization.string("settings.haptics.intensity.heavy")
        }
    }
}

/// Events that can trigger haptic feedback.
enum HapticEvent {
    case subscribeButton
    case playerShow
    case playerDismiss
    case commentsDismiss
    case seekGestureActivation
    case seekGestureBoundary
}

// MARK: - SponsorBlock

/// Categories of segments that can be skipped via SponsorBlock.
enum SponsorBlockCategory: String, CaseIterable, Codable, Sendable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case musicOfftopic = "music_offtopic"
    case filler
    case highlight = "poi_highlight"

    static var defaultEnabled: Set<SponsorBlockCategory> {
        [.sponsor, .selfpromo, .interaction, .intro, .outro]
    }

    var displayName: String {
        switch self {
        case .sponsor: return AppLocalization.string("sponsorBlock.category.sponsor")
        case .selfpromo: return AppLocalization.string("sponsorBlock.category.selfpromo")
        case .interaction: return AppLocalization.string("sponsorBlock.category.interaction")
        case .intro: return AppLocalization.string("sponsorBlock.category.intro")
        case .outro: return AppLocalization.string("sponsorBlock.category.outro")
        case .preview: return AppLocalization.string("sponsorBlock.category.preview")
        case .musicOfftopic: return AppLocalization.string("sponsorBlock.category.musicOfftopic")
        case .filler: return AppLocalization.string("sponsorBlock.category.filler")
        case .highlight: return AppLocalization.string("sponsorBlock.category.highlight")
        }
    }

    var localizedDescription: String {
        switch self {
        case .sponsor: return AppLocalization.string("sponsorBlock.category.sponsor.description")
        case .selfpromo: return AppLocalization.string("sponsorBlock.category.selfpromo.description")
        case .interaction: return AppLocalization.string("sponsorBlock.category.interaction.description")
        case .intro: return AppLocalization.string("sponsorBlock.category.intro.description")
        case .outro: return AppLocalization.string("sponsorBlock.category.outro.description")
        case .preview: return AppLocalization.string("sponsorBlock.category.preview.description")
        case .musicOfftopic: return AppLocalization.string("sponsorBlock.category.musicOfftopic.description")
        case .filler: return AppLocalization.string("sponsorBlock.category.filler.description")
        case .highlight: return AppLocalization.string("sponsorBlock.category.highlight.description")
        }
    }

    /// Whether this category should auto-skip by default.
    var defaultAutoSkip: Bool {
        switch self {
        case .sponsor, .selfpromo, .interaction, .intro, .outro:
            return true
        case .preview, .musicOfftopic, .filler, .highlight:
            return false
        }
    }
}

// MARK: - Floating Panel

/// Which side the floating details panel appears on in widescreen layout.
enum FloatingPanelSide: String, CaseIterable, Codable {
    case left
    case right

    /// The opposite side.
    var opposite: FloatingPanelSide {
        switch self {
        case .left: return .right
        case .right: return .left
        }
    }

    /// The edge for alignment.
    var edge: Edge {
        switch self {
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// The horizontal alignment.
    var alignment: HorizontalAlignment {
        switch self {
        case .left: return .leading
        case .right: return .trailing
        }
    }
}

// MARK: - Link Action

/// Default action when opening links from share extension or URL schemes.
enum DefaultLinkAction: String, CaseIterable, Codable {
    case open
    case download
    case ask

    var displayName: String {
        switch self {
        case .open: return AppLocalization.string("settings.behavior.linkAction.open")
        case .download: return AppLocalization.string("settings.behavior.linkAction.download")
        case .ask: return AppLocalization.string("settings.behavior.linkAction.ask")
        }
    }
}

// MARK: - Mini Player Video Tap Action

/// Action to perform when tapping on video in mini player.
enum MiniPlayerVideoTapAction: String, CaseIterable, Codable {
    case startPiP
    case expandPlayer

    var displayName: String {
        switch self {
        case .startPiP:
            return AppLocalization.string("settings.behavior.miniPlayer.videoTapAction.startPiP")
        case .expandPlayer:
            return AppLocalization.string("settings.behavior.miniPlayer.videoTapAction.expandPlayer")
        }
    }
}

// MARK: - Mini Player Minimize Behavior

/// Behavior for minimizing the mini player (iOS 26+ only).
#if os(iOS)
@available(iOS 26, *)
enum MiniPlayerMinimizeBehavior: String, CaseIterable, Codable {
    case onScrollDown
    case never

    var displayName: String {
        switch self {
        case .onScrollDown:
            return AppLocalization.string("settings.behavior.miniPlayer.minimizeBehavior.onScrollDown")
        case .never:
            return AppLocalization.string("settings.behavior.miniPlayer.minimizeBehavior.never")
        }
    }
}
#endif

// MARK: - Video Tap Action

/// Action to perform when tapping on video cards/rows (iOS/macOS only).
enum VideoTapAction: String, CaseIterable, Codable {
    case playVideo
    case openInfo
    case none

    var displayName: String {
        switch self {
        case .playVideo:
            return AppLocalization.string("settings.behavior.videoTap.playVideo")
        case .openInfo:
            return AppLocalization.string("settings.behavior.videoTap.openInfo")
        case .none:
            return AppLocalization.string("settings.behavior.videoTap.none")
        }
    }
}

// MARK: - Resume Action

/// Action to perform when starting a partially watched video.
enum ResumeAction: String, CaseIterable, Codable {
    /// Continue playback from where the user left off.
    case continueWatching
    /// Always start from the beginning.
    case startFromBeginning
    /// Ask the user each time.
    case ask

    var displayName: String {
        switch self {
        case .continueWatching:
            return AppLocalization.string("settings.playback.resumeAction.continueWatching")
        case .startFromBeginning:
            return AppLocalization.string("settings.playback.resumeAction.startFromBeginning")
        case .ask:
            return AppLocalization.string("settings.playback.resumeAction.ask")
        }
    }
}

// MARK: - Volume Mode

/// How volume is controlled during playback.
enum VolumeMode: String, CaseIterable, Codable {
    /// In-app volume control via MPV.
    case mpv
    /// Use device system volume (hardware buttons/OS controls).
    case system

    var displayName: String {
        switch self {
        case .mpv: return AppLocalization.string("settings.playback.volume.mode.inApp")
        case .system: return AppLocalization.string("settings.playback.volume.mode.system")
        }
    }
}

// MARK: - System Controls

/// Mode for system control buttons (Control Center, Lock Screen).
enum SystemControlsMode: String, CaseIterable, Codable {
    /// Skip forward/backward by duration.
    case seek
    /// Navigate to previous/next video in queue.
    case skipTrack

    var displayName: String {
        switch self {
        case .seek: return AppLocalization.string("settings.playback.systemControls.mode.seek")
        case .skipTrack: return AppLocalization.string("settings.playback.systemControls.mode.skipTrack")
        }
    }
}

/// Duration for seek operations in system controls.
enum SystemControlsSeekDuration: Int, CaseIterable, Codable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60

    var displayName: String { "\(rawValue)s" }
    var timeInterval: TimeInterval { TimeInterval(rawValue) }
}

// MARK: - Video Swipe Actions

/// Available swipe actions for video lists.
#if !os(tvOS)
enum VideoSwipeAction: String, CaseIterable, Codable, Identifiable {
    case playNext
    case addToQueue
    case download
    case share
    case videoInfo
    case goToChannel
    case addToBookmarks
    case addToPlaylist
    case markWatched

    var id: String { rawValue }

    /// SF Symbol name for this action.
    var symbolImage: String {
        switch self {
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.append"
        case .download: return "arrow.down.circle"
        case .share: return "square.and.arrow.up"
        case .videoInfo: return "info.circle"
        case .goToChannel: return "person.circle"
        case .addToBookmarks: return "bookmark"
        case .addToPlaylist: return "text.badge.plus"
        case .markWatched: return "eye"
        }
    }

    /// Tint color for the icon.
    var tint: Color { .white }

    /// Background color for the action button.
    var backgroundColor: Color {
        switch self {
        case .playNext: return .blue
        case .addToQueue: return .indigo
        case .download: return .green
        case .share: return .orange
        case .videoInfo: return .gray
        case .goToChannel: return .purple
        case .addToBookmarks: return .yellow
        case .addToPlaylist: return .teal
        case .markWatched: return .cyan
        }
    }

    /// Localized display name for this action.
    var displayName: String {
        switch self {
        case .playNext: return AppLocalization.string("swipeAction.playNext")
        case .addToQueue: return AppLocalization.string("swipeAction.addToQueue")
        case .download: return AppLocalization.string("swipeAction.download")
        case .share: return AppLocalization.string("swipeAction.share")
        case .videoInfo: return AppLocalization.string("swipeAction.videoInfo")
        case .goToChannel: return AppLocalization.string("swipeAction.goToChannel")
        case .addToBookmarks: return AppLocalization.string("swipeAction.addToBookmarks")
        case .addToPlaylist: return AppLocalization.string("swipeAction.addToPlaylist")
        case .markWatched: return AppLocalization.string("swipeAction.markWatched")
        }
    }

    /// Default order with only download and share enabled.
    static var defaultOrder: [VideoSwipeAction] {
        [.download, .share]
    }

    /// Default visibility: only download and share are enabled by default.
    static var defaultVisibility: [VideoSwipeAction: Bool] {
        var visibility = [VideoSwipeAction: Bool]()
        for action in allCases {
            visibility[action] = (action == .download || action == .share)
        }
        return visibility
    }
}
#endif
