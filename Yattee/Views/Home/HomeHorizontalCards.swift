//
//  HomeHorizontalCards.swift
//  Yattee
//
//  Horizontal shelf of video cards for Home section card layouts.
//

import SwiftUI

/// A horizontally scrolling row of `VideoCardView` cards used by Home sections.
struct HomeHorizontalCards: View {
    let videos: [Video]
    let queueSource: QueueSource
    let sourceLabel: String
    var layout: HomeSectionLayout = .grid
    var loadMoreVideos: LoadMoreVideosCallback? = nil

    #if os(tvOS)
    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 340
    private let spacing: CGFloat = 60
    private let verticalPadding: CGFloat = 28
    #else
    private let cardWidth: CGFloat = 180
    private let cardHeight: CGFloat = 210
    private let spacing: CGFloat = 28
    private let verticalPadding: CGFloat = 8
    #endif

    private var cardSpacing: CGFloat {
        layout == .large ? 12 : spacing
    }

    var body: some View {
        #if os(macOS)
        if layout == .large {
            MacHomeLargeGrid(items: videos, id: \.id, maxRows: 1) { index, video in
                VideoCardView(video: video, usesLargeMacTypography: true)
                    .tappableVideo(
                        video,
                        queueSource: queueSource,
                        sourceLabel: sourceLabel,
                        videoList: videos,
                        videoIndex: index,
                        loadMoreVideos: loadMoreVideos
                    )
            }
        } else {
            horizontalCards
        }
        #else
        horizontalCards
        #endif
    }

    private var horizontalCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    Group {
                        if layout == .large {
                            HomeLargeVideoCard(video: video)
                                .containerRelativeFrame(.horizontal) { availableWidth, _ in
                                    availableWidth * 0.8
                                }
                        } else {
                            VideoCardView(video: video, isCompact: true)
                                .frame(width: cardWidth, height: cardHeight, alignment: .top)
                        }
                    }
                        .tappableVideo(
                            video,
                            queueSource: queueSource,
                            sourceLabel: sourceLabel,
                            videoList: videos,
                            videoIndex: index,
                            loadMoreVideos: loadMoreVideos
                        )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, verticalPadding)
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }
}

/// Continue-watching variant that keeps the SwiftData entries observable until
/// card rendering instead of freezing their metadata in an intermediate array.
struct HomeContinueWatchingHorizontalCards: View {
    let entries: [WatchEntry]
    let queueSource: QueueSource
    let sourceLabel: String
    var layout: HomeSectionLayout = .grid
    var loadMoreVideos: LoadMoreVideosCallback? = nil

    #if os(tvOS)
    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 340
    private let spacing: CGFloat = 60
    private let verticalPadding: CGFloat = 28
    #else
    private let cardWidth: CGFloat = 180
    private let cardHeight: CGFloat = 210
    private let spacing: CGFloat = 28
    private let verticalPadding: CGFloat = 8
    #endif

    private var cardSpacing: CGFloat {
        layout == .large ? 12 : spacing
    }

    var body: some View {
        let videos = entries.map { $0.toVideo() }
        #if os(macOS)
        if layout == .large {
            MacHomeLargeGrid(items: entries, id: \.videoIdentifier, maxRows: 3, absoluteLimit: 12) { index, entry in
                HomeContinueWatchingCard(
                    entry: entry,
                    layout: layout,
                    compactWidth: cardWidth,
                    compactHeight: cardHeight,
                    usesLargeMacTypography: true
                )
                .tappableVideo(
                    entry.toVideo(),
                    startTime: entry.watchedSeconds,
                    queueSource: queueSource,
                    sourceLabel: sourceLabel,
                    videoList: videos,
                    videoIndex: index,
                    loadMoreVideos: loadMoreVideos
                )
            }
        } else {
            horizontalCards(videos: videos)
        }
        #else
        horizontalCards(videos: videos)
        #endif
    }

    private func horizontalCards(videos: [Video]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(Array(entries.enumerated()), id: \.element.videoIdentifier) { index, entry in
                    let video = entry.toVideo()

                    HomeContinueWatchingCard(
                        entry: entry,
                        layout: layout,
                        compactWidth: cardWidth,
                        compactHeight: cardHeight,
                        usesLargeMacTypography: false
                    )
                    .tappableVideo(
                        video,
                        startTime: entry.watchedSeconds,
                        queueSource: queueSource,
                        sourceLabel: sourceLabel,
                        videoList: videos,
                        videoIndex: index,
                        loadMoreVideos: loadMoreVideos
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, verticalPadding)
            #if os(tvOS)
            .focusSection()
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

}

/// Materializes the display `Video` inside the retained lazy cell so SwiftUI
/// observes changes to the underlying SwiftData entry instead of preserving a
/// value snapshot created by the parent `ForEach` closure.
private struct HomeContinueWatchingCard: View {
    @Bindable var entry: WatchEntry

    let layout: HomeSectionLayout
    let compactWidth: CGFloat
    let compactHeight: CGFloat
    let usesLargeMacTypography: Bool

    var body: some View {
        let video = entry.toVideo()
        Group {
            if layout == .large {
                #if os(macOS)
                VideoCardView(
                    video: video,
                    watchProgress: entry.progress,
                    usesLargeMacTypography: usesLargeMacTypography
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                #else
                VideoCardView(
                    video: video,
                    watchProgress: entry.progress,
                    usesLargeMacTypography: usesLargeMacTypography
                )
                    .containerRelativeFrame(.horizontal) { availableWidth, _ in
                        availableWidth * 0.8
                    }
                #endif
            } else {
                VideoCardView(video: video, watchProgress: entry.progress, isCompact: true)
                    .frame(width: compactWidth, height: compactHeight, alignment: .top)
            }
        }
    }

}

#if os(macOS)
/// Adaptive vertical grid used only by the macOS Home "Large" presentation.
/// It caps visible rows without manufacturing empty cells.
private struct MacHomeLargeGridItem<Item, ID: Hashable>: Identifiable {
    let id: ID
    let index: Int
    let item: Item
}

private struct MacHomeLargeGrid<Item, ID: Hashable, Content: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let maxRows: Int
    let absoluteLimit: Int?
    @ViewBuilder let content: (Int, Item) -> Content

    @State private var availableWidth: CGFloat = 0

    init(
        items: [Item],
        id: KeyPath<Item, ID>,
        maxRows: Int,
        absoluteLimit: Int? = nil,
        @ViewBuilder content: @escaping (Int, Item) -> Content
    ) {
        self.items = items
        self.id = id
        self.maxRows = maxRows
        self.absoluteLimit = absoluteLimit
        self.content = content
    }

    private var columnCount: Int {
        let horizontalPadding: CGFloat = 64
        let spacing: CGFloat = 20
        let targetCardWidth: CGFloat = 280
        let usableWidth = max(0, availableWidth - horizontalPadding)
        let fittingColumns = Int((usableWidth + spacing) / (targetCardWidth + spacing))
        return min(4, max(2, fittingColumns))
    }

    private var visibleItems: [MacHomeLargeGridItem<Item, ID>] {
        let rowLimit = columnCount * maxRows
        let limit = min(rowLimit, absoluteLimit ?? rowLimit)
        return items.prefix(limit).enumerated().map { item in
            MacHomeLargeGridItem(
                id: item.element[keyPath: id],
                index: item.offset,
                item: item.element
            )
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: 400), spacing: 20, alignment: .top),
            count: columnCount
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 24) {
            ForEach(visibleItems) { item in
                content(item.index, item.item)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            availableWidth = newWidth
        }
    }
}
#endif

// MARK: - Large Card

private struct HomeLargeVideoCard: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let video: Video

    @State private var watchEntry: WatchEntry?

    var body: some View {
        VideoCardView(
            video: video,
            watchProgress: watchEntry?.progress
        )
        .onAppear { updateWatchEntry() }
        .onChange(of: video.id) { updateWatchEntry() }
        .onReceive(NotificationCenter.default.publisher(for: .watchHistoryDidChange)) { _ in
            updateWatchEntry()
        }
    }

    private func updateWatchEntry() {
        watchEntry = appEnvironment?.dataManager.watchEntry(for: video.id.videoID)
    }
}
