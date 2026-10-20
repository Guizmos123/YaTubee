//
//  VideoThumbnailView.swift
//  Yattee
//
//  Reusable video thumbnail component with consistent 16:9 aspect ratio and optional overlays.
//

import SwiftUI
import Nuke
import NukeUI

enum PlaybackThumbnailStatus: Equatable, Sendable {
    case playing
    case paused

    init?(playbackState: PlaybackState) {
        switch playbackState {
        case .playing:
            self = .playing
        case .paused:
            self = .paused
        default:
            return nil
        }
    }
}

struct PiPPlaybackStatusOverlay: View {
    let isPaused: Bool

    var body: some View {
        Color.black.opacity(0.58)
            .overlay {
                Text(
                    isPaused
                        ? LocalizedStringKey("player.pip.paused")
                        : LocalizedStringKey("player.pip.nowPlaying")
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 4)
            }
            .allowsHitTesting(false)
    }
}

/// A `LazyImage` that steps through candidate URLs, advancing to the next
/// (lower-quality) one when a load fails.
///
/// YouTube's CDN (and the backends that wrap it) frequently advertise
/// `maxresdefault`/`sddefault` thumbnails that don't exist for older or
/// low-resolution uploads and return 404. Pass best-quality-first candidates
/// (e.g. `video.thumbnailURLsByQuality`) so a valid thumbnail is always shown.
struct FallbackLazyImage<Content: View>: View {
    let urls: [URL]
    @ViewBuilder let content: (LazyImageState) -> Content

    /// Index into `urls` of the URL currently being attempted.
    @State private var candidateIndex = 0

    private var currentURL: URL? {
        guard urls.indices.contains(candidateIndex) else { return urls.last }
        return urls[candidateIndex]
    }

    var body: some View {
        LazyImage(url: currentURL) { state in
            content(state)
        }
        .onCompletion { result in
            if case .failure = result, candidateIndex < urls.count - 1 {
                candidateIndex += 1
            }
        }
        .onChange(of: urls) { candidateIndex = 0 }
    }
}

/// A `LazyImage` variant that preserves complete `ImageRequest` values, including
/// authentication headers, while retrying ordered image candidates.
struct FallbackLazyImageRequest<Content: View>: View {
    let requests: [ImageRequest]
    let onSuccess: ((ImageResponse) -> Void)?
    @ViewBuilder let content: (LazyImageState) -> Content

    @State private var candidateIndex = 0

    init(
        requests: [ImageRequest],
        onSuccess: ((ImageResponse) -> Void)? = nil,
        @ViewBuilder content: @escaping (LazyImageState) -> Content
    ) {
        self.requests = requests
        self.onSuccess = onSuccess
        self.content = content
    }

    private var currentRequest: ImageRequest? {
        guard requests.indices.contains(candidateIndex) else { return requests.last }
        return requests[candidateIndex]
    }

    private var requestURLs: [URL?] {
        requests.map(\.url)
    }

    var body: some View {
        LazyImage(request: currentRequest) { state in
            content(state)
        }
        .onCompletion { result in
            if case .success(let response) = result {
                onSuccess?(response)
            } else if candidateIndex < requests.count - 1 {
                candidateIndex += 1
            }
        }
        .onChange(of: requestURLs) { candidateIndex = 0 }
    }
}

/// A reusable video thumbnail view with 16:9 aspect ratio.
///
/// Supports optional overlays for:
/// - Watch progress bar
/// - Duration badge
/// - Download status (completed checkmark or progress indicator)
/// - Live badge
struct VideoThumbnailView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let url: URL?

    /// Stable YouTube/source video identifier used to limit the PiP treatment
    /// to the thumbnail representing the currently playing video.
    var videoID: String? = nil

    /// Lower-quality URLs to try, in priority order, if `url` fails to load.
    ///
    /// YouTube's CDN (and the backends that wrap it) frequently advertise
    /// `maxresdefault`/`sddefault` thumbnails that don't exist for older or
    /// low-resolution uploads and return 404. When the primary `url` fails we
    /// step through these so a valid thumbnail is always shown.
    var fallbackURLs: [URL] = []

    var cornerRadius: CGFloat = 8
    var watchProgress: Double? = nil
    var duration: String? = nil
    var durationAlignment: Alignment = .bottomLeading
    var isDownloaded: Bool = false
    var downloadProgress: Double? = nil
    /// When true, shows a spinner instead of progress arc (for unknown file sizes)
    var downloadProgressIndeterminate: Bool = false
    var isLive: Bool = false
    var placeholderTitle: String? = nil
    var isWatched: Bool = false
    var showsNoveltyBadge: Bool = false
    var noveltyBadgeSize: CGFloat = 18

    /// De-duplicated candidate URLs, best-quality first.
    private var candidates: [URL] {
        var seen = Set<URL>()
        return ([url] + fallbackURLs).compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    private var playbackThumbnailStatus: PlaybackThumbnailStatus? {
        guard let videoID,
              let playerService = appEnvironment?.playerService,
              playerService.state.currentVideo?.id.videoID == videoID else {
            return nil
        }

        return PlaybackThumbnailStatus(playbackState: playerService.state.playbackState)
    }

    var body: some View {
        FallbackLazyImage(urls: candidates) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if let title = placeholderTitle {
                            Text(title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(8)
                        }
                    }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .overlay(alignment: .bottom) {
            watchProgressBar
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: durationAlignment) {
            durationBadge
        }
        .overlay(alignment: .bottomTrailing) {
            downloadIndicator
        }
        .overlay(alignment: .topTrailing) {
            liveBadge
        }
        .overlay(alignment: .topLeading) {
            if isWatched {
                watchedCheckmark
            } else if showsNoveltyBadge {
                noveltyBadge
            }
        }
        .overlay {
            if let playbackThumbnailStatus {
                PiPPlaybackStatusOverlay(
                    isPaused: playbackThumbnailStatus == .paused
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // MARK: - Overlays

    private var noveltyBadge: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: noveltyBadgeSize, y: 0))
            path.addLine(to: CGPoint(x: 0, y: noveltyBadgeSize))
            path.closeSubpath()
        }
        .fill(.orange)
        .frame(width: noveltyBadgeSize, height: noveltyBadgeSize)
        .accessibilityLabel(Text("feed.noveltyBadge.accessibilityLabel"))
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var watchProgressBar: some View {
        // Live streams have no fixed timeline, so a progress bar is meaningless
        if !isLive, let progress = watchProgress, progress > 0 && progress < 1 {
            GeometryReader { geo in
                Rectangle()
                    .fill(.red)
                    .frame(width: geo.size.width * progress, height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let duration, !duration.isEmpty {
            DurationBadge(text: duration)
                .padding(cornerRadius > 6 ? 6 : 4)
        }
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        if isDownloaded {
            Image(systemName: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.8))
                .clipShape(Circle())
                .padding(4)
        } else if let progress = downloadProgress, progress < 1 || downloadProgressIndeterminate {
            DownloadProgressIndicator(
                progress: progress,
                size: cornerRadius > 6 ? 28 : 22,
                isIndeterminate: downloadProgressIndeterminate
            )
            .padding(4)
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if isLive {
            Text(AppLocalization.string("video.badge.live"))
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }

    @ViewBuilder
    private var watchedCheckmark: some View {
        if isWatched && !isLive {
            #if os(tvOS)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: cornerRadius > 6 ? 32 : 22, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                .padding(cornerRadius > 6 ? 4 : 2)
            #else
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: cornerRadius > 6 ? 20 : 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.background, .tint)
                .padding(cornerRadius > 6 ? 3 : 2)
            #endif
        }
    }
}

// MARK: - Preview

#Preview("Default") {
    VideoThumbnailView(url: nil)
        .frame(width: 280)
        .padding()
}

#Preview("With Progress") {
    VideoThumbnailView(
        url: nil,
        watchProgress: 0.6,
        duration: "12:34"
    )
    .frame(width: 280)
    .padding()
}

#Preview("Downloaded") {
    VideoThumbnailView(
        url: nil,
        duration: "1:23:45",
        isDownloaded: true
    )
    .frame(width: 280)
    .padding()
}

#Preview("Live") {
    VideoThumbnailView(
        url: nil,
        isLive: true
    )
    .frame(width: 280)
    .padding()
}

#Preview("Watched") {
    VideoThumbnailView(
        url: nil,
        duration: "12:34",
        isWatched: true
    )
    .frame(width: 280)
    .padding()
}
