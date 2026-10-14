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
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    Group {
                        if layout == .large {
                            VideoCardView(video: video)
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
