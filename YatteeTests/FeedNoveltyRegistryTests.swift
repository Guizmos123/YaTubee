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
@testable import YaTubee

@Suite("Feed novelty registry", .serialized)
struct FeedNoveltyRegistryTests {
    private let baselineDate = Date(timeIntervalSince1970: 1_000)
    private let refreshDate = Date(timeIntervalSince1970: 2_000)

    #if os(iOS)
    @Test("App icon badge uses an authorization that is already granted")
    @MainActor
    func appIconBadgeAlreadyAuthorized() async {
        let provider = TestAppIconBadgeProvider(state: .authorized)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(await manager.enable(count: 4))
        #expect(await provider.requestCount == 0)
        #expect(await provider.appliedCounts == [4])
    }

    @Test("App icon badge requests badge-only permission once and applies the count")
    @MainActor
    func appIconBadgeFirstRequestAccepted() async {
        let provider = TestAppIconBadgeProvider(state: .notDetermined, requestResult: true)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(await manager.enable(count: 5))
        #expect(await provider.requestCount == 1)
        #expect(await provider.settingsReadCount == 2)
        #expect(await provider.appliedCounts == [5])
    }

    @Test("A refused first badge request does not apply a count")
    @MainActor
    func appIconBadgeFirstRequestRefused() async {
        let provider = TestAppIconBadgeProvider(state: .notDetermined, requestResult: false)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(!(await manager.enable(count: 5)))
        #expect(await provider.requestCount == 1)
        #expect(await provider.settingsReadCount == 2)
        #expect(await provider.appliedCounts.isEmpty)
    }

    @Test("Badge enable trusts the post-request system setting")
    @MainActor
    func appIconBadgeRequestRechecksSystemSetting() async {
        let provider = TestAppIconBadgeProvider(
            state: .notDetermined,
            requestResult: true,
            stateAfterRequest: .denied
        )
        let manager = AppIconBadgeManager(provider: provider)

        #expect(!(await manager.enable(count: 6)))
        #expect(await provider.requestCount == 1)
        #expect(await provider.settingsReadCount == 2)
        #expect(await provider.appliedCounts.isEmpty)
    }

    @Test("A previous badge refusal never prompts again")
    @MainActor
    func appIconBadgePreviousRefusal() async {
        let provider = TestAppIconBadgeProvider(state: .denied)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(!(await manager.enable(count: 3)))
        #expect(!(await manager.enable(count: 3)))
        #expect(await provider.requestCount == 0)
        #expect(await provider.appliedCounts.isEmpty)
    }

    @Test("Disabling always attempts to clear the app icon badge")
    @MainActor
    func appIconBadgeDisableClearsUnconditionally() async {
        let provider = TestAppIconBadgeProvider(state: .denied)
        let manager = AppIconBadgeManager(provider: provider)

        await manager.apply(count: 99, enabled: false)

        #expect(await provider.appliedCounts == [0])
    }

    @Test("Foreground reconciliation observes a changed system badge permission")
    @MainActor
    func appIconBadgeForegroundReconciliation() async {
        let provider = TestAppIconBadgeProvider(state: .denied)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(!(await manager.reconcile(count: 2, enabled: true)))
        await provider.setState(.authorized)
        #expect(await manager.reconcile(count: 2, enabled: true))

        #expect(await provider.settingsReadCount == 2)
        #expect(await provider.appliedCounts == [2])
    }

    @Test("A notification payload keeps the global count when direct badge application fails")
    @MainActor
    func notificationPayloadSurvivesBadgeApplicationFailure() async {
        let provider = TestAppIconBadgeProvider(state: .authorized, failsToApply: true)
        let manager = AppIconBadgeManager(provider: provider)

        #expect(await manager.reconcile(count: 7, enabled: true))
        let content = NotificationManager.notificationContent(
            for: [(video: video("notification", publishedAt: 1_500), channelName: "Channel")],
            appIconBadgeCount: 7
        )

        #expect(await provider.appliedCounts == [7])
        #expect(content.badge?.intValue == 7)
    }

    @Test("App icon restoration waits for the active BADGE-01 scope hydration")
    func appIconBadgeHydrationAndScopePolicy() {
        let serverScope = "local-feed:yattee-server:server"
        let invidiousScope = "local-feed:invidious:invidious"

        #expect(!AppIconBadgeProjectionPolicy.canApply(
            activeScopeRawValue: serverScope,
            hydratedScopeRawValue: nil,
            isHydrated: false
        ))
        #expect(AppIconBadgeProjectionPolicy.canApply(
            activeScopeRawValue: serverScope,
            hydratedScopeRawValue: serverScope,
            isHydrated: true
        ))
        #expect(!AppIconBadgeProjectionPolicy.canApply(
            activeScopeRawValue: invidiousScope,
            hydratedScopeRawValue: serverScope,
            isHydrated: true
        ))
    }

    @Test("App icon projection applies Shorts and channel preferences without mutation")
    func appIconBadgeProjectionPreferences() {
        let regular = FeedNoveltyEntry(
            videoID: "regular",
            channelID: "included",
            publishedAt: baselineDate,
            discoveredAt: refreshDate,
            contentKind: .regular
        )
        let short = FeedNoveltyEntry(
            videoID: "short",
            channelID: "included",
            publishedAt: baselineDate,
            discoveredAt: refreshDate,
            contentKind: .short
        )
        let excluded = FeedNoveltyEntry(
            videoID: "excluded",
            channelID: "excluded",
            publishedAt: baselineDate,
            discoveredAt: refreshDate,
            contentKind: .regular
        )
        let entries = [regular, short, excluded]

        #expect(AppIconBadgeProjectionPolicy.count(
            entries: entries,
            excluding: ["excluded"],
            includeShorts: false
        ) == 1)
        #expect(AppIconBadgeProjectionPolicy.count(
            entries: entries,
            excluding: ["excluded"],
            includeShorts: true
        ) == 2)
        #expect(entries.count == 3)
    }

    @Test("Authorized system status still requires the badge setting")
    func appIconBadgeSystemStateResolution() {
        #expect(SystemAppIconBadgeProvider.authorizationState(
            status: .authorized,
            badgeSetting: .enabled
        ) == .authorized)
        #expect(SystemAppIconBadgeProvider.authorizationState(
            status: .authorized,
            badgeSetting: .disabled
        ) == .denied)
        #expect(SystemAppIconBadgeProvider.authorizationState(
            status: .notDetermined,
            badgeSetting: .notSupported
        ) == .notDetermined)
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

    @Test("Defaults affect only new unconfigured badge subscriptions")
    @MainActor
    func newSubscriptionBadgeDefaultsPreserveExistingChoices() {
        let suiteName = "ChannelBadgePreferencesDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = FeedNoveltyScope(rawValue: "local-feed:invidious:instance")
        let preferences = ChannelBadgePreferences(defaults: defaults, storageKey: "excluded")

        preferences.setIncluded(true, channelID: "existing-included", in: scope)
        preferences.setIncluded(false, channelID: "existing-excluded", in: scope)
        preferences.applyDefault(
            includeByDefault: false,
            channelIDs: ["existing-included", "existing-excluded", "new-excluded"],
            in: scope
        )

        #expect(preferences.isIncluded(channelID: "existing-included", in: scope))
        #expect(!preferences.isIncluded(channelID: "existing-excluded", in: scope))
        #expect(!preferences.isIncluded(channelID: "new-excluded", in: scope))

        preferences.applyDefault(
            includeByDefault: true,
            channelIDs: ["new-included"],
            in: scope
        )
        #expect(preferences.isIncluded(channelID: "new-included", in: scope))

        preferences.setIncluded(true, channelID: "new-excluded", in: scope)
        preferences.applyDefault(
            includeByDefault: false,
            channelIDs: ["new-excluded"],
            in: scope
        )
        #expect(preferences.isIncluded(channelID: "new-excluded", in: scope))
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
            let provider = TestAppIconBadgeProvider(state: .authorized)
            let iconManager = AppIconBadgeManager(provider: provider)
            #expect(await iconManager.enable(count: filteredCount))
            #expect(await provider.appliedCounts == [1])
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

    @Test("Shorts preference filters non-destructively OFF to ON to OFF")
    func shortsPolicyAndPreferenceChanges() async {
        await withRegistry { registry, scope, defaults in
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
            var snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 3)
            #expect(FeedNoveltyBadgeFilter.count(
                entries: snapshot.unconsulted,
                excluding: [],
                includeShorts: false
            ) == 2)
            #expect(FeedNoveltyBadgeFilter.count(
                entries: snapshot.unconsulted,
                excluding: [],
                includeShorts: true
            ) == 3)

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
            snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 4)
            #expect(FeedNoveltyBadgeFilter.count(
                entries: snapshot.unconsulted,
                excluding: [],
                includeShorts: true
            ) == 4)

            await registry.ingest(
                videos: [],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: false,
                includeShorts: false
            )
            snapshot = await registry.snapshot(for: scope)
            #expect(snapshot.count == 4)
            #expect(FeedNoveltyBadgeFilter.count(
                entries: snapshot.unconsulted,
                excluding: [],
                includeShorts: false
            ) == 2)

            let restored = FeedNoveltyRegistry(defaults: defaults, storageKey: storageKey)
            let restoredSnapshot = await restored.snapshot(for: scope)
            #expect(restoredSnapshot.count == 4)
            #expect(restoredSnapshot.unconsulted.filter { $0.contentKind == .short }.count == 2)

            let otherScope = FeedNoveltyScope(rawValue: "other-scope")
            await establishBaseline(restored, scope: otherScope)
            #expect(await restored.snapshot(for: otherScope).count == 0)
        }
    }

    @Test("Shorts and channel exclusions share one non-destructive badge filter")
    func shortsAndChannelBadgeFiltering() {
        let entries = [
            FeedNoveltyEntry(
                videoID: "regular",
                channelID: "included",
                publishedAt: baselineDate,
                discoveredAt: refreshDate,
                contentKind: .regular
            ),
            FeedNoveltyEntry(
                videoID: "short",
                channelID: "included",
                publishedAt: baselineDate,
                discoveredAt: refreshDate,
                contentKind: .short
            ),
            FeedNoveltyEntry(
                videoID: "excluded",
                channelID: "excluded",
                publishedAt: baselineDate,
                discoveredAt: refreshDate,
                contentKind: .regular
            ),
        ]

        #expect(FeedNoveltyBadgeFilter.count(
            entries: entries,
            excluding: ["excluded"],
            includeShorts: false
        ) == 1)
        #expect(FeedNoveltyBadgeFilter.count(
            entries: entries,
            excluding: ["excluded"],
            includeShorts: true
        ) == 2)
        #expect(entries.count == 3)
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

    @Test("Consultation requires a genuinely visible active Feed")
    func consultationPolicy() {
        let visibleIDs: Set<String> = ["global:youtube:visible"]
        #expect(FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            isPlayerObscuringFeed: false,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: false,
            isSceneActive: true,
            isPlayerObscuringFeed: false,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: false,
            isPlayerObscuringFeed: false,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            isPlayerObscuringFeed: true,
            visibleVideoIDs: visibleIDs
        ))
        #expect(FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            isPlayerObscuringFeed: false,
            visibleVideoIDs: visibleIDs
        ))
        #expect(!FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: true,
            isSceneActive: true,
            isPlayerObscuringFeed: false,
            visibleVideoIDs: []
        ))
    }

    @Test("Expanded player preserves novelties until the Feed is exposed again")
    func playerVisibilityConsultationTransition() async {
        await withRegistry { registry, scope, _ in
            await establishBaseline(registry, scope: scope)
            await registry.ingest(
                videos: [video("visible", publishedAt: 1_500)],
                scope: scope,
                observedAt: refreshDate,
                isCompleteSnapshot: true,
                includeShorts: false
            )
            let visibleIDs: Set<String> = ["global:youtube:visible"]

            let whileExpanded = FeedNoveltyConsultationPolicy.shouldConsult(
                isTabActive: true,
                isSceneActive: true,
                isPlayerObscuringFeed: true,
                visibleVideoIDs: visibleIDs
            )
            if whileExpanded {
                await registry.markConsulted(videoIDs: visibleIDs, in: scope)
            }
            #expect(await registry.snapshot(for: scope).count == 1)

            let afterClosing = FeedNoveltyConsultationPolicy.shouldConsult(
                isTabActive: true,
                isSceneActive: true,
                isPlayerObscuringFeed: false,
                visibleVideoIDs: visibleIDs
            )
            if afterClosing {
                await registry.markConsulted(videoIDs: visibleIDs, in: scope)
            }
            #expect(await registry.snapshot(for: scope).count == 0)
        }
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
private actor TestAppIconBadgeProvider: AppIconBadgeProviding {
    private var state: AppIconBadgeAuthorizationState
    private let requestResult: Bool
    private let stateAfterRequest: AppIconBadgeAuthorizationState?
    private let failsToApply: Bool
    private(set) var requestCount = 0
    private(set) var settingsReadCount = 0
    private(set) var appliedCounts: [Int] = []

    init(
        state: AppIconBadgeAuthorizationState,
        requestResult: Bool = false,
        stateAfterRequest: AppIconBadgeAuthorizationState? = nil,
        failsToApply: Bool = false
    ) {
        self.state = state
        self.requestResult = requestResult
        self.stateAfterRequest = stateAfterRequest
        self.failsToApply = failsToApply
    }

    func authorizationState() async -> AppIconBadgeAuthorizationState {
        settingsReadCount += 1
        return state
    }

    func requestBadgeAuthorization() async throws -> Bool {
        requestCount += 1
        state = stateAfterRequest ?? (requestResult ? .authorized : .denied)
        return requestResult
    }

    func setBadgeCount(_ count: Int) async throws {
        appliedCounts.append(count)
        if failsToApply {
            throw TestAppIconBadgeProviderError.applicationFailed
        }
    }

    func setState(_ state: AppIconBadgeAuthorizationState) {
        self.state = state
    }
}

private enum TestAppIconBadgeProviderError: Error {
    case applicationFailed
}
#endif
