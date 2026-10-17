//
//  CompactTabView.swift
//  Yattee
//
//  Custom tab bar for compact size class (iPhone, iPad Stage Manager small window).
//  Uses settings-based tab customization since Apple's TabViewCustomization only works in sidebar mode.
//

import SwiftUI

#if os(iOS)
struct CompactTabView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    /// Whether this hierarchy owns the mini player through the native tab accessory.
    var usesMiniPlayerAccessory = true

    /// iOS 27 PoC: display the active video as a native prominent tab for Bubble style.
    var usesProminentBubbleTab = false

    // Navigation paths for fixed tabs
    @State private var homePath = NavigationPath()
    @State private var morePath = NavigationPath()

    // Navigation paths for dynamic tabs
    @State private var subscriptionsPath = NavigationPath()
    @State private var channelsPath = NavigationPath()
    @State private var bookmarksPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var continueWatchingPath = NavigationPath()

    // Tab selection - using String to support both fixed and dynamic tabs
    // Initial value is a placeholder; actual startup tab is applied in onAppear
    @State private var selectedTab: String = "home"
    @State private var lastContentTab: String = "home"
    @State private var hasAppliedStartupTab = false
    @State private var noveltyBadgeState = FeedNoveltyBadgeState.shared
    @State private var channelBadgePreferences = ChannelBadgePreferences.shared
    #if DEBUG
    @State private var noveltyBadgeDiagnostic = FeedNoveltyBadgeDiagnosticState.shared
    #endif

    // Zoom transition namespace (local to this tab view)
    @Namespace private var zoomTransition

    private var settingsManager: SettingsManager? {
        appEnvironment?.settingsManager
    }

    private var navigationCoordinator: NavigationCoordinator? {
        appEnvironment?.navigationCoordinator
    }

    /// Returns the visible custom tabs from settings
    private var visibleTabItems: [TabBarItem] {
        settingsManager?.visibleTabBarItems() ?? []
    }

    /// Whether to show the mini player accessory (iOS 26.1+)
    private var shouldShowAccessory: Bool {
        guard let state = appEnvironment?.playerService.state else { return false }
        return state.currentVideo != nil && !state.isClosingVideo
    }

    private var zoomTransitionsEnabled: Bool {
        appEnvironment?.settingsManager.zoomTransitionsEnabled ?? true
    }

    private var localizationLocale: Locale {
        appEnvironment?.settingsManager.appLanguage.locale ?? AppLanguage.english.locale
    }

    private var activeNoveltyScope: FeedNoveltyScope? {
        FeedNoveltyScope.active(in: appEnvironment)
    }

    private var subscriptionBadgeCount: Int {
        #if DEBUG
        if noveltyBadgeDiagnostic.scope == activeNoveltyScope {
            return FeedNoveltyBadgePresentation.count(
                registryCount: noveltyBadgeDiagnostic.remainingCount,
                isEnabled: settingsManager?.videoTabBadgeEnabled == true
            )
        }
        #endif
        return FeedNoveltyBadgePresentation.count(
            registryCount: realNoveltyCount,
            isEnabled: settingsManager?.videoTabBadgeEnabled == true
        )
    }

    private var realNoveltyCount: Int {
        noveltyBadgeState.count(
            for: activeNoveltyScope,
            excluding: channelBadgePreferences.excludedChannelIDs(in: activeNoveltyScope),
            includeShorts: settingsManager?.badgesIncludeShorts == true
        )
    }

    private static let prominentMiniPlayerTabValue = "prominentMiniPlayer"
    private static let moreTabValue = "more"

    private var prominentMiniPlayerIcon: String {
        appEnvironment?.playerService.state.playbackState == .playing
            ? "pause.fill"
            : "play.fill"
    }

    private var shouldIncludeProminentBubbleTab: Bool {
        if #available(iOS 27.0, *) {
            return usesProminentBubbleTab
                && appEnvironment?.playerService.state.currentVideo != nil
                && appEnvironment?.playerService.state.isClosingVideo == false
        }
        return false
    }

    /// A prominent tab is still a real tab destination. Keep its selection transient,
    /// then restore the previous content tab before the expanded player disappears.
    private var tabSelection: Binding<String> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == Self.prominentMiniPlayerTabValue {
                    guard selectedTab != Self.prominentMiniPlayerTabValue else { return }
                    lastContentTab = selectedTab
                    navigationCoordinator?.expandPlayer()
                    selectedTab = newValue
                } else {
                    selectedTab = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            // Fixed: Home (first)
            Tab(value: "home") {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .withNavigationDestinations()
                }
            } label: {
                Label("tabs.home", systemImage: "house.fill")
            }
            .accessibilityIdentifier("tab.home")

            // Dynamic tabs from settings (in the middle, SwiftUI auto-collapses overflow into More)
            ForEach(visibleTabItems) { item in
                Tab(value: item.rawValue) {
                    tabContent(for: item)
                } label: {
                    Label(item.localizedTitle, systemImage: item.icon)
                }
                .badge(item == .subscriptions ? subscriptionBadgeCount : 0)
            }

            if #available(iOS 27.0, *), shouldIncludeProminentBubbleTab {
                Tab(value: Self.prominentMiniPlayerTabValue, role: .prominent) {
                    EmptyView()
                } label: {
                    Label("player.prominentTab", systemImage: prominentMiniPlayerIcon)
                        .tint(settingsManager?.resolvedAccentColor ?? .accentColor)
                }
            }

        }
        .environment(\.locale, localizationLocale)
        .zoomTransitionNamespace(zoomTransition)
        .zoomTransitionsEnabled(zoomTransitionsEnabled)
        .iOS26TabFeatures(
            shouldShowAccessory: shouldShowAccessory,
            allowsMiniPlayerAccessory: usesMiniPlayerAccessory,
            settingsManager: settingsManager
        )
        .onChange(of: navigationCoordinator?.pendingNavigation) { _, newValue in
            handlePendingNavigation(newValue)
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab != Self.prominentMiniPlayerTabValue {
                lastContentTab = newTab
            }
            updateHandoffForTab(newTab)
            syncTabToCoordinator(newTab)
        }
        .onChange(of: visibleTabItems) { _, visibleItems in
            guard selectedTab == Self.moreTabValue, !visibleItems.contains(.more) else { return }
            selectedTab = "home"
        }
        .onChange(of: navigationCoordinator?.isPlayerExpanded) { _, isExpanded in
            if isExpanded == false {
                restoreContentTabIfNeeded()
            }
        }
        .onChange(of: navigationCoordinator?.isPlayerWindowVisible) { _, isVisible in
            if isVisible == true {
                restoreContentTabIfNeeded()
            }
        }
        .onChange(of: shouldIncludeProminentBubbleTab) { _, isIncluded in
            if !isIncluded {
                restoreContentTabIfNeeded()
            }
        }
        .onChange(of: navigationCoordinator?.selectedTab) { _, newTab in
            syncTabFromCoordinator(newTab)
        }
        .onAppear {
            applyStartupTabIfNeeded()
            #if DEBUG
            logProminentTabState(reason: "appear")
            #endif
        }
        #if DEBUG
        .onChange(of: usesProminentBubbleTab) { _, _ in
            logProminentTabState(reason: "presentationChanged")
        }
        .onChange(of: appEnvironment?.playerService.state.currentVideo?.id) { _, _ in
            logProminentTabState(reason: "videoChanged")
        }
        #endif
        .task(id: activeNoveltyScope?.rawValue) {
            guard let activeNoveltyScope else { return }
            await FeedNoveltyRegistry.shared.synchronizeBadgeState(for: activeNoveltyScope)
        }
    }

    // MARK: - Startup Tab

    private func restoreContentTabIfNeeded() {
        guard selectedTab == Self.prominentMiniPlayerTabValue else { return }
        selectedTab = lastContentTab
    }

    /// Applies the configured startup tab on first appearance.
    private func applyStartupTabIfNeeded() {
        guard !hasAppliedStartupTab else { return }
        hasAppliedStartupTab = true

        let startupTab = settingsManager?.effectiveStartupTabForTabBar() ?? .home
        if startupTab == .search {
            selectedTab = "home"
            homePath.append(NavigationDestination.search(""))
        } else {
            selectedTab = startupTab.compactTabValue
        }
    }

    // MARK: - Handoff

    /// Updates Handoff activity based on the selected tab.
    private func updateHandoffForTab(_ tab: String) {
        let destination: NavigationDestination?

        switch tab {
        case "home":
            // Home tab - use playlists as default (matches HomeView's primary content)
            destination = .playlists
        case Self.moreTabValue:
            destination = .playlists
        case TabBarItem.subscriptions.rawValue:
            destination = .subscriptionsFeed
        case TabBarItem.channels.rawValue:
            destination = .manageChannels
        case TabBarItem.bookmarks.rawValue:
            destination = .bookmarks
        case TabBarItem.playlists.rawValue:
            destination = .playlists
        case TabBarItem.history.rawValue:
            destination = .history
        case TabBarItem.downloads.rawValue:
            destination = .downloads
        case TabBarItem.sources.rawValue:
            destination = nil  // No handoff for sources
        case TabBarItem.settings.rawValue:
            destination = nil  // No handoff for settings
        default:
            destination = nil
        }

        if let destination {
            appEnvironment?.handoffManager.updateActivity(for: destination)
        }
    }

    // MARK: - Tab Sync with NavigationCoordinator

    /// Syncs NavigationCoordinator's selectedTab to local state (coordinator → local).
    /// Called when NavigationCoordinator.selectedTab changes (e.g., from notification tap).
    private func syncTabFromCoordinator(_ appTab: AppTab?) {
        guard let appTab else { return }

        switch appTab {
        case .home:
            if selectedTab != "home" {
                selectedTab = "home"
            }
        case .subscriptions:
            if visibleTabItems.contains(.subscriptions) {
                // Subscriptions tab is visible - switch to it
                let tabValue = TabBarItem.subscriptions.rawValue
                if selectedTab != tabValue {
                    selectedTab = tabValue
                }
            } else {
                // Subscriptions tab not visible - push subscriptions view onto current stack
                pushSubscriptionsOnCurrentStack()
            }
        case .search:
            pushSearchOnCurrentStack()
        #if os(tvOS)
        case .settings:
            break
        #endif
        }
    }

    /// Syncs local selectedTab to NavigationCoordinator (local → coordinator).
    /// Called when user manually switches tabs.
    private func syncTabToCoordinator(_ tab: String) {
        guard let coordinator = navigationCoordinator else { return }

        let appTab: AppTab
        switch tab {
        case "home":
            appTab = .home
        case TabBarItem.subscriptions.rawValue:
            appTab = .subscriptions
        default:
            // Other tabs (channels, bookmarks, downloads, etc.) don't have AppTab equivalents
            // Don't update coordinator - just return to avoid feedback loop
            return
        }

        if coordinator.selectedTab != appTab {
            coordinator.selectedTab = appTab
        }
    }

    /// Pushes the subscriptions feed onto the current tab's navigation stack.
    /// Used when subscriptions tab is not visible but we need to navigate to subscriptions.
    private func pushSubscriptionsOnCurrentStack() {
        let destination = NavigationDestination.subscriptionsFeed
        switch selectedTab {
        case "home":
            homePath.append(destination)
        case Self.moreTabValue:
            morePath.append(destination)
        case TabBarItem.channels.rawValue:
            channelsPath.append(destination)
        case TabBarItem.bookmarks.rawValue:
            bookmarksPath.append(destination)
        case TabBarItem.playlists.rawValue:
            playlistsPath.append(destination)
        case TabBarItem.history.rawValue:
            historyPath.append(destination)
        case TabBarItem.downloads.rawValue:
            downloadsPath.append(destination)
        case TabBarItem.sources.rawValue:
            sourcesPath.append(destination)
        case TabBarItem.settings.rawValue:
            settingsPath.append(destination)
        case TabBarItem.continueWatching.rawValue:
            continueWatchingPath.append(destination)
        default:
            homePath.append(destination)
        }
    }

    /// Pushes Search onto the selected tab while preserving its navigation state.
    private func pushSearchOnCurrentStack() {
        let destination = NavigationDestination.search("")
        switch selectedTab {
        case "home":
            homePath.append(destination)
        case Self.moreTabValue:
            morePath.append(destination)
        case TabBarItem.subscriptions.rawValue:
            subscriptionsPath.append(destination)
        case TabBarItem.channels.rawValue:
            channelsPath.append(destination)
        case TabBarItem.bookmarks.rawValue:
            bookmarksPath.append(destination)
        case TabBarItem.playlists.rawValue:
            playlistsPath.append(destination)
        case TabBarItem.history.rawValue:
            historyPath.append(destination)
        case TabBarItem.downloads.rawValue:
            downloadsPath.append(destination)
        case TabBarItem.sources.rawValue:
            sourcesPath.append(destination)
        case TabBarItem.settings.rawValue:
            settingsPath.append(destination)
        case TabBarItem.continueWatching.rawValue:
            continueWatchingPath.append(destination)
        default:
            homePath.append(destination)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for item: TabBarItem) -> some View {
        switch item {
        case .subscriptions:
            NavigationStack(path: $subscriptionsPath) {
                SubscriptionsView(
                    isTabActive: selectedTab == TabBarItem.subscriptions.rawValue
                )
                    .withNavigationDestinations()
            }
        case .channels:
            NavigationStack(path: $channelsPath) {
                ManageChannelsView()
                    .withNavigationDestinations()
            }
        case .more:
            NavigationStack(path: $morePath) {
                HomeView(customizationContext: .more)
                    .withNavigationDestinations()
            }
        case .bookmarks:
            NavigationStack(path: $bookmarksPath) {
                BookmarksListView()
                    .withNavigationDestinations()
            }
        case .playlists:
            NavigationStack(path: $playlistsPath) {
                PlaylistsListView()
                    .withNavigationDestinations()
            }
        case .history:
            NavigationStack(path: $historyPath) {
                HistoryListView()
                    .withNavigationDestinations()
            }
        case .downloads:
            NavigationStack(path: $downloadsPath) {
                DownloadsView()
                    .withNavigationDestinations()
            }
        case .sources:
            NavigationStack(path: $sourcesPath) {
                MediaSourcesView()
                    .withNavigationDestinations()
            }
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsView(showCloseButton: false)
                    .withNavigationDestinations()
            }
        case .continueWatching:
            NavigationStack(path: $continueWatchingPath) {
                ContinueWatchingView()
                    .withNavigationDestinations()
            }
        }
    }

    // MARK: - Navigation Handling

    private func handlePendingNavigation(_ destination: NavigationDestination?) {
        guard let destination else { return }

        // Append to the current tab's path
        switch selectedTab {
        case "home":
            homePath.append(destination)
        case Self.moreTabValue:
            morePath.append(destination)
        case TabBarItem.subscriptions.rawValue:
            subscriptionsPath.append(destination)
        case TabBarItem.channels.rawValue:
            channelsPath.append(destination)
        case TabBarItem.bookmarks.rawValue:
            bookmarksPath.append(destination)
        case TabBarItem.playlists.rawValue:
            playlistsPath.append(destination)
        case TabBarItem.history.rawValue:
            historyPath.append(destination)
        case TabBarItem.downloads.rawValue:
            downloadsPath.append(destination)
        case TabBarItem.sources.rawValue:
            sourcesPath.append(destination)
        case TabBarItem.settings.rawValue:
            settingsPath.append(destination)
        case TabBarItem.continueWatching.rawValue:
            continueWatchingPath.append(destination)
        default:
            // Fallback to home
            homePath.append(destination)
        }

        navigationCoordinator?.clearPendingNavigation()
    }

    #if DEBUG
    private func logProminentTabState(reason: String) {
        let state = appEnvironment?.playerService.state
        LoggingService.shared.debug(
            "[ProminentTabPoC] CompactTabView reason=\(reason) " +
                "prominent=\(usesProminentBubbleTab) accessory=\(usesMiniPlayerAccessory) " +
                "hasVideo=\(state?.currentVideo != nil) closing=\(state?.isClosingVideo ?? false)",
            category: .general
        )
    }
    #endif
}

// MARK: - Preview

#Preview {
    CompactTabView()
        .appEnvironment(.preview)
}
#endif
