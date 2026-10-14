//
//  TVSubscriptionsSidebarRow.swift
//  Yattee
//
//  Compact row used in the tvOS Subscriptions sidebar for the
//  "All Channels" entry and each subscribed channel.
//

#if os(tvOS)
import SwiftUI

struct TVSubscriptionsSidebarRow: View {
    let name: String
    let avatarURL: URL?
    let serverURL: URL?
    let authHeader: String?
    let channelID: String?
    var source: ContentSource? = nil
    let isAllChannels: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private let avatarSize: CGFloat = 50

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                avatar
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())

                Text(name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                placeholderFont: .headline
            )
        }
    }
}
#endif
