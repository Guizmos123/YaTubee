//
//  FeedNoveltyRegistryTests.swift
//  YatteeTests
//
//  Deterministic tests for persistent subscription feed novelty tracking.
//

import Foundation
import Testing
#if os(iOS)
import UserNotifications
#endif
@testable import Yattee

@Suite("Feed novelty registry", .serialized)
struct FeedNoveltyRegistryTests {
    private let baselineDate = Date(timeIntervalSince1970: 1_000)
    private let refreshDate = Date(timeIntervalSince1970: 2_000)

    #if os(iOS)
    @Test("App icon badge follows ON, OFF and zero without redundant writes")
    func appIconBadgePreferenceAndDeduplication() async {
        let center = TestAppIconBadgeCenter(setting: .enabled)
        let manager = AppIconBadgeManager(center: center)

        await manager.synchronize(realNoveltyCount: 4, isEnabled: true)
        await manager.synchronize(realNoveltyCount: 4, isEnabled: true)
        await manager.synchronize(realNoveltyCount: 4, isEnabled: false)
        await manager.synchronize(realNoveltyCount: 0, isEnabled: true)

        #expect(await center.appliedCounts == [4, 0])
    }

    @Test("App icon badge follows consultation and active scope counts")
    func appIconBadgeCountChanges() async {
        let center = TestAppIconBadgeCenter(setting: .enabled)
        let manager = AppIconBadgeManager(center: center)

        await manager.synchronize(realNoveltyCount: 5, isEnabled: true)
        await manager.synchronize(realNoveltyCount: 2, isEnabled: true)
        await manager.synchronize(realNoveltyCount: 7, isEnabled: true)

        #expect(await center.appliedCounts == [5, 2, 7])

        let firstScope = AppIconBadgeSynchronizationKey(
            scopeRawValue: "local",
            realNoveltyCount: 2,
            isEnabled: true,
            isSceneActive: true
        )
        let secondScope = AppIconBadgeSynchronizationKey(
            scopeRawValue: "piped:other-account",
            realNoveltyCount: 2,
            isEnabled: true,
            isSceneActive: true
        )
        #expect(firstScope != secondScope)
    }

    @Test("App icon badge respects disabled system badge permission")
    func appIconBadgePermissionDenied() async {
        let center = TestAppIconBadgeCenter(setting: .disabled)
        let manager = AppIconBadgeManager(center: center)

        await manager.synchronize(realNoveltyCount: 6, isEnabled: true)

        #expect(await center.appliedCounts.isEmpty)
    }

    @Test("App icon badge receives only the real registry count")
    func appIconBadgeExcludesDebugSimulation() async {
        let center = TestAppIconBadgeCenter(setting: .enabled)
        let manager = AppIconBadgeManager(center: center)
        let realRegistryCount = 2
        let simulatedDebugCount = 10

        await manager.synchronize(realNoveltyCount: realRegistryCount, isEnabled: true)

        #expect(await center.appliedCounts == [2])
        #expect(await center.appliedCounts != [simulatedDebugCount])
    }
    #endif

    @Test("All channels are included by default and preferences persist per scope")
    @MainActor
    func channelBadgePreferencesPersistByScope() {
        let suiteName = "ChannelBadgePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "excluded"
        let instanceID = UUID()
        let firstScope = FeedNoveltyScope.key(
            for: .invidious(instanceID),
            credential: "first-account"
        )
        let secondScope = FeedNoveltyScope.key(
            for: .invidious(instanceID),
            credential: "second-account"
        )
        let otherInstanceScope = FeedNoveltyScope.key(
            for: .invidious(UUID()),
            credential: "first-account"
        )
        let otherSourceScope = FeedNoveltyScope.key(
            for: .piped(instanceID),
            credential: "first-account"
        )
        var preferences = ChannelBadgePreferences(defaults: defaults, storageKey: storageKey)

        #expect(preferences.isIncluded(channelID: "channel", in: firstScope))
        preferences.setIncluded(false, channelID: "channel", in: firstScope)
        #expect(!preferences.isIncluded(channelID: "channel", in: firstScope))
        #expect(preferences.isIncluded(channelID: "channel", in: secondScope))
        #expect(preferences.isIncluded(channelID: "channel", in: otherInstanceScope))
        #expect(preferences.isIncluded(channelID: "channel", in: otherSourceScope))

        preferences = ChannelBadgePreferences(defaults: defaults, storageKey: storageKey)
        #expect(!preferences.isIncluded(channelID: "channel", in: firstScope))
        preferences.setIncluded(true, channelID: "channel", in: firstScope)
        #expect(preferences.isIncluded(channelID: "channel", in: firstScope))
    }

    @Test("Channel exclusions recalculate badges without deleting novelties")
    @MainActor
    func channelBadgeFilteringPreservesRegistry() async {
        await withRegistry { registry, scope, defaults in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [
                    video("one", publishedAt: 1_500, channelID: "first"),
                    video("two", publishedAt: 1_600, channelID: "second")
                ],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            let snapshot = await registry.snapshot(for: scope)
            let badgeState = FeedNoveltyBadgeState()
            badgeState.update(snapshot, for: scope)
            let preferences = ChannelBadgePreferences(defaults: defaults, storageKey: "excluded")

            #expect(badgeState.count(for: scope, excluding: preferences.excludedChannelIDs(in: scope)) == 2)
            preferences.setIncluded(false, channelID: "first", in: scope)
            let filteredCount = badgeState.count(
                for: scope,
                excluding: preferences.excludedChannelIDs(in: scope)
            )
            #expect(filteredCount == 1)
            #expect(await registry.snapshot(for: scope).count == 2)
            #if os(iOS)
            let center = TestAppIconBadgeCenter(setting: .enabled)
            let iconManager = AppIconBadgeManager(center: center)
            await iconManager.synchronize(realNoveltyCount: filteredCount, isEnabled: true)
            #expect(await center.appliedCounts == [1])
            #endif
            preferences.setIncluded(true, channelID: "first", in: scope)
            #expect(badgeState.count(for: scope, excluding: preferences.excludedChannelIDs(in: scope)) == 2)
        }
    }

    @Test("Persisted novelties without a channel remain backward compatible")
    func legacyNoveltyEntryDecoding() throws {
        let entry = FeedNoveltyEntry(
            videoID: "global:youtube:video",
            channelID: "channel",
            publishedAt: baselineDate,
            discoveredAt: refreshDate,
            contentKind: .regular
        )
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "channelID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(FeedNoveltyEntry.self, from: legacyData)

        #expect(decoded.videoID == entry.videoID)
        #expect(decoded.channelID == nil)
    }

    @Test("Channel badge preferences are independent from notification settings")
    @MainActor
    func channelBadgePreferencesAreIndependent() {
        let suiteName = "ChannelBadgePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "backgroundNotificationsEnabled")
        let preferences = ChannelBadgePreferences(defaults: defaults, storageKey: "excluded")

        preferences.setIncluded(false, channelID: "channel", in: FeedNoveltyScope(rawValue: "local"))

        #expect(defaults.bool(forKey: "backgroundNotificationsEnabled"))
    }

    @Test("First complete response establishes a silent baseline")
    func firstBaseline() async {
        await withRegistry { registry, scope, _ in
            await registry.ingest(
                videos: [video("old", publishedAt: 900)],
                scope: scope,
                observedAt: baselineDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            let snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.isInitialized)
            #expect(snapshot.referenceDate == baselineDate)
            #expect(snapshot.count == 0)
        }
    }

    @Test("BADGE-01 local Feed scopes follow source type and instance")
    func localFeedScopeIdentity() {
        let sharedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let otherID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let server = Instance(
            id: sharedID,
            type: .yatteeServer,
            url: URL(string: "https://server.example")!
        )
        let invidious = Instance(
            id: sharedID,
            type: .invidious,
            url: URL(string: "https://invidious.example")!
        )
        let otherInvidious = Instance(
            id: otherID,
            type: .invidious,
            url: URL(string: "https://other.example")!
        )

        let serverScope = FeedNoveltyScope.localFeed(yatteeServer: server)
        let invidiousScope = FeedNoveltyScope.localFeed(invidious: invidious)
        let otherScope = FeedNoveltyScope.localFeed(invidious: otherInvidious)

        #expect(serverScope != invidiousScope)
        #expect(invidiousScope != otherScope)
        #expect(FeedNoveltyScope.localFeed(source: .yatteeServer(server)) == serverScope)
        #expect(FeedNoveltyScope.localFeed(source: .invidious(invidious)) == invidiousScope)
        #expect(FeedNoveltyScope.localFeed(source: .unavailable) == nil)
    }

    @Test("BADGE-01 Invidious baseline and later novelty share one scope")
    func invidiousBaselineAndNovelty() async {
        await withRegistry { registry, _, _ in
            let instance = Instance(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                type: .invidious,
                url: URL(string: "https://invidious.example")!
            )
            let producerScope = FeedNoveltyScope.localFeed(invidious: instance)
            let consumerScope = FeedNoveltyScope.localFeed(source: .invidious(instance))!

            await registry.ingest(
                videos: [video("historical", publishedAt: 900)],
                scope: producerScope,
                observedAt: baselineDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: consumerScope).count == 0)

            await registry.ingest(
                videos: [video("new", publishedAt: 1_500)],
                scope: producerScope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            let snapshot = await registry.snapshot(for: consumerScope)
            #expect(snapshot.count == 1)
            #expect(snapshot.unconsulted.map(\.videoID) == ["global:youtube:new"])
        }
    }

    @Test("BADGE-01 incomplete Invidious snapshots never establish or advance a baseline")
    func invidiousIncompleteSnapshot() async {
        await withRegistry { registry, _, _ in
            let instance = Instance(
                type: .invidious,
                url: URL(string: "https://invidious.example")!
            )
            let scope = FeedNoveltyScope.localFeed(invidious: instance)

            await registry.ingest(
                videos: [video("partial-history", publishedAt: 900)],
                scope: scope,
                observedAt: baselineDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            var snapshot = await registry.snapshot(for: scope)
            #expect(!snapshot.isInitialized)
            #expect(snapshot.referenceDate == nil)

            await registry.ingest(
                videos: [],
                scope: scope,
                observedAt: baselineDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.ingest(
                videos: [video("partial-new", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 1)
            #expect(snapshot.referenceDate == baselineDate)
        }
    }

    @Test("BADGE-01 Yattee Server baseline and novelty use the server scope")
    func yatteeServerBaselineAndNovelty() async {
        await withRegistry { registry, _, _ in
            let instance = Instance(
                type: .yatteeServer,
                url: URL(string: "https://server.example")!
            )
            let scope = FeedNoveltyScope.localFeed(yatteeServer: instance)

            await registry.ingest(
                videos: [video("historical", publishedAt: 900)],
                scope: scope,
                observedAt: baselineDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.ingest(
                videos: [
                    video("historical", publishedAt: 900),
                    video("new", publishedAt: 1_500),
                ],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            let snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 1)
            #expect(snapshot.unconsulted.map(\.videoID) == ["global:youtube:new"])
        }
    }

    @Test("BADGE-01 changing local Feed source keeps registries isolated")
    func localFeedSourceChange() async {
        await withRegistry { registry, _, _ in
            let server = Instance(
                type: .yatteeServer,
                url: URL(string: "https://server.example")!
            )
            let invidious = Instance(
                type: .invidious,
                url: URL(string: "https://invidious.example")!
            )
            let serverScope = FeedNoveltyScope.localFeed(yatteeServer: server)
            let invidiousScope = FeedNoveltyScope.localFeed(invidious: invidious)

            await establishBaseline(registry, scope: serverScope)
            await registry.ingest(
                videos: [video("server-new", publishedAt: 1_500)],
                scope: serverScope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.ingest(
                videos: [video("invidious-history", publishedAt: 900)],
                scope: invidiousScope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            #expect(await registry.snapshot(for: serverScope).count == 1)
            #expect(await registry.snapshot(for: invidiousScope).count == 0)
        }
    }

    @Test("BADGE-01 legacy local state migrates once and survives relaunch")
    func legacyLocalMigrationAndPersistence() async {
        let suiteName = "FeedNoveltyRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyScope = FeedNoveltyScope(rawValue: "local")
        let server = Instance(
            type: .yatteeServer,
            url: URL(string: "https://server.example")!
        )
        let migratedScope = FeedNoveltyScope.localFeed(yatteeServer: server)

        var registry = FeedNoveltyRegistry(defaults: defaults, storageKey: storageKey)
        await establishBaseline(registry, scope: legacyScope)
        await registry.ingest(
            videos: [video("preserved", publishedAt: 1_500)],
            scope: legacyScope,
            observedAt: refreshDate,
            isCompleteSnapshot: true,
            includeShorts: false
        )

        #expect(await registry.snapshot(for: migratedScope).count == 1)
        registry = FeedNoveltyRegistry(defaults: defaults, storageKey: storageKey)
        #expect(await registry.snapshot(for: migratedScope).count == 1)
        #expect(await registry.snapshot(for: legacyScope).count == 0)
    }

    @Test("State and unconsulted novelties survive registry recreation")
    func persistence() async {
        await withRegistry { registry, scope, defaults in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("new", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            let restored = FeedNoveltyRegistry(defaults: defaults, storageKey: storageKey)
            let snapshot = await restored.snapshot(for: scope)
            #expect(snapshot.count == 1)
            #expect(snapshot.unconsulted.map(\.videoID) == ["global:youtube:new"])
        }
    }

    @Test("Credentials separate accounts on the same instance")
    func accountScopedIdentity() async {
        let instanceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let account = SubscriptionAccount.invidious(instanceID)
        let first = FeedNoveltyScope.key(for: account, credential: "account-one-session")
        let second = FeedNoveltyScope.key(for: account, credential: "account-two-session")
        #expect(first != second)
        #expect(!first.rawValue.contains("account-one-session"))

        await withRegistry { registry, _, _ in
            await establishBaseline(registry, scope: first)
            await registry.ingest(
                videos: [video("same-id", publishedAt: 1_500)],
                scope: first,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.ingest(
                videos: [video("same-id", publishedAt: 1_500)],
                scope: second,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            #expect(await registry.snapshot(for: first).count == 1)
            #expect(await registry.snapshot(for: second).count == 0)
        }
    }

    @Test("Duplicates and paginated responses are counted once")
    func duplicatesAndPagination() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("one", publishedAt: 1_400), video("one", publishedAt: 1_400)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            await registry.ingest(
                videos: [video("one", publishedAt: 1_400), video("two", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            #expect(await registry.snapshot(for: scope).count == 2)
        }
    }

    @Test("Partial responses cannot initialize or advance a baseline")
    func partialResponses() async {
        await withRegistry { registry, scope, _ in
            await registry.ingest(
                videos: [video("partial", publishedAt: 900)],
                scope: scope,
                observedAt: baselineDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            var snapshot = await registry.snapshot(for: scope)
            #expect(!snapshot.isInitialized)
            #expect(snapshot.referenceDate == nil)

            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("new", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 1)
            #expect(snapshot.referenceDate == baselineDate)
        }
    }

    @Test("Upcoming content becomes new only after publication")
    func upcomingBecomesPublished() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("premiere", publishedAt: 1_500, isUpcoming: true)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 0)

            await registry.ingest(
                videos: [video("premiere", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 1)
        }
    }

    @Test("Missing and future dates are not invented or counted")
    func invalidDates() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [
                    video("missing", publishedAt: nil),
                    video("future", publishedAt: 2_500),
                ],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 0)
        }
    }

    @Test("Shorts policy excludes only confirmed Shorts without later catch-up")
    func shortsPolicyAndPreferenceChanges() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [
                    video("short-off", publishedAt: 1_200, kind: .short),
                    video("unknown", publishedAt: 1_300, kind: .unknown),
                    video("regular", publishedAt: 1_400, kind: .regular),
                ],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 2)

            await registry.ingest(
                videos: [
                    video("short-off", publishedAt: 1_200, kind: .short),
                    video("short-on", publishedAt: 1_500, kind: .short),
                ],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: true
            )
            #expect(await registry.snapshot(for: scope).count == 3)

            await registry.ingest(
                videos: [],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 2)
        }
    }

    @Test("Consultation removes only the supplied identifiers")
    func partialConsultation() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("one", publishedAt: 1_400), video("two", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.markConsulted(videoIDs: ["global:youtube:one"], in: scope)

            let snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 1)
            #expect(snapshot.unconsulted.map(\.videoID) == ["global:youtube:two"])
        }
    }

    @Test("Pruned known videos cannot reappear as false novelties")
    func pruningDoesNotReintroduceOldVideos() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            let videos = (0..<(FeedNoveltyRegistry.maximumKnownVideoCount + 10)).map {
                video("video-\($0)", publishedAt: TimeInterval(1_100 + $0))
            }
            let completionDate = Date(timeIntervalSince1970: 10_000)
            await registry.ingest(
                videos: videos,
                scope: scope,
                observedAt: completionDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            await registry.markConsulted(
                videoIDs: Set(videos.map { $0.id.id }),
                in: scope
            )

            await registry.ingest(
                videos: [videos[0]],
                scope: scope,
                observedAt: Date(timeIntervalSince1970: 11_000),
                isCompleteSnapshot: false,
                includeShorts: false
            )
            #expect(await registry.snapshot(for: scope).count == 0)
        }
    }

    @Test("Badge presentation follows its preference and hides zero")
    func badgePresentation() {
        #expect(FeedNoveltyBadgePresentation.count(registryCount: 0, isEnabled: true) == 0)
        #expect(FeedNoveltyBadgePresentation.count(registryCount: 3, isEnabled: false) == 0)
        #expect(FeedNoveltyBadgePresentation.count(registryCount: 3, isEnabled: true) == 3)
    }

    @Test("Consultation requires a visible cell, active tab, and active scene")
    func consultationPolicy() {
        let visibleIDs: Set<String> = ["global:youtube:visible"]
        #expect(FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: false,
            isSceneActive: true,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: false,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            visibleVideoIDs: []
        ))
    }

    @Test("Published badge state follows discovery and exact consultation")
    func badgeStatePropagation() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("visible", publishedAt: 1_500), video("offscreen", publishedAt: 1_600)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            let discoveredCount = await MainActor.run {
                FeedNoveltyBadgeState.shared.count(for: scope)
            }
            #expect(discoveredCount == 2)

            await registry.markConsulted(videoIDs: ["global:youtube:visible"], in: scope)
            let remainingCount = await MainActor.run {
                FeedNoveltyBadgeState.shared.count(for: scope)
            }
            #expect(remainingCount == 1)
            #expect(await registry.snapshot(for: scope).unconsulted.map(\.videoID) == [
                "global:youtube:offscreen",
            ])
        }
    }

    #if DEBUG
    @Test("Diagnostic selects ten exact feed IDs and decrements only visible IDs")
    @MainActor
    func diagnosticVisibilityCountdown() {
        let diagnostic = FeedNoveltyBadgeDiagnosticState.shared
        diagnostic.finish()
        let scope = FeedNoveltyScope(rawValue: "diagnostic-scope")
        let videos = (0..<12).map { video("diagnostic-\($0)", publishedAt: 1_500) }

        #expect(diagnostic.start(videos: videos, scope: scope) == 10)
        #expect(diagnostic.remainingCount == 10)

        diagnostic.markVisible(
            videoIDs: Set(videos.prefix(3).map { $0.id.id })
                .union(["global:youtube:not-selected"]),
            in: scope
        )
        #expect(diagnostic.remainingCount == 7)

        diagnostic.markVisible(videoIDs: [videos[0].id.id], in: scope)
        #expect(diagnostic.remainingCount == 7)

        diagnostic.markVisible(
            videoIDs: Set(videos.prefix(10).map { $0.id.id }),
            in: scope
        )
        #expect(diagnostic.remainingCount == 0)
        diagnostic.finish()
    }

    @Test("Diagnostic finishes when its account or feed changes")
    @MainActor
    func diagnosticContextChange() {
        let diagnostic = FeedNoveltyBadgeDiagnosticState.shared
        let scope = FeedNoveltyScope(rawValue: "first-scope")
        let videos = (0..<10).map { video("context-\($0)", publishedAt: 1_500) }
        diagnostic.start(videos: videos, scope: scope)

        diagnostic.finishIfContextChanged(
            scope: scope,
            availableVideoIDs: Set(videos.map { $0.id.id })
        )
        #expect(diagnostic.isActive)

        diagnostic.finishIfContextChanged(
            scope: FeedNoveltyScope(rawValue: "second-scope"),
            availableVideoIDs: Set(videos.map { $0.id.id })
        )
        #expect(!diagnostic.isActive)
    }

    @Test("Diagnostic consultation leaves the persistent registry untouched")
    func diagnosticIsolation() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            let videos = [video("real-one", publishedAt: 1_500), video("real-two", publishedAt: 1_600)]
            await registry.ingest(
                videos: videos,
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )

            await MainActor.run {
                let diagnostic = FeedNoveltyBadgeDiagnosticState.shared
                diagnostic.start(videos: videos, scope: scope)
                diagnostic.markVisible(videoIDs: [videos[0].id.id], in: scope)
                #expect(diagnostic.remainingCount == 1)
                diagnostic.finish()
            }

            #expect(await registry.snapshot(for: scope).count == 2)
        }
    }
    #endif

    private var storageKey: String { "FeedNoveltyRegistryTests.state" }

    private func withRegistry(
        _ body: (FeedNoveltyRegistry, FeedNoveltyScope, UserDefaults) async throws -> Void
    ) async rethrows {
        let suiteName = "FeedNoveltyRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = FeedNoveltyRegistry(defaults: defaults, storageKey: storageKey)
        try await body(registry, FeedNoveltyScope(rawValue: "test-scope"), defaults)
    }

    private func establishBaseline(
        _ registry: FeedNoveltyRegistry,
        scope: FeedNoveltyScope
    ) async {
        await registry.ingest(
            videos: [],
            scope: scope,
            observedAt: baselineDate,
            isCompleteSnapshot: true,
            includeShorts: false
        )
    }

    private func video(
        _ id: String,
        publishedAt: TimeInterval?,
        isUpcoming: Bool = false,
        kind: VideoContentKind = .unknown,
        channelID: String = "channel"
    ) -> Video {
        Video(
            id: .global(id),
            title: id,
            description: nil,
            author: Author(id: channelID, name: "Channel"),
            duration: 60,
            publishedAt: publishedAt.map(Date.init(timeIntervalSince1970:)),
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: isUpcoming,
            contentKind: kind,
            scheduledStartTime: nil
        )
    }
}

#if os(iOS)
private actor TestAppIconBadgeCenter: AppIconBadgeCenter {
    let setting: UNNotificationSetting
    private(set) var appliedCounts: [Int] = []

    init(setting: UNNotificationSetting) {
        self.setting = setting
    }

    func badgeSetting() async -> UNNotificationSetting {
        setting
    }

    func setBadgeCount(_ count: Int) async throws {
        appliedCounts.append(count)
    }
}
#endif
