//
//  ModelTests.swift
//  YatteeTests
//
//  Tests for core model types.
//

import Foundation
import Nuke
import Testing
@testable import YaTubee

// MARK: - Channel Avatar Request Tests

@Suite("Channel Avatar Request Tests")
struct ChannelAvatarRequestTests {
    private let serverURL = URL(string: "https://server.example")!
    private let directURL = URL(string: "https://cdn.example/avatar.jpg")!

    @Test("A known direct URL works without a server")
    func directURLWithoutServer() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: directURL,
            serverURL: nil,
            size: 80,
            authHeader: nil
        )

        #expect(requests.map(\.url) == [directURL])
    }

    @Test("A direct URL remains available after the server fallback")
    func serverThenDirectFallback() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: directURL,
            serverURL: serverURL,
            size: 80,
            authHeader: "Basic credential"
        )

        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/api/v1/channels/UCchannel/avatar/176.jpg")
        #expect(requests[1].url == directURL)
    }

    @Test("Basic Auth is limited to the Yattee Server request")
    func serverAuthentication() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: directURL,
            serverURL: serverURL,
            size: 80,
            authHeader: "Basic credential"
        )

        #expect(requests[0].urlRequest?.value(forHTTPHeaderField: "Authorization") == "Basic credential")
        #expect(requests[1].urlRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A missing direct URL still uses the server fallback")
    func missingDirectURL() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: nil,
            serverURL: serverURL,
            size: 80,
            authHeader: nil
        )

        #expect(requests.count == 1)
        #expect(requests[0].url?.host == "server.example")
    }

    @Test("Regular list avatar uses the working 176 pixel server variant")
    func regularListServerSize() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: directURL,
            serverURL: serverURL,
            size: 68,
            authHeader: nil
        )

        #expect(requests[0].url?.path == "/api/v1/channels/UCchannel/avatar/176.jpg")
        #expect(requests[1].url == directURL)
    }

    @Test("Identical server and direct candidates are deduplicated")
    func duplicateCandidates() {
        let serverAvatarURL = serverURL
            .appendingPathComponent("api/v1/channels/UCchannel/avatar/176.jpg")
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: serverAvatarURL,
            serverURL: serverURL,
            size: 80,
            authHeader: "Basic credential"
        )

        #expect(requests.count == 1)
        #expect(requests[0].url == serverAvatarURL)
        #expect(requests[0].urlRequest?.value(forHTTPHeaderField: "Authorization") == "Basic credential")
    }

    @Test("Revalidation bypasses Nuke caches and preserves scoped authentication")
    func revalidationRequest() {
        let requests = AvatarURLBuilder.imageRequests(
            channelID: "UCchannel",
            directURL: directURL,
            serverURL: serverURL,
            size: 80,
            authHeader: "Basic credential"
        )

        let serverRequest = AvatarURLBuilder.revalidationRequest(from: requests[0])
        let directRequest = AvatarURLBuilder.revalidationRequest(from: requests[1])

        #expect(serverRequest.options.contains(.reloadIgnoringCachedData))
        #expect(serverRequest.urlRequest?.cachePolicy == .reloadRevalidatingCacheData)
        #expect(serverRequest.urlRequest?.value(forHTTPHeaderField: "Authorization") == "Basic credential")
        #expect(directRequest.urlRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

// MARK: - Mini Player Style Tests

@Suite("Mini Player Style Tests")
struct MiniPlayerStyleTests {
    @Test("Bar is the default mini player style")
    func defaultStyle() {
        #expect(MiniPlayerSettings.default.style == .bar)
        #expect(PlayerControlsLayout().effectiveMiniPlayerSettings.style == .bar)
    }

    @Test("Mini player style survives encoding and restoration")
    func persistenceRoundTrip() throws {
        let settings = MiniPlayerSettings(style: .video)
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(MiniPlayerSettings.self, from: data)

        #expect(restored.style == .video)
        #expect(restored.showVideo == settings.showVideo)
        #expect(restored.videoTapAction == settings.videoTapAction)
        #expect(restored.buttons == settings.buttons)
    }

    @Test("Legacy mini player settings without a style restore as bar")
    func legacySettingsDefaultToBar() throws {
        let encoded = try JSONEncoder().encode(MiniPlayerSettings(style: .bubble))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "style")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(MiniPlayerSettings.self, from: legacyData)
        #expect(restored.style == .bar)
    }

    @Test("Changing presets restores each preset mini player style")
    func presetStyleRestoration() {
        var barLayout = PlayerControlsLayout()
        barLayout.miniPlayerSettings = MiniPlayerSettings(style: .bar)
        let barPreset = LayoutPreset(name: "Bar", layout: barLayout)

        var bubbleLayout = PlayerControlsLayout()
        bubbleLayout.miniPlayerSettings = MiniPlayerSettings(style: .bubble)
        let bubblePreset = LayoutPreset(name: "Bubble", layout: bubbleLayout)

        #expect(barPreset.layout.effectiveMiniPlayerSettings.style == .bar)
        #expect(bubblePreset.layout.effectiveMiniPlayerSettings.style == .bubble)
        #expect(bubblePreset.duplicate(name: "Bubble Copy").layout.effectiveMiniPlayerSettings.style == .bubble)
    }

    @Test("Changing style preserves the shared buttons and exposes the correct editor sections")
    func styleChangesPreserveButtons() {
        var settings = MiniPlayerSettings()
        let originalButtons = settings.buttons

        settings.style = .video
        #expect(settings.buttons == originalButtons)
        #expect(settings.style.supportsCustomizableButtons)

        settings.style = .bubble
        #expect(settings.buttons == originalButtons)
        #expect(!settings.style.supportsCustomizableButtons)

        settings.style = .bar
        #expect(settings.buttons == originalButtons)
        #expect(settings.style.supportsCustomizableButtons)
    }

    @Test("Video commands use the persisted order and only supported actions")
    func videoCommandsPreserveSupportedOrder() {
        let settings = MiniPlayerSettings(
            style: .video,
            buttons: [
                ControlButtonConfiguration(buttonType: .airplay),
                ControlButtonConfiguration(buttonType: .playNext),
                ControlButtonConfiguration(buttonType: .close),
                ControlButtonConfiguration(buttonType: .fullscreen),
                ControlButtonConfiguration(buttonType: .playPause),
                ControlButtonConfiguration(buttonType: .pictureInPicture)
            ]
        )

        #expect(settings.videoButtons.map(\.buttonType) == [
            .airplay,
            .close,
            .playPause,
            .pictureInPicture
        ])
    }

    @Test("Shared style metrics preserve the intended geometry")
    func sharedMetrics() {
        #expect(abs(Double(MiniPlayerStyleMetrics.videoAspectRatio) - 16.0 / 9.0) < 0.000_001)
        #expect(MiniPlayerStyleMetrics.recommendedBubbleDiameter == 72)
    }

    @Test("Mini player presentation uses exactly one container per style and platform capability")
    func presentationPolicy() {
        #expect(MiniPlayerPresentation.resolve(style: .bar, supportsTabAccessory: true) == .tabAccessory)
        #expect(MiniPlayerPresentation.resolve(style: .video, supportsTabAccessory: true) == .rootOverlay)
        #expect(MiniPlayerPresentation.resolve(style: .bubble, supportsTabAccessory: true) == .tabAccessory)
        #expect(
            MiniPlayerPresentation.resolve(
                style: .bubble,
                supportsTabAccessory: true,
                supportsProminentTab: true
            ) == .prominentTab
        )
        #expect(
            MiniPlayerPresentation.resolve(
                style: .bar,
                supportsTabAccessory: true,
                supportsProminentTab: true
            ) == .tabAccessory
        )
        #expect(
            MiniPlayerPresentation.resolve(
                style: .video,
                supportsTabAccessory: true,
                supportsProminentTab: true
            ) == .rootOverlay
        )

        for style in MiniPlayerStyle.allCases {
            #expect(MiniPlayerPresentation.resolve(style: style, supportsTabAccessory: false) == .rootOverlay)
        }
    }
}

// MARK: - Video Content Classification Tests

@Suite("Video Content Classification Tests")
struct VideoContentClassificationTests {
    @Test("Piped Short metadata maps true, false and nil semantically")
    func pipedClassification() {
        #expect(VideoContentKind(pipedIsShort: true) == .short)
        #expect(VideoContentKind(pipedIsShort: false) == .regular)
        #expect(VideoContentKind(pipedIsShort: nil) == .unknown)
    }

    @Test("Sources without reliable metadata default to unknown")
    func unknownByDefault() {
        #expect(makeVideo().contentKind == .unknown)
    }

    @Test("Short filtering excludes only confirmed Shorts")
    func filteringPolicy() {
        #expect(VideoContentKind.regular.isIncluded(whenIncludingShorts: false))
        #expect(!VideoContentKind.short.isIncluded(whenIncludingShorts: false))
        #expect(VideoContentKind.unknown.isIncluded(whenIncludingShorts: false))

        for kind in [VideoContentKind.regular, .short, .unknown] {
            #expect(kind.isIncluded(whenIncludingShorts: true))
        }
    }

    @Test("Previously serialized videos decode with unknown classification")
    func legacyVideoDecoding() throws {
        let encoded = try JSONEncoder().encode(makeVideo(contentKind: .regular))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "contentKind")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Video.self, from: legacyData)
        #expect(decoded.contentKind == .unknown)
    }

    private func makeVideo(contentKind: VideoContentKind = .unknown) -> Video {
        Video(
            id: .global("classification-test"),
            title: "Test",
            description: nil,
            author: Author(id: "channel", name: "Channel"),
            duration: 120,
            publishedAt: nil,
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: false,
            contentKind: contentKind,
            scheduledStartTime: nil
        )
    }
}

// MARK: - ContentSource Tests

@Suite("ContentSource Tests")
@MainActor
struct ContentSourceTests {

    @Test("Global source equality")
    func globalEquality() {
        let source1 = ContentSource.global(provider: ContentSource.youtubeProvider)
        let source2 = ContentSource.global(provider: ContentSource.youtubeProvider)
        #expect(source1 == source2)
    }

    @Test("Federated source with same instance are equal")
    func federatedEqualitySameInstance() {
        let url = URL(string: "https://peertube.example.com")!
        let source1 = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: url)
        let source2 = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: url)
        #expect(source1 == source2)
    }

    @Test("Federated sources with different instances are not equal")
    func federatedEqualityDifferentInstances() {
        let url1 = URL(string: "https://peertube1.example.com")!
        let url2 = URL(string: "https://peertube2.example.com")!
        let source1 = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: url1)
        let source2 = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: url2)
        #expect(source1 != source2)
    }

    @Test("Global and Federated are not equal")
    func globalNotEqualToFederated() {
        let global = ContentSource.global(provider: ContentSource.youtubeProvider)
        let federated = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: URL(string: "https://example.com")!)
        #expect(global != federated)
    }

    @Test("ContentSource display names")
    func displayNames() {
        #expect(ContentSource.global(provider: ContentSource.youtubeProvider).displayName == "YouTube")

        let peertubeURL = URL(string: "https://framatube.org")!
        #expect(ContentSource.federated(provider: ContentSource.peertubeProvider, instance: peertubeURL).displayName == "framatube.org")
    }

    @Test("ContentSource short names")
    func shortNames() {
        #expect(ContentSource.global(provider: ContentSource.youtubeProvider).shortName == "YT")

        let peertubeURL = URL(string: "https://framatube.org")!
        #expect(ContentSource.federated(provider: ContentSource.peertubeProvider, instance: peertubeURL).shortName == "framatub")
    }

    @Test("ContentSource is Codable")
    func codable() throws {
        let sources: [ContentSource] = [
            .global(provider: ContentSource.youtubeProvider),
            .federated(provider: ContentSource.peertubeProvider, instance: URL(string: "https://example.com")!)
        ]

        for source in sources {
            let encoded = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(ContentSource.self, from: encoded)
            #expect(source == decoded)
        }
    }

    @Test("ContentSource sorting - Global comes before Federated")
    func sorting() {
        let global = ContentSource.global(provider: ContentSource.youtubeProvider)
        let federated = ContentSource.federated(provider: ContentSource.peertubeProvider, instance: URL(string: "https://example.com")!)

        #expect(global < federated)
        #expect(!(federated < global))
    }
}

// MARK: - VideoID Tests

@Suite("VideoID Tests")
@MainActor
struct VideoIDTests {

    @Test("Global VideoID creation")
    func globalCreation() {
        let videoID = VideoID.global("dQw4w9WgXcQ")
        #expect(videoID.videoID == "dQw4w9WgXcQ")
        if case .global(let provider) = videoID.source {
            #expect(provider == ContentSource.youtubeProvider)
        } else {
            Issue.record("Expected global source")
        }
        #expect(videoID.uuid == nil)
    }

    @Test("Federated VideoID creation")
    func federatedCreation() {
        let instance = URL(string: "https://framatube.org")!
        let videoID = VideoID.federated("123", instance: instance, uuid: "abc-def")
        #expect(videoID.videoID == "123")
        if case .federated(let provider, let url) = videoID.source {
            #expect(provider == ContentSource.peertubeProvider)
            #expect(url == instance)
        } else {
            Issue.record("Expected federated source")
        }
        #expect(videoID.uuid == "abc-def")
    }

    @Test("VideoID identifiable ID format")
    func identifiableID() {
        let ytID = VideoID.global("abc123")
        #expect(ytID.id == "global:youtube:abc123")

        let ptID = VideoID.federated("456", instance: URL(string: "https://example.com")!)
        #expect(ptID.id == "federated:peertube:example.com:456")
    }
}

// MARK: - Video Tests

@Suite("Video Tests")
@MainActor
struct VideoTests {

    @Test("Video formatted duration - minutes and seconds")
    func formattedDurationMinutesSeconds() {
        let video = makeVideo(duration: 185) // 3:05
        #expect(video.formattedDuration == "3:05")
    }

    @Test("Video formatted duration - hours")
    func formattedDurationHours() {
        let video = makeVideo(duration: 3725) // 1:02:05
        #expect(video.formattedDuration == "1:02:05")
    }

    @Test("Video formatted duration - live shows LIVE")
    func formattedDurationLive() {
        let video = makeVideo(duration: 0, isLive: true)
        #expect(video.formattedDuration == "LIVE")
    }

    @Test("Video formatted view count - thousands")
    func formattedViewCountThousands() {
        let video = makeVideo(viewCount: 1500)
        #expect(video.formattedViewCount == "1.5K")
    }

    @Test("Video formatted view count - millions")
    func formattedViewCountMillions() {
        let video = makeVideo(viewCount: 2_500_000)
        #expect(video.formattedViewCount == "2.5M")
    }

    @Test("Video formatted view count - exact thousands")
    func formattedViewCountExactThousands() {
        let video = makeVideo(viewCount: 1000)
        #expect(video.formattedViewCount == "1K")
    }

    @Test("Video best thumbnail returns highest quality")
    func bestThumbnail() {
        let thumbnails = [
            Thumbnail(url: URL(string: "https://example.com/default.jpg")!, quality: .default),
            Thumbnail(url: URL(string: "https://example.com/maxres.jpg")!, quality: .maxres),
            Thumbnail(url: URL(string: "https://example.com/high.jpg")!, quality: .high),
        ]
        let video = makeVideo(thumbnails: thumbnails)
        #expect(video.bestThumbnail?.quality == .maxres)
    }

    private func makeVideo(
        duration: TimeInterval = 100,
        isLive: Bool = false,
        viewCount: Int? = nil,
        thumbnails: [Thumbnail] = []
    ) -> Video {
        Video(
            id: .global("test"),
            title: "Test Video",
            description: nil,
            author: Author(id: "channel", name: "Test Channel"),
            duration: duration,
            publishedAt: nil,
            publishedText: nil,
            viewCount: viewCount,
            likeCount: nil,
            thumbnails: thumbnails,
            isLive: isLive,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}

// MARK: - Instance Tests

@Suite("Instance Tests")
@MainActor
struct InstanceTests {

    @Test("Instance URL validation - valid HTTPS")
    func validateURLValidHTTPS() {
        let url = Instance.validateURL("https://invidious.io")
        #expect(url != nil)
        #expect(url?.scheme == "https")
    }

    @Test("Instance URL validation - preserves explicit HTTP for local servers")
    func validateURLPreservesHTTP() {
        // HTTP is preserved for local/private network servers (e.g., yt-dlp server)
        let url = Instance.validateURL("http://invidious.io")
        #expect(url?.scheme == "http")
    }

    @Test("Instance URL validation - adds HTTPS if missing")
    func validateURLAddsScheme() {
        let url = Instance.validateURL("invidious.io")
        #expect(url?.scheme == "https")
    }

    @Test("Instance URL validation - removes trailing slash")
    func validateURLRemovesTrailingSlash() {
        let url = Instance.validateURL("https://invidious.io/")
        #expect(url?.path == "" || !url!.absoluteString.hasSuffix("/"))
    }

    @Test("Instance URL validation - handles edge cases")
    func validateURLEdgeCases() {
        // URLComponents is lenient and encodes spaces
        let urlWithSpaces = Instance.validateURL("example with spaces")
        #expect(urlWithSpaces != nil) // Gets URL-encoded

        // Verifies scheme is added
        let simpleHost = Instance.validateURL("invidious.io")
        #expect(simpleHost?.scheme == "https")
    }

    @Test("Instance URL normalization preserves embedded credentials")
    func normalizeSourceURLPreservesCredentials() {
        let url = Instance.normalizeSourceURL("https://user:pass@server.com")
        #expect(url?.user == "user")
        #expect(url?.password == "pass")
        #expect(url?.host == "server.com")
    }

    @Test("Instance displayURL strips credentials")
    func displayURLStripsCredentials() {
        let instance = Instance(
            type: .invidious,
            url: URL(string: "https://user:pass@server.com")!
        )
        #expect(instance.displayURL == "https://server.com")
    }

    @Test("Instance displayURL returns absoluteString when no credentials")
    func displayURLWithoutCredentials() {
        let instance = Instance(
            type: .invidious,
            url: URL(string: "https://server.com")!
        )
        #expect(instance.displayURL == "https://server.com")
    }

    @Test("Instance display name uses custom name if set")
    func displayNameCustom() {
        let instance = Instance(
            type: .invidious,
            url: URL(string: "https://invidious.io")!,
            name: "My Instance"
        )
        #expect(instance.displayName == "My Instance")
    }

    @Test("Instance display name falls back to host")
    func displayNameFallback() {
        let instance = Instance(
            type: .invidious,
            url: URL(string: "https://invidious.io")!
        )
        #expect(instance.displayName == "invidious.io")
    }

    @Test("Instance isYouTubeInstance for Invidious")
    func isYouTubeInstanceInvidious() {
        let instance = Instance(type: .invidious, url: URL(string: "https://example.com")!)
        #expect(instance.isYouTubeInstance == true)
        #expect(instance.isPeerTubeInstance == false)
    }

    @Test("Instance isYouTubeInstance for Piped")
    func isYouTubeInstancePiped() {
        let instance = Instance(type: .piped, url: URL(string: "https://example.com")!)
        #expect(instance.isYouTubeInstance == true)
        #expect(instance.isPeerTubeInstance == false)
    }

    @Test("Instance isPeerTubeInstance")
    func isPeerTubeInstance() {
        let instance = Instance(type: .peertube, url: URL(string: "https://example.com")!)
        #expect(instance.isYouTubeInstance == false)
        #expect(instance.isPeerTubeInstance == true)
    }
}

// MARK: - Channel Tests

@Suite("Channel Tests")
@MainActor
struct ChannelTests {

    @Test("Channel formatted subscriber count")
    func formattedSubscriberCount() {
        let channel = Channel(
            id: .global("test"),
            name: "Test Channel",
            subscriberCount: 1_500_000
        )
        #expect(channel.formattedSubscriberCount == "1.5M")
    }

    @Test("ChannelID identifiable ID format")
    func channelIDFormat() {
        let ytID = ChannelID.global("UC123")
        #expect(ytID.id == "global:youtube:UC123")

        let ptID = ChannelID.federated("channel", instance: URL(string: "https://example.com")!)
        #expect(ptID.id == "federated:peertube:example.com:channel")
    }
}

// MARK: - Stream Tests

@Suite("Stream Tests")
@MainActor
struct StreamTests {

    @Test("StreamResolution comparison")
    func resolutionComparison() {
        #expect(StreamResolution.p720 < StreamResolution.p1080)
        #expect(StreamResolution.p1080 < StreamResolution.p2160)
        #expect(!(StreamResolution.p1080 < StreamResolution.p720))
    }

    @Test("StreamResolution from height label")
    func resolutionFromLabel() {
        let res720 = StreamResolution(heightLabel: "720p")
        #expect(res720?.height == 720)

        let res1080 = StreamResolution(heightLabel: "1080")
        #expect(res1080?.height == 1080)
    }

    @Test("Stream quality label for video")
    func qualityLabelVideo() {
        let stream = Stream(
            url: URL(string: "https://example.com/video.mp4")!,
            resolution: .p1080,
            format: "mp4"
        )
        #expect(stream.qualityLabel == "1080p")
    }

    @Test("Stream quality label for audio")
    func qualityLabelAudio() {
        let stream = Stream(
            url: URL(string: "https://example.com/audio.m4a")!,
            resolution: nil,
            format: "m4a",
            isAudioOnly: true
        )
        #expect(stream.qualityLabel == "Audio")
    }

    @Test("Stream isNativelyPlayable for MP4 H264")
    func nativelyPlayableMp4() {
        let stream = Stream(
            url: URL(string: "https://example.com/video.mp4")!,
            resolution: .p1080,
            format: "mp4",
            videoCodec: "avc1.4d401f"
        )
        #expect(stream.isNativelyPlayable == true)
    }

    @Test("Stream isNativelyPlayable for WebM VP9")
    func nativelyPlayableWebm() {
        let stream = Stream(
            url: URL(string: "https://example.com/video.webm")!,
            resolution: .p1080,
            format: "webm",
            videoCodec: "vp9"
        )
        #expect(stream.isNativelyPlayable == false)
    }
}

// MARK: - Playlist Tests

@Suite("Playlist Tests")
@MainActor
struct PlaylistTests {

    @Test("PlaylistID local vs remote")
    func playlistIDLocalVsRemote() {
        let localID = PlaylistID.local("my-playlist")
        #expect(localID.isLocal == true)
        #expect(localID.id == "local:my-playlist")

        let remoteID = PlaylistID.global("PLtest123")
        #expect(remoteID.isLocal == false)
        #expect(remoteID.id == "global:youtube:PLtest123")
    }
}

// MARK: - Caption Tests

@Suite("Caption Tests")
struct CaptionTests {

    @Test("Caption isAutoGenerated detection")
    func isAutoGenerated() {
        let autoCaption = Caption(
            label: "English (auto-generated)",
            languageCode: "en",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(autoCaption.isAutoGenerated == true)

        let manualCaption = Caption(
            label: "English",
            languageCode: "en",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(manualCaption.isAutoGenerated == false)
    }

    @Test("Caption baseLanguageCode extracts base code")
    func baseLanguageCode() {
        let enUS = Caption(
            label: "English (US)",
            languageCode: "en-US",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(enUS.baseLanguageCode == "en")

        let deDE = Caption(
            label: "German",
            languageCode: "de-DE",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(deDE.baseLanguageCode == "de")

        let simple = Caption(
            label: "French",
            languageCode: "fr",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(simple.baseLanguageCode == "fr")
    }

    @Test("Caption id is unique")
    func captionID() {
        let caption = Caption(
            label: "English",
            languageCode: "en",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        #expect(caption.id == "en:English")
    }

    @Test("Caption displayName strips auto-generated suffix")
    func displayName() {
        let autoCaption = Caption(
            label: "English (auto-generated)",
            languageCode: "en",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        // Should return localized name or stripped label
        #expect(!autoCaption.displayName.contains("auto-generated"))
    }

    @Test("Caption is Codable")
    func codable() throws {
        let caption = Caption(
            label: "Spanish",
            languageCode: "es",
            url: URL(string: "https://example.com/caption.vtt")!
        )
        let encoded = try JSONEncoder().encode(caption)
        let decoded = try JSONDecoder().decode(Caption.self, from: encoded)
        #expect(caption == decoded)
    }

    @Test("Caption is Hashable")
    func hashable() {
        let caption1 = Caption(
            label: "English",
            languageCode: "en",
            url: URL(string: "https://example.com/caption1.vtt")!
        )
        let caption2 = Caption(
            label: "English",
            languageCode: "en",
            url: URL(string: "https://example.com/caption1.vtt")!
        )
        let caption3 = Caption(
            label: "French",
            languageCode: "fr",
            url: URL(string: "https://example.com/caption2.vtt")!
        )

        var set = Set<Caption>()
        set.insert(caption1)
        set.insert(caption2)
        set.insert(caption3)

        #expect(set.count == 2)
    }
}

// MARK: - VideoRowStyle Tests

@Suite("VideoRowStyle Tests")
struct VideoRowStyleTests {

    @Test("Large style dimensions")
    func largeDimensions() {
        let style = VideoRowStyle.large
        #expect(style.thumbnailWidth == 160)
        #expect(style.thumbnailHeight == 90)
    }

    @Test("Regular style dimensions")
    func regularDimensions() {
        let style = VideoRowStyle.regular
        #expect(style.thumbnailWidth == 120)
        #expect(style.thumbnailHeight == 68)
    }

    @Test("Compact style dimensions")
    func compactDimensions() {
        let style = VideoRowStyle.compact
        #expect(style.thumbnailWidth == 70)
        #expect(style.thumbnailHeight == 39)
    }

    @Test("Aspect ratios are 16:9")
    func aspectRatios() {
        for style in [VideoRowStyle.large, .regular, .compact] {
            let ratio = style.thumbnailWidth / style.thumbnailHeight
            // 16:9 ≈ 1.77, allow small tolerance
            #expect(abs(ratio - 16.0/9.0) < 0.1)
        }
    }
}

// MARK: - HomeTab Tests

@Suite("HomeTab Tests")
struct HomeTabTests {

    @Test("All cases exist")
    func allCases() {
        let cases = HomeTab.allCases
        #expect(cases.contains(.playlists))
        #expect(cases.contains(.history))
        #expect(cases.contains(.downloads))
        #expect(cases.count == 3)
    }

    @Test("Titles are not empty")
    func titles() {
        for tab in HomeTab.allCases {
            #expect(!tab.title.isEmpty)
        }
    }

    @Test("Icons are valid SF Symbol names")
    func icons() {
        #expect(HomeTab.playlists.icon == "list.bullet.rectangle")
        #expect(HomeTab.history.icon == "clock")
        #expect(HomeTab.downloads.icon == "arrow.down.circle")
    }

    @Test("Identifiable id uses rawValue")
    func identifiableID() {
        for tab in HomeTab.allCases {
            #expect(tab.id == tab.rawValue)
        }
    }
}

// MARK: - PlayerInfoTab Tests

@Suite("PlayerInfoTab Tests")
struct PlayerInfoTabTests {

    @Test("All cases exist")
    func allCases() {
        let cases = PlayerInfoTab.allCases
        #expect(cases.contains(.description))
        #expect(cases.contains(.comments))
        #expect(cases.count == 2)
    }

    @Test("Titles are not empty")
    func titles() {
        for tab in PlayerInfoTab.allCases {
            #expect(!tab.title.isEmpty)
        }
    }
}

// MARK: - SearchResultType Tests

@Suite("SearchResultType Tests")
struct SearchResultTypeTests {

    @Test("All cases exist")
    func allCases() {
        let cases = SearchResultType.allCases
        #expect(cases.contains(.all))
        #expect(cases.contains(.videos))
        #expect(cases.contains(.channels))
        #expect(cases.contains(.playlists))
        #expect(cases.count == 4)
    }

    @Test("Titles are not empty")
    func titles() {
        for type in SearchResultType.allCases {
            #expect(!type.title.isEmpty)
        }
    }

    @Test("Identifiable id uses rawValue")
    func identifiableID() {
        for type in SearchResultType.allCases {
            #expect(type.id == type.rawValue)
        }
    }
}

// MARK: - CommentsLoadState Tests

@Suite("CommentsLoadState Tests")
struct CommentsLoadStateTests {

    @Test("All states are equatable")
    func equatable() {
        #expect(CommentsLoadState.idle == CommentsLoadState.idle)
        #expect(CommentsLoadState.loading == CommentsLoadState.loading)
        #expect(CommentsLoadState.loaded == CommentsLoadState.loaded)
        #expect(CommentsLoadState.loadingMore == CommentsLoadState.loadingMore)
        #expect(CommentsLoadState.disabled == CommentsLoadState.disabled)
        #expect(CommentsLoadState.error == CommentsLoadState.error)
    }

    @Test("Different states are not equal")
    func notEqual() {
        #expect(CommentsLoadState.idle != CommentsLoadState.loading)
        #expect(CommentsLoadState.loaded != CommentsLoadState.error)
        #expect(CommentsLoadState.loading != CommentsLoadState.loadingMore)
    }
}
