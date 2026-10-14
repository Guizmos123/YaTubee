//
//  ChannelAvatarView.swift
//  Yattee
//
//  Channel avatar that supports loading from Yattee Server.
//  When the author doesn't have a thumbnail URL (common with yt-dlp),
//  this view will attempt to load the avatar from the server's avatar endpoint.
//

import SwiftUI
import Nuke
import NukeUI

// MARK: - Channel Avatar View

/// A channel avatar view that supports loading from Yattee Server.
struct ChannelAvatarView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let channelID: String
    let name: String
    let directURL: URL?
    let size: CGFloat
    let yatteeServerURL: URL?
    let source: ContentSource?
    let authHeader: String?
    let placeholderFont: Font?
    let placeholderFill: AnyShapeStyle
    let showsPlaceholderInitial: Bool

    @State private var persistedImage: Image?
    @State private var revalidatedImage: Image?

    init(
        author: Author,
        size: CGFloat = 40,
        yatteeServerURL: URL? = nil,
        source: ContentSource? = nil,
        authHeader: String? = nil,
        placeholderFont: Font? = nil,
        placeholderFill: AnyShapeStyle = AnyShapeStyle(.quaternary),
        showsPlaceholderInitial: Bool = true
    ) {
        channelID = author.id
        name = author.name
        directURL = author.thumbnailURL
        self.size = size
        self.yatteeServerURL = yatteeServerURL
        self.source = source
        self.authHeader = authHeader
        self.placeholderFont = placeholderFont
        self.placeholderFill = placeholderFill
        self.showsPlaceholderInitial = showsPlaceholderInitial
    }

    init(
        channelID: String,
        name: String,
        directURL: URL?,
        yatteeServerURL: URL?,
        size: CGFloat,
        authHeader: String?,
        source: ContentSource?,
        placeholderFont: Font? = nil,
        placeholderFill: AnyShapeStyle = AnyShapeStyle(.quaternary),
        showsPlaceholderInitial: Bool = true
    ) {
        self.channelID = channelID
        self.name = name
        self.directURL = directURL
        self.yatteeServerURL = yatteeServerURL
        self.size = size
        self.authHeader = authHeader
        self.source = source
        self.placeholderFont = placeholderFont
        self.placeholderFill = placeholderFill
        self.showsPlaceholderInitial = showsPlaceholderInitial
    }

    var body: some View {
        FallbackLazyImageRequest(
            requests: avatarRequests,
            onSuccess: persistSuccessfulResponse
        ) { state in
            ZStack {
                // Background circle with letter placeholder
                Circle()
                    .fill(placeholderFill)
                    .overlay {
                        if state.image == nil, persistedImage == nil, showsPlaceholderInitial {
                            Text(String(name.prefix(1)))
                                .font(placeholderFont ?? (size > 50 ? .title : .subheadline))
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }

                // Avatar image
                if let persistedImage {
                    persistedImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

                if let revalidatedImage {
                    revalidatedImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Isolate geometry to prevent position jumping during parent animations
        .geometryGroup()
        .task(id: loadIdentity) {
            revalidatedImage = nil
            await loadPersistedImage()
            await revalidatePersistedImageIfNeeded()
        }
    }

    private var avatarRequests: [ImageRequest] {
        let serverURL: URL? = source.map { source in
            if case .global(let provider) = source,
               provider == ContentSource.youtubeProvider {
                return yatteeServerURL
            }
            return nil
        } ?? yatteeServerURL

        return AvatarURLBuilder.imageRequests(
            channelID: channelID,
            directURL: directURL,
            serverURL: serverURL,
            size: Int(size),
            authHeader: authHeader
        )
    }

    private var persistenceKey: ChannelAvatarStorageKey? {
        ChannelAvatarStorageKey(channelID: channelID, source: source)
    }

    private var loadIdentity: AvatarLoadIdentity {
        AvatarLoadIdentity(
            persistenceKey: persistenceKey,
            requestURLs: avatarRequests.map(\.url)
        )
    }

    private func loadPersistedImage() async {
        persistedImage = nil
        guard let persistenceKey,
              let data = await ChannelAvatarStore.shared.data(for: persistenceKey),
              let platformImage = PlatformImage(data: data) else {
            return
        }

        #if os(macOS)
        persistedImage = Image(nsImage: platformImage)
        #else
        persistedImage = Image(uiImage: platformImage)
        #endif
    }

    private func persistSuccessfulResponse(_ response: ImageResponse) {
        guard let persistenceKey else { return }

        Task.detached(priority: .utility) {
            guard let data = ImageEncoders.Default(compressionQuality: 0.9)
                .encode(response.image),
                !data.isEmpty else {
                return
            }

            await ChannelAvatarStore.shared.save(data, for: persistenceKey)
        }
    }

    private func revalidatePersistedImageIfNeeded() async {
        guard let persistenceKey,
              appEnvironment?.connectivityMonitor.isOnline != false,
              !avatarRequests.isEmpty,
              await ChannelAvatarStore.shared.beginRevalidationIfNeeded(for: persistenceKey) else {
            return
        }

        for request in avatarRequests {
            do {
                let refreshedRequest = AvatarURLBuilder.revalidationRequest(from: request)
                let (data, _) = try await ImagePipeline.shared.data(for: refreshedRequest)
                guard !data.isEmpty, let platformImage = PlatformImage(data: data) else {
                    continue
                }

                guard await ChannelAvatarStore.shared.save(data, for: persistenceKey) else {
                    continue
                }
                await ChannelAvatarStore.shared.finishRevalidation(
                    for: persistenceKey,
                    succeeded: true,
                    sourceURL: request.url
                )

                #if os(macOS)
                revalidatedImage = Image(nsImage: platformImage)
                #else
                revalidatedImage = Image(uiImage: platformImage)
                #endif
                return
            } catch is CancellationError {
                await ChannelAvatarStore.shared.finishRevalidation(
                    for: persistenceKey,
                    succeeded: false,
                    sourceURL: nil
                )
                return
            } catch {
                continue
            }
        }

        await ChannelAvatarStore.shared.finishRevalidation(
            for: persistenceKey,
            succeeded: false,
            sourceURL: nil
        )
    }

    private struct AvatarLoadIdentity: Hashable {
        let persistenceKey: ChannelAvatarStorageKey?
        let requestURLs: [URL?]
    }
}
