//
//  NotificationRefreshTransactionTests.swift
//  YatteeTests
//
//  Deterministic tests for transactional background notification refreshes.
//

import Foundation
import Testing
import UserNotifications
@testable import YaTubee

@Suite("Notification refresh transaction")
struct NotificationRefreshTransactionTests {
    private let previousCheck = Date(timeIntervalSince1970: 1_000)
    private let requestStart = Date(timeIntervalSince1970: 2_000)

    @Test("Background refresh remains enabled for either consumer")
    func refreshConsumerCombinations() {
        #expect(BackgroundRefreshPolicy.isEnabled(notificationsEnabled: true, appIconBadgeEnabled: false))
        #expect(BackgroundRefreshPolicy.isEnabled(notificationsEnabled: false, appIconBadgeEnabled: true))
        #expect(BackgroundRefreshPolicy.isEnabled(notificationsEnabled: true, appIconBadgeEnabled: true))
        #expect(!BackgroundRefreshPolicy.isEnabled(notificationsEnabled: false, appIconBadgeEnabled: false))
    }

    @Test("A pending BGTask request is not submitted twice")
    func duplicateSchedulingIsPrevented() {
        let identifier = "com.app.yatubee.feedRefresh"
        #expect(BackgroundRefreshPolicy.shouldSubmit(
            pendingIdentifiers: [], identifier: identifier, isEnabled: true, isAvailable: true
        ))
        #expect(!BackgroundRefreshPolicy.shouldSubmit(
            pendingIdentifiers: [identifier], identifier: identifier, isEnabled: true, isAvailable: true
        ))
        #expect(!BackgroundRefreshPolicy.shouldSubmit(
            pendingIdentifiers: [], identifier: identifier, isEnabled: false, isAvailable: true
        ))
        #expect(!BackgroundRefreshPolicy.shouldSubmit(
            pendingIdentifiers: [], identifier: identifier, isEnabled: true, isAvailable: false
        ))
    }

    @Test("An acquired snapshot is consumed only by its still-active BADGE-01 scope")
    func sourceChangeRejectsObsoleteAcquisition() {
        let server = FeedNoveltyScope(rawValue: "local-feed:yattee-server:server")
        let invidious = FeedNoveltyScope(rawValue: "local-feed:invidious:instance")
        #expect(BackgroundRefreshPolicy.canConsume(acquiredScope: server, activeScope: server))
        #expect(!BackgroundRefreshPolicy.canConsume(acquiredScope: server, activeScope: invidious))
        #expect(!BackgroundRefreshPolicy.canConsume(acquiredScope: server, activeScope: nil))
    }

    @Test("A partial snapshot cannot establish the notification baseline")
    func partialSnapshotBaselinePolicy() {
        #expect(!BackgroundRefreshPolicy.canProcessNotifications(
            isCompleteSnapshot: false, hasBaseline: false
        ))
        #expect(BackgroundRefreshPolicy.canProcessNotifications(
            isCompleteSnapshot: true, hasBaseline: false
        ))
        #expect(BackgroundRefreshPolicy.canProcessNotifications(
            isCompleteSnapshot: false, hasBaseline: true
        ))
    }

    @Test("Foreground and background callers share one Feed acquisition")
    @MainActor
    func feedRefreshSingleFlightSharesAcquisition() async {
        let gate = BackgroundRefreshTestGate()
        let singleFlight = FeedRefreshSingleFlight()
        var acquisitionCount = 0

        let background = Task { @MainActor in
            await singleFlight.run(foregroundParticipant: false) {
                acquisitionCount += 1
                await gate.wait()
            }
        }
        while acquisitionCount == 0 { await Task.yield() }
        let foreground = Task { @MainActor in
            await singleFlight.run(foregroundParticipant: true) {
                acquisitionCount += 1
            }
        }
        await Task.yield()

        background.cancel()
        #expect(await background.value == false)
        await gate.open()
        #expect(await foreground.value)
        #expect(acquisitionCount == 1)
    }

    @Test("Expiration releases an exclusively background Feed waiter")
    @MainActor
    func exclusiveBackgroundRefreshCancellation() async {
        let gate = BackgroundRefreshTestGate()
        let singleFlight = FeedRefreshSingleFlight()
        var started = false
        let background = Task { @MainActor in
            await singleFlight.run(foregroundParticipant: false) {
                started = true
                await gate.wait()
            }
        }
        while !started { await Task.yield() }

        background.cancel()
        #expect(await background.value == false)
        await gate.open()
    }

    #if DEBUG
    @Test("Notification diagnostic history remains bounded and Codable")
    @MainActor
    func diagnosticHistoryIsBoundedAndCodable() throws {
        let runs = (0..<25).map { index in
            NotificationPipelineDiagnostic.Run(
                id: UUID(),
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                origin: "test"
            )
        }
        let bounded = NotificationPipelineDiagnostic.boundedRuns(runs)
        let encoded = try JSONEncoder().encode(bounded)
        let decoded = try JSONDecoder().decode([NotificationPipelineDiagnostic.Run].self, from: encoded)

        #expect(decoded.count == 20)
        #expect(decoded.first?.startedAt == runs.first?.startedAt)
        #expect(decoded.last?.startedAt == runs[19].startedAt)
    }
    #endif

    @Test("First launch establishes a baseline without historical notifications")
    func firstLaunch() {
        let plan = makePlan(previousCheck: nil, candidates: [candidate("old", publishedAt: 1_500)])
        let state = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )

        #expect(plan.isInitialBaseline)
        #expect(plan.eligibleKeys.isEmpty)
        #expect(state.lastCheck == requestStart)
        #expect(state.processedVideos.isEmpty)
    }

    @Test("A video is accepted once across repeated refreshes")
    func uniqueVideoAndRepeatedRefresh() {
        let firstPlan = makePlan(candidates: [candidate("one", publishedAt: 1_500)])
        let firstState = NotificationRefreshTransaction.committedState(
            for: firstPlan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )
        let repeatedPlan = makePlan(
            processedKeys: Set(firstState.processedVideos.keys),
            candidates: [candidate("one", publishedAt: 1_500)]
        )

        #expect(firstPlan.eligibleKeys == ["global:youtube:one"])
        #expect(repeatedPlan.eligibleKeys.isEmpty)
    }

    @Test("Multiple videos are ordered deterministically despite response order")
    func multipleVideosAndDisorderedResponse() {
        let plan = makePlan(candidates: [
            candidate("third", publishedAt: 1_700),
            candidate("first", publishedAt: 1_300),
            candidate("second", publishedAt: 1_500)
        ])

        #expect(plan.eligibleKeys == [
            "global:youtube:first",
            "global:youtube:second",
            "global:youtube:third"
        ])
    }

    @Test("A failed submission commits no eligible IDs and keeps the cursor")
    func failedSubmissionIsRetried() {
        let plan = makePlan(candidates: [candidate("retry", publishedAt: 1_500)])
        let state = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: false,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )

        #expect(state.lastCheck == requestStart)
        #expect(state.processedVideos.isEmpty)
        #expect(state.pendingVideos.keys.contains("global:youtube:retry"))

        let retryPlan = NotificationRefreshTransaction.plan(
            candidates: [candidate("retry", publishedAt: 1_500)],
            requestStartedAt: Date(timeIntervalSince1970: 3_000),
            previousCheck: state.lastCheck,
            processedKeys: [],
            legacyProcessedVideoIDs: [],
            pendingKeys: Set(state.pendingVideos.keys),
            includeShorts: false
        )
        #expect(retryPlan.eligibleKeys == ["global:youtube:retry"])
    }

    @Test("A video published during the request is picked up by the next window")
    func videoPublishedDuringRequest() {
        let publishedDuringRequest: TimeInterval = 2_100
        let firstPlan = makePlan(candidates: [candidate("during", publishedAt: publishedDuringRequest)])
        let firstState = NotificationRefreshTransaction.committedState(
            for: firstPlan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )
        let nextPlan = NotificationRefreshTransaction.plan(
            candidates: [candidate("during", publishedAt: publishedDuringRequest)],
            requestStartedAt: Date(timeIntervalSince1970: 3_000),
            previousCheck: firstState.lastCheck,
            processedKeys: [],
            legacyProcessedVideoIDs: [],
            pendingKeys: [],
            includeShorts: false
        )

        #expect(firstPlan.eligibleKeys.isEmpty)
        #expect(firstState.lastCheck == requestStart)
        #expect(nextPlan.eligibleKeys == ["global:youtube:during"])
    }

    @Test("Watched videos are permanently ignored")
    func watchedVideo() {
        let plan = makePlan(candidates: [candidate("watched", publishedAt: 1_500, isWatched: true)])
        let state = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )

        #expect(plan.eligibleKeys.isEmpty)
        #expect(plan.ignoredKeys == ["global:youtube:watched"])
        #expect(state.processedVideos.keys.contains("global:youtube:watched"))
    }

    @Test("Shorts OFF excludes only confirmed shorts")
    func shortsDisabled() {
        let plan = makePlan(candidates: [
            candidate("regular", publishedAt: 1_500, contentKind: .regular),
            candidate("short", publishedAt: 1_600, contentKind: .short),
            candidate("unknown", publishedAt: 1_700, contentKind: .unknown)
        ])

        #expect(plan.eligibleKeys == [
            "global:youtube:regular",
            "global:youtube:unknown"
        ])
        #expect(plan.ignoredKeys == ["global:youtube:short"])
    }

    @Test("Shorts ON permits confirmed shorts")
    func shortsEnabled() {
        let plan = makePlan(
            includeShorts: true,
            candidates: [candidate("short", publishedAt: 1_500, contentKind: .short)]
        )

        #expect(plan.eligibleKeys == ["global:youtube:short"])
        #expect(plan.ignoredKeys.isEmpty)
    }

    @Test("Re-enabling Shorts does not catch up a previously excluded Short")
    func shortsDisabledThenEnabled() {
        let disabledPlan = makePlan(
            candidates: [candidate("short", publishedAt: 1_500, contentKind: .short)]
        )
        let disabledState = NotificationRefreshTransaction.committedState(
            for: disabledPlan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )
        let enabledPlan = makePlan(
            processedKeys: Set(disabledState.processedVideos.keys),
            includeShorts: true,
            candidates: [candidate("short", publishedAt: 1_500, contentKind: .short)]
        )

        #expect(disabledPlan.ignoredKeys == ["global:youtube:short"])
        #expect(enabledPlan.eligibleKeys.isEmpty)
    }

    @Test("A pending Short is finalized when Shorts become disabled")
    func pendingShortAfterPreferenceChange() {
        let key = "global:youtube:short-retry"
        let plan = NotificationRefreshTransaction.plan(
            candidates: [candidate("short-retry", publishedAt: 1_500, contentKind: .short)],
            requestStartedAt: requestStart,
            previousCheck: previousCheck,
            processedKeys: [],
            legacyProcessedVideoIDs: [],
            pendingKeys: [key],
            includeShorts: false
        )
        let state = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [key: previousCheck.timeIntervalSince1970]
        )

        #expect(plan.ignoredKeys == [key])
        #expect(plan.eligibleKeys.isEmpty)
        #expect(state.processedVideos[key] != nil)
        #expect(state.pendingVideos[key] == nil)
    }

    @Test("Upcoming videos defer the cursor and become eligible after airing")
    func upcomingVideo() {
        let upcomingPlan = makePlan(
            candidates: [candidate("premiere", publishedAt: 1_500, isUpcoming: true)]
        )
        let upcomingState = NotificationRefreshTransaction.committedState(
            for: upcomingPlan,
            submissionAccepted: true,
            existingProcessedVideos: [:],
            existingPendingVideos: [:]
        )
        let airedPlan = NotificationRefreshTransaction.plan(
            candidates: [candidate("premiere", publishedAt: 1_500)],
            requestStartedAt: Date(timeIntervalSince1970: 3_000),
            previousCheck: upcomingState.lastCheck,
            processedKeys: [],
            legacyProcessedVideoIDs: [],
            pendingKeys: Set(upcomingState.pendingVideos.keys),
            includeShorts: false
        )

        #expect(upcomingPlan.deferredKeys == ["global:youtube:premiere"])
        #expect(upcomingState.lastCheck == requestStart)
        #expect(airedPlan.eligibleKeys == ["global:youtube:premiere"])
    }

    @Test("Legacy per-channel IDs remain valid deduplication input")
    func legacyPersistenceCompatibility() {
        let plan = makePlan(
            legacyVideoIDs: ["legacy"],
            candidates: [candidate("legacy", publishedAt: 1_500)]
        )

        #expect(plan.eligibleKeys.isEmpty)
    }

    @Test("The processed ledger remains bounded")
    func boundedPersistence() {
        let existing = Dictionary(uniqueKeysWithValues: (0...600).map {
            ("video-\($0)", TimeInterval($0))
        })
        let plan = makePlan(candidates: [])
        let state = NotificationRefreshTransaction.committedState(
            for: plan,
            submissionAccepted: true,
            existingProcessedVideos: existing,
            existingPendingVideos: [:]
        )

        #expect(state.processedVideos.count == NotificationRefreshTransaction.maximumProcessedVideoCount)
        #expect(state.processedVideos["video-600"] != nil)
        #expect(state.processedVideos["video-0"] == nil)
    }

    @Test("Yattee Server partial and failed responses are not complete")
    func yatteeServerCompleteness() {
        let partial = serverResponse(status: "pending", pendingCount: 2, errorCount: 0)
        let failedChannel = serverResponse(status: "ready", pendingCount: 0, errorCount: 1)
        let complete = serverResponse(status: "ready", pendingCount: 0, errorCount: 0)

        #expect(!NotificationRefreshTransaction.isCompleteYatteeServerResponse(partial))
        #expect(!NotificationRefreshTransaction.isCompleteYatteeServerResponse(failedChannel))
        #expect(NotificationRefreshTransaction.isCompleteYatteeServerResponse(complete))
    }

    @Test("A concurrent refresh is coalesced and the gate recovers after completion")
    func concurrentRefreshGate() {
        var state = NotificationRefreshRunState()

        let firstBegin = state.begin()
        let concurrentBegin = state.begin()
        state.end()
        let beginAfterCompletion = state.begin()

        #expect(firstBegin)
        #expect(!concurrentBegin)
        #expect(beginAfterCompletion)
    }

    @Test("A retry payload survives absence from a later feed and remains bounded")
    func retryPayloadPersistence() throws {
        let record = PendingNotificationRecord(
            video: video("retry"),
            channelName: "Channel",
            queuedAt: 2_000
        )
        let encoded = try JSONEncoder().encode(["global:youtube:retry": record])
        let decoded = try JSONDecoder().decode([String: PendingNotificationRecord].self, from: encoded)

        #expect(decoded["global:youtube:retry"]?.video.id.videoID == "retry")
        #expect(decoded["global:youtube:retry"]?.channelName == "Channel")

        let oversized = Dictionary(uniqueKeysWithValues: (0...600).map { index in
            let key = "global:youtube:\(index)"
            return (key, PendingNotificationRecord(
                video: video("\(index)"),
                channelName: "Channel",
                queuedAt: TimeInterval(index)
            ))
        })
        let bounded = NotificationRefreshTransaction.boundedPendingRecords(oversized)
        #expect(bounded.count == NotificationRefreshTransaction.maximumProcessedVideoCount)
        #expect(bounded["global:youtube:600"] != nil)
        #expect(bounded["global:youtube:0"] == nil)
    }

    @Test("Notification refresh scopes separate accounts and instances")
    func accountScopes() {
        let firstInstance = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondInstance = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        #expect(NotificationRefreshScope.key(for: .local) == "local")
        #expect(
            NotificationRefreshScope.key(for: .invidious(firstInstance))
                != NotificationRefreshScope.key(for: .invidious(secondInstance))
        )
        #expect(
            NotificationRefreshScope.key(for: .invidious(firstInstance))
                != NotificationRefreshScope.key(for: .piped(firstInstance))
        )
    }

    @Test("System notification authorization distinguishes presentable statuses")
    @MainActor
    func authorizationStatuses() {
        #expect(NotificationManager.permitsNotificationSubmission(.authorized))
        #expect(NotificationManager.permitsNotificationSubmission(.provisional))
        #if os(iOS)
        #expect(NotificationManager.permitsNotificationSubmission(.ephemeral))
        #endif
        #expect(!NotificationManager.permitsNotificationSubmission(.denied))
        #expect(!NotificationManager.permitsNotificationSubmission(.notDetermined))
    }

    @Test("General notification permission includes the app icon badge")
    @MainActor
    func notificationAuthorizationIncludesBadge() {
        let options = NotificationManager.notificationAuthorizationOptions
        #expect(options.contains(.alert))
        #expect(options.contains(.sound))
        #expect(options.contains(.badge))
    }

    #if !os(tvOS)
    @Test("Notification payload carries the global badge count when enabled")
    @MainActor
    func notificationPayloadCarriesGlobalBadgeCount() {
        let videos = [(video: video("one"), channelName: "Channel")]
        let content = NotificationManager.notificationContent(
            for: videos,
            appIconBadgeCount: 7
        )

        #expect(content.badge?.intValue == 7)
    }

    @Test("Notification payload leaves the badge unchanged when badges are disabled")
    @MainActor
    func notificationPayloadOmitsDisabledBadge() {
        let videos = [(video: video("one"), channelName: "Channel")]
        let content = NotificationManager.notificationContent(
            for: videos,
            appIconBadgeCount: nil
        )

        #expect(content.badge == nil)
    }

    @Test("Notification payload explicitly carries a zero global badge count")
    @MainActor
    func notificationPayloadCarriesZeroBadge() {
        let videos = [(video: video("one"), channelName: "Channel")]
        let content = NotificationManager.notificationContent(
            for: videos,
            appIconBadgeCount: 0
        )

        #expect(content.badge?.intValue == 0)
    }

    @Test("Notification payload badge is independent from the notified video count")
    @MainActor
    func notificationPayloadDoesNotUseNotifiedVideoCount() {
        let videos = [
            (video: video("one"), channelName: "Channel"),
            (video: video("two"), channelName: "Channel")
        ]
        let content = NotificationManager.notificationContent(
            for: videos,
            appIconBadgeCount: 11
        )

        #expect(videos.count == 2)
        #expect(content.badge?.intValue == 11)
    }
    #endif

    @Test("Identical channel IDs from different content sources have distinct video keys")
    func sourceScopedVideoKeys() {
        let youtube = VideoID.global("shared-channel-video", provider: "youtube")
        let otherProvider = VideoID.global("shared-channel-video", provider: "other")

        #expect(youtube.id != otherProvider.id)
    }

    private func makePlan(
        previousCheck: Date? = Date(timeIntervalSince1970: 1_000),
        processedKeys: Set<String> = [],
        legacyVideoIDs: Set<String> = [],
        includeShorts: Bool = false,
        candidates: [NotificationRefreshCandidate]
    ) -> NotificationRefreshPlan {
        NotificationRefreshTransaction.plan(
            candidates: candidates,
            requestStartedAt: requestStart,
            previousCheck: previousCheck,
            processedKeys: processedKeys,
            legacyProcessedVideoIDs: legacyVideoIDs,
            pendingKeys: [],
            includeShorts: includeShorts
        )
    }

    private func candidate(
        _ videoID: String,
        publishedAt: TimeInterval?,
        isUpcoming: Bool = false,
        isWatched: Bool = false,
        contentKind: VideoContentKind = .unknown
    ) -> NotificationRefreshCandidate {
        NotificationRefreshCandidate(
            deduplicationKey: "global:youtube:\(videoID)",
            legacyVideoID: videoID,
            publishedAt: publishedAt.map(Date.init(timeIntervalSince1970:)),
            isUpcoming: isUpcoming,
            isWatched: isWatched,
            contentKind: contentKind
        )
    }


    private func serverResponse(
        status: String,
        pendingCount: Int,
        errorCount: Int
    ) -> StatelessFeedResponse {
        StatelessFeedResponse(
            status: status,
            videos: [],
            total: 0,
            hasMore: false,
            readyCount: 1,
            pendingCount: pendingCount,
            errorCount: errorCount,
            etaSeconds: nil
        )
    }

    private func video(_ id: String) -> Video {
        Video(
            id: .global(id),
            title: "Video \(id)",
            description: nil,
            author: Author(id: "channel", name: "Channel"),
            duration: 60,
            publishedAt: Date(timeIntervalSince1970: 1_500),
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: false,
            scheduledStartTime: nil
        )
    }
}

private actor BackgroundRefreshTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
