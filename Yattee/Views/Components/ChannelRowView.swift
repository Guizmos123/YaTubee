//
//  ChannelRowView.swift
//  Yattee
//
//  A row view for displaying channel information in search results.
//

import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    var style: VideoRowStyle = .regular
    var yatteeServerURL: URL?
    var authHeader: String?

    // Style-based dimensions - use thumbnail height to keep avatar square and match row height
    private var avatarSize: CGFloat {
        style.thumbnailHeight
    }

    private var nameLines: Int {
        switch style {
        case .large: return 2
        case .regular: return 1
        case .compact: return 1
        }
    }

    private var nameFont: Font {
        #if os(tvOS)
        style == .compact ? .caption : .subheadline
        #else
        .subheadline
        #endif
    }

    private var subscriberFont: Font {
        #if os(tvOS)
        style == .compact ? .caption2 : .caption
        #else
        style == .compact ? .caption2 : .caption
        #endif
    }

    private var showChevron: Bool {
        style != .compact
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar - centered in container with same width as video thumbnail
            ChannelAvatarView(
                channelID: channel.id.channelID,
                name: channel.name,
                directURL: channel.thumbnailURL,
                yatteeServerURL: yatteeServerURL,
                size: avatarSize,
                authHeader: authHeader,
                source: channel.id.source
            )
            .frame(width: style.thumbnailWidth)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(nameFont)
                    .fontWeight(.medium)
                    .lineLimit(nameLines)

                if let subscribers = channel.formattedSubscriberCount {
                    HStack(spacing: 4) {
                        Text(AppLocalization.string("channel.subscriberCount \(subscribers)"))
                            .font(subscriberFont)
                            .foregroundStyle(.secondary)
                        
                        if channel.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            if showChevron {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
    }

}
