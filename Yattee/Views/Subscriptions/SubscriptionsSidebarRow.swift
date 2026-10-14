//
//  SubscriptionsSidebarRow.swift
//  Yattee
//
//  Compact row used in the Subscriptions sidebar (macOS and iPad) for the
//  "All Channels" entry and each subscribed channel.
//

import SwiftUI

struct SubscriptionsSidebarRow: View {
    let name: String
    let avatarURL: URL?
    let serverURL: URL?
    let authHeader: String?
    let channelID: String?
    var source: ContentSource? = nil
    let isAllChannels: Bool
    var isSelected: Bool = false

    private let avatarSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            avatar
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())

            Text(name)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if isAllChannels {
            ZStack {
                Circle().fill(.quaternary)
                Image(systemName: "rectangle.stack.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(avatarSize * 0.25)
            }
        } else {
            ChannelAvatarView(
                channelID: channelID ?? "",
                name: name,
                directURL: avatarURL,
                yatteeServerURL: serverURL,
                size: avatarSize,
                authHeader: authHeader,
                source: source,
                placeholderFont: .caption
            )
        }
    }
}
