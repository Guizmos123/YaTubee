//
//  AppIconBadgeSynchronization.swift
//  Yattee
//
//  Owns app-level synchronization between Feed novelty state and the iOS icon badge.
//

#if os(iOS)
import SwiftUI

struct AppIconBadgeProjectionKey: Hashable {
    let activeScopeRawValue: String?
    let hydratedScopeRawValue: String?
    let isHydrated: Bool
    let count: Int
    let isEnabled: Bool
    let includeShorts: Bool
    let isSceneActive: Bool
}

enum AppIconBadgeProjectionPolicy {
    static func canApply(
        activeScopeRawValue: String?,
        hydratedScopeRawValue: String?,
        isHydrated: Bool
    ) -> Bool {
        isHydrated && hydratedScopeRawValue == activeScopeRawValue
    }

    static func count(
        entries: [FeedNoveltyEntry],
        excluding channelIDs: Set<String>,
        includeShorts: Bool
    ) -> Int {
        FeedNoveltyBadgeFilter.count(
            entries: entries,
            excluding: channelIDs,
            includeShorts: includeShorts
        )
    }
}

private struct AppIconBadgeSnapshotKey: Hashable {
    let activeScopeRawValue: String?
    let publishedCount: Int
    let excludedChannelIDs: Set<String>
    let includeShorts: Bool
}

private struct AppIconBadgeSynchronizationModifier: ViewModifier {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var badgeState = FeedNoveltyBadgeState.shared
    @State private var channelPreferences = ChannelBadgePreferences.shared
    @State private var hydratedScopeRawValue: String?
    @State private var isHydrated = false
    @State private var entries: [FeedNoveltyEntry] = []

    private var activeScope: FeedNoveltyScope? {
        FeedNoveltyScope.active(in: appEnvironment)
    }

    private var count: Int {
        AppIconBadgeProjectionPolicy.count(
            entries: entries,
            excluding: channelPreferences.excludedChannelIDs(in: activeScope),
            includeShorts: appEnvironment?.settingsManager.badgesIncludeShorts == true
        )
    }

    private var snapshotKey: AppIconBadgeSnapshotKey {
        AppIconBadgeSnapshotKey(
            activeScopeRawValue: activeScope?.rawValue,
            publishedCount: badgeState.count(for: activeScope),
            excludedChannelIDs: channelPreferences.excludedChannelIDs(in: activeScope),
            includeShorts: appEnvironment?.settingsManager.badgesIncludeShorts == true
        )
    }

    private var projectionKey: AppIconBadgeProjectionKey {
        AppIconBadgeProjectionKey(
            activeScopeRawValue: activeScope?.rawValue,
            hydratedScopeRawValue: hydratedScopeRawValue,
            isHydrated: isHydrated,
            count: count,
            isEnabled: appEnvironment?.settingsManager.appIconBadgeEnabled == true,
            includeShorts: appEnvironment?.settingsManager.badgesIncludeShorts == true,
            isSceneActive: scenePhase == .active
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: snapshotKey) {
                isHydrated = false
                hydratedScopeRawValue = nil
                entries = []

                if let activeScope {
                    await FeedNoveltyRegistry.shared.synchronizeBadgeState(for: activeScope)
                    guard activeScope == self.activeScope else { return }
                    entries = await FeedNoveltyRegistry.shared.snapshot(for: activeScope).unconsulted
                    hydratedScopeRawValue = activeScope.rawValue
                }

                isHydrated = true
            }
            .task(id: projectionKey) {
                guard let appEnvironment,
                      AppIconBadgeProjectionPolicy.canApply(
                          activeScopeRawValue: activeScope?.rawValue,
                          hydratedScopeRawValue: hydratedScopeRawValue,
                          isHydrated: isHydrated
                      ) else { return }

                let enabled = appEnvironment.settingsManager.appIconBadgeEnabled
                appEnvironment.backgroundRefreshManager.handleAppIconBadgeEnabledChanged(enabled)
                if scenePhase == .active {
                    _ = await AppIconBadgeManager.shared.reconcile(
                        count: count,
                        enabled: enabled
                    )
                } else {
                    await AppIconBadgeManager.shared.apply(count: count, enabled: enabled)
                }
            }
    }
}

extension View {
    func synchronizeAppIconBadge() -> some View {
        modifier(AppIconBadgeSynchronizationModifier())
    }
}
#endif
