//
//  SubscriptionsView.swift
//  Yattee
//
//  Subscriptions tab with channel filter strip and feed.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SubscriptionsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var sheetTransition
    #if os(tvOS)
    @FocusState private var focusedVideoID: String?
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var feedCache = SubscriptionFeedCache.shared
    @State private var subscriptions: [Subscription] = []
    @State private var subscriptionsLoaded = false
    @State private var selectedChannelID: String? = nil
    @State private var errorMessage: String?
    @State private var watchEntriesMap: [String: WatchEntry] = [:]
    @State private var showViewOptions = false
    @State private var noveltyBadgeState = FeedNoveltyBadgeState.shared
    #if DEBUG
    @State private var noveltyBadgeDiagnostic = FeedNoveltyBadgeDiagnosticState.shared
    #endif
    @State private var visibleVideoIDs: Set<String> = []
    @State private var pendingConsultedVideoIDs: Set<String> = []
    @State private var feedSyncCapsuleState: FeedSyncCapsuleState?
    @State private var feedSyncCapsuleDismissTask: Task<Void, Never>?
    @State private var hasObservedFeedSynchronization = false
    let isTabActive: Bool
    #if os(macOS)
    @State private var showSubscriptionsData = false
    @State private var pendingSubscriptionsData = false
    #endif

    init(isTabActive: Bool = false) {
        self.isTabActive = isTabActive
    }

    // View options (persisted)
    @AppStorage("subscriptionsLayout") private var layout: VideoListLayout = .list
    @AppStorage("subscriptionsRowStyle") private var rowStyle: VideoRowStyle = .regular
    @AppStorage("subscriptionsGridColumns") private var gridColumns = 2
    @AppStorage("subscriptionsHideWatched") private var hideWatched = false
    @AppStorage("subscriptionsChannelStripSize") private var channelStripSize: ChannelStripSize = .normal
    @AppStorage("subscriptionsShowSidebar") private var showSidebar = true
    /// Whether the last completed load produced enough channels for the sidebar,
    /// so its space can be reserved before the next load finishes.
    @AppStorage("subscriptionsSidebarExpected") private var sidebarExpected = false
    #if os(macOS)
    @AppStorage("subscriptionsMacOSSidebarWidth") private var macOSSidebarWidth = 240.0
    @State private var macOSSidebarDragStartWidth: Double?
    #elseif os(iOS)
    @AppStorage("subscriptionsIPadSidebarWidth") private var iPadSidebarWidth = 260.0
    @State private var iPadSidebarDragStartWidth: Double?
    #endif

    /// List style from centralized settings.
    private var listStyle: VideoListStyle {
        appEnvironment?.settingsManager.listStyle ?? .inset
    }

    private var localizationLocale: Locale {
        appEnvironment?.settingsManager.appLanguage.locale ?? AppLanguage.english.locale
    }

    private var activeNoveltyScope: FeedNoveltyScope? {
        FeedNoveltyScope.active(in: appEnvironment)
    }

    private var activeNoveltyCount: Int {
        #if DEBUG
        if noveltyBadgeDiagnostic.scope == activeNoveltyScope {
            return noveltyBadgeDiagnostic.remainingCount
        }
        #endif
        return noveltyBadgeState.count(for: activeNoveltyScope)
    }

    // Grid layout configuration
    @State private var viewWidth: CGFloat = 0
    private var gridConfig: GridLayoutConfiguration {
        GridLayoutConfiguration(viewWidth: viewWidth, gridColumns: gridColumns)
    }

    private var viewOptionsForm: some View {
        Form {
            Section {
                #if os(macOS)
                Toggle("viewOptions.showSidebar", isOn: $showSidebar)
                #elseif os(iOS)
                if isIPadRegular {
                    Toggle("viewOptions.showSidebar", isOn: $showSidebar)
                }
                #elseif os(tvOS)
                PlatformMenuPicker(AppLocalization.string("viewOptions.showSidebar"), selection: $showSidebar) {
                    Text("common.on").tag(true)
                    Text("common.off").tag(false)
                }
                #endif

                // Layout picker (inline menu)
                PlatformMenuPicker(AppLocalization.string("viewOptions.layout"), selection: $layout) {
                    ForEach(VideoListLayout.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                // List-specific options
                if layout == .list {
                    PlatformMenuPicker(AppLocalization.string("viewOptions.rowSize"), selection: $rowStyle) {
                        Text("viewOptions.rowSize.compact").tag(VideoRowStyle.compact)
                        Text("viewOptions.rowSize.regular").tag(VideoRowStyle.regular)
                        Text("viewOptions.rowSize.large").tag(VideoRowStyle.large)
                    }
                }

                // Grid-specific options
                if layout == .grid {
                    #if os(tvOS)
                    Picker("viewOptions.columns.header", selection: $gridColumns) {
                        ForEach(GridConstants.minAllowedColumns...max(GridConstants.minAllowedColumns, gridConfig.maxColumns), id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    #else
                    Stepper(
                        "viewOptions.columns \(min(max(GridConstants.minAllowedColumns, gridColumns), gridConfig.maxColumns))",
                        value: $gridColumns,
                        in: GridConstants.minAllowedColumns...max(GridConstants.minAllowedColumns, gridConfig.maxColumns)
                    )
                    #endif
                }

                #if os(tvOS)
                PlatformMenuPicker(AppLocalization.string("viewOptions.hideWatched"), selection: $hideWatched) {
                    Text("common.on").tag(true)
                    Text("common.off").tag(false)
                }
                #else
                Toggle("viewOptions.hideWatched", isOn: $hideWatched)
                #endif

                #if os(iOS)
                Picker("viewOptions.channelStrip", selection: $channelStripSize) {
                    ForEach(ChannelStripSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .disabled(isIPadRegular && showSidebar)
                #endif
            }

            #if os(macOS)
            Section {
                Button {
                    pendingSubscriptionsData = true
                    showViewOptions = false
                } label: {
                    Label(AppLocalization.string("manageChannels.subscriptionsData"), systemImage: "person.2.badge.gearshape")
                }
            }
            #elseif os(iOS)
            Section {
                NavigationLink {
                    SubscriptionsSettingsView()
                } label: {
                    Label(AppLocalization.string("manageChannels.subscriptionsData"), systemImage: "person.2.badge.gearshape")
                }
            }
            #endif
        }
    }

    #if os(macOS)
    private var subscriptionsDataSheet: some View {
        NavigationStack {
            SubscriptionsSettingsView()
                .toolbar {
                    sheetCloseToolbarItem { showSubscriptionsData = false }
                }
        }
        .frame(minWidth: 500, minHeight: 450)
    }
    #endif

    private var isShowingFullScreenError: Bool {
        if case .error = feedCache.feedLoadState, feedCache.videos.isEmpty {
            return true
        }
        return false
    }

    private var dataManager: DataManager? { appEnvironment?.dataManager }
    private var accentColor: Color { appEnvironment?.settingsManager.resolvedAccentColor ?? .accentColor }
    private var yatteeServer: Instance? {
        appEnvironment?.instancesManager.enabledYatteeServerInstances.first
    }
    private var yatteeServerURL: URL? { yatteeServer?.url }
    private var yatteeServerAuthHeader: String? {
        guard let server = yatteeServer else { return nil }
        return appEnvironment?.basicAuthCredentialsManager.basicAuthHeader(for: server)
    }

    /// Generates a unique ID based on instances configuration.
    private var instanceConfigurationID: String {
        guard let instances = appEnvironment?.instancesManager.instances else {
            return "none"
        }
        return instances
            .filter { $0.type == .yatteeServer }
            .map { "\($0.id):\($0.isEnabled):\($0.apiKey?.isEmpty == false)" }
            .joined(separator: "|")
    }

    /// Videos filtered by selected channel and watch status.
    private var filteredVideos: [Video] {
        var videos = feedCache.videos

        if let channelID = selectedChannelID {
            videos = videos.filter { $0.author.id == channelID }
        }

        if hideWatched {
            videos = videos.filter { video in
                guard let entry = watchEntriesMap[video.id.videoID] else { return true }
                return !entry.isFinished
            }
        }

        return videos
    }

    /// The currently selected subscription (if any).
    private var selectedSubscription: Subscription? {
        guard let channelID = selectedChannelID else { return nil }
        return subscriptions.first { $0.channelID == channelID }
    }

    /// Converts feed error to localized message.
    private func errorMessage(for error: FeedLoadState.FeedLoadError) -> String {
        switch error {
        case .yatteeServerRequired:
            return AppLocalization.string("subscriptions.error.yatteeServerRequired")
        case .compatibleSourceRequired:
            return AppLocalization.string("subscriptions.error.compatibleSourceRequired")
        case .notAuthenticated:
            return AppLocalization.string("subscriptions.error.notAuthenticated")
        case .networkError(let message):
            return message
        }
    }

    /// Subscriptions sorted by most recent video upload date.
    private var sortedSubscriptions: [Subscription] {
        var latestVideoDate: [String: Date] = [:]
        for video in feedCache.videos {
            let channelID = video.author.id
            let videoDate = video.publishedAt ?? .distantPast
            if let existing = latestVideoDate[channelID] {
                if videoDate > existing {
                    latestVideoDate[channelID] = videoDate
                }
            } else {
                latestVideoDate[channelID] = videoDate
            }
        }

        return subscriptions.sorted { sub1, sub2 in
            let date1 = latestVideoDate[sub1.channelID] ?? .distantPast
            let date2 = latestVideoDate[sub2.channelID] ?? .distantPast
            return date1 > date2
        }
    }

    /// Gets the watch progress (0.0-1.0) for a video, or nil if not watched/finished.
    private func watchProgress(for video: Video) -> Double? {
        guard let entry = watchEntriesMap[video.id.videoID] else { return nil }
        let progress = entry.progress
        return progress > 0 && progress < 1 ? progress : nil
    }

    /// View options button lives on the leading edge on macOS, trailing elsewhere.
    private var viewOptionsPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .primaryAction
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    #if os(tvOS)
                    HStack(alignment: .top, spacing: 24) {
                        if showSidebar && subscriptionsLoaded && subscriptions.count > 1 {
                            tvOSChannelsSidebar
                                .frame(width: max(geometry.size.width * 0.28, 360), alignment: .leading)
                                .focusSection()
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            if !showSidebar || subscriptions.count <= 1 {
                                tvOSViewOptionsButton
                            }

                            Group {
                                switch layout {
                                case .list:
                                    listContent
                                case .grid:
                                    gridContent
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .focusSection()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    #elseif os(macOS)
                    HStack(spacing: 0) {
                        if showSidebar && subscriptionsLoaded && subscriptions.count > 1 {
                            macOSChannelsSidebar
                                .frame(width: clampedMacOSSidebarWidth)

                            macOSSidebarResizeHandle
                        } else if showSidebar && !subscriptionsLoaded && sidebarExpected {
                            macOSSidebarPlaceholder
                                .frame(width: clampedMacOSSidebarWidth)

                            macOSSidebarResizeHandle
                        }

                        Group {
                            switch layout {
                            case .list:
                                listContent
                            case .grid:
                                gridContent
                            }
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    #else
                    if isIPadRegular && showSidebar && subscriptionsLoaded && subscriptions.count > 1 {
                        HStack(spacing: 0) {
                            iOSChannelsSidebar
                                .frame(width: clampedIPadSidebarWidth)

                            iPadSidebarResizeHandle

                            feedLayout
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .refreshable {
                            guard let appEnvironment else { return }
                            LoggingService.shared.info("User initiated pull-to-refresh in Subscriptions view", category: .general)
                            await loadSubscriptionsAsync()
                            await feedCache.refresh(using: appEnvironment)
                            LoggingService.shared.info("Pull-to-refresh completed", category: .general)
                        }
                    } else {
                        feedLayout
                            .refreshable {
                                guard let appEnvironment else { return }
                                LoggingService.shared.info("User initiated pull-to-refresh in Subscriptions view", category: .general)
                                await loadSubscriptionsAsync()
                                await feedCache.refresh(using: appEnvironment)
                                LoggingService.shared.info("Pull-to-refresh completed", category: .general)
                            }
                    }
                    #endif

                    // Bottom overlay for filter strip (iOS only, compact width)
                    #if os(iOS)
                    VStack {
                        Spacer()

                        if subscriptionsLoaded && subscriptions.count > 1 && channelStripSize != .disabled && !isShowingFullScreenError && !(isIPadRegular && showSidebar) {
                            bottomFloatingFilterStrip
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    VStack {
                        if let feedSyncCapsuleState {
                            feedSyncCapsule(for: feedSyncCapsuleState)
                                .transition(
                                    .move(edge: .top)
                                        .combined(with: .opacity)
                                        .combined(with: .scale(scale: 0.94, anchor: .top))
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .zIndex(2)
                    #endif
                }
                #if !os(tvOS)
                .reactiveNavigationTitle(AppLocalization.string("tabs.subscriptions"))
                #if os(iOS)
                .toolbarTitleDisplayMode(isIPadRegular ? .inline : .inlineLarge)
                #else
                .toolbarTitleDisplayMode(.inlineLarge)
                #endif
                .toolbar {
                    ToolbarItem(placement: viewOptionsPlacement) {
                        Button {
                            showViewOptions = true
                        } label: {
                            Label(AppLocalization.string("viewOptions.title"), systemImage: "slider.horizontal.3")
                        }
                        .liquidGlassTransitionSource(id: "subscriptionsViewOptions", in: sheetTransition)
                        #if os(macOS)
                        .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                            viewOptionsForm
                                .padding()
                                .frame(width: 300)
                                .onDisappear {
                                    // Present the sheet only after the popover is gone,
                                    // otherwise the presentation is swallowed.
                                    if pendingSubscriptionsData {
                                        pendingSubscriptionsData = false
                                        showSubscriptionsData = true
                                    }
                                }
                        }
                        #endif
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: NavigationDestination.search("")) {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityIdentifier("subscriptions.searchButton")
                        .accessibilityLabel(AppLocalization.string("tabs.search"))
                    }
                    #endif
                }
                #endif
                #if os(macOS)
                .sheet(isPresented: $showSubscriptionsData) {
                    subscriptionsDataSheet
                }
                #else
                .sheet(isPresented: $showViewOptions) {
                        NavigationStack {
                            viewOptionsForm
                            #if os(tvOS)
                            .scrollClipDisabled()
                            .padding(.horizontal, 40)
                            .padding(.vertical, 24)
                            #else
                            .reactiveNavigationTitle(AppLocalization.string("subscriptions.viewOptions.title"))
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                            #endif
                        }
                        .presentationDetents([.height(520), .large])
                        .presentationDragIndicator(.visible)
                        .liquidGlassSheetContent(sourceID: "subscriptionsViewOptions", in: sheetTransition)
                    }
                    #endif
                    .onAppear {
                        // Synchronous load for local accounts so the sidebar is
                        // present in the first layout pass (avoids layout jump).
                        loadSubscriptions()
                    }
                    .task {
                        await loadSubscriptionsAsync()
                        loadWatchEntries()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .subscriptionsDidChange)) { _ in
                        Task {
                            await loadSubscriptionsAsync()
                        }
                        // Subscription changes now trigger a full refresh via invalidation
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .watchHistoryDidChange)) { _ in
                        loadWatchEntries()
                    }
                    .onChange(of: appEnvironment?.settingsManager.subscriptionAccount) { _, _ in
                        #if DEBUG
                        noveltyBadgeDiagnostic.finish()
                        #endif
                        visibleVideoIDs.removeAll()
                        pendingConsultedVideoIDs.removeAll()
                        // The main feed always uses local subscriptions. A remote
                        // account change must not replace its list or cache.
                        loadSubscriptions()
                    }
                    .onChange(of: isTabActive) { _, isActive in
                        consultVisibleNoveltiesIfEligible()
                        #if os(iOS)
                        if isActive {
                            updateFeedSyncCapsule(for: feedSyncObservation)
                        } else {
                            resetFeedSyncCapsulePresentation()
                        }
                        #endif
                    }
                    .onChange(of: scenePhase) { _, _ in
                        consultVisibleNoveltiesIfEligible()
                    }
                    .onChange(of: activeNoveltyCount) { _, _ in
                        consultVisibleNoveltiesIfEligible()
                    }
                    #if DEBUG
                    .onChange(of: Set(feedCache.videos.map { $0.id.id })) { _, availableIDs in
                        noveltyBadgeDiagnostic.finishIfContextChanged(
                            scope: activeNoveltyScope,
                            availableVideoIDs: availableIDs
                        )
                    }
                    #endif
                .task(id: instanceConfigurationID) {
                    LoggingService.shared.debug("SubscriptionsView task triggered, instanceConfigurationID: \(instanceConfigurationID)", category: .general)
                    await loadSubscriptionsAsync()

                    if let appEnvironment {
                        await feedCache.loadFromDiskIfNeeded(using: appEnvironment)
                    }

                    let cacheValid = feedCache.isCacheValid(using: appEnvironment?.settingsManager)
                    LoggingService.shared.debug(
                        "cacheValid: \(cacheValid), isLoading: \(feedCache.isLoading)",
                        category: .general
                    )

                    if !cacheValid && !feedCache.isLoading {
                        LoggingService.shared.info("Cache invalid and not loading, refreshing feed", category: .general)
                        await loadFeed(forceRefresh: false)
                    } else {
                        LoggingService.shared.debug("Using cached feed, no refresh needed", category: .general)
                    }
                }
                .onChange(of: selectedChannelID) { _, _ in
                    withAnimation {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                #if os(iOS)
                .onChange(of: feedSyncObservation, initial: true) { _, observation in
                    updateFeedSyncCapsule(for: observation)
                }
                .onDisappear {
                    resetFeedSyncCapsulePresentation()
                }
                #endif
                #if os(tvOS)
                .onChange(of: filteredVideos.first?.id.videoID, initial: true) { _, newValue in
                    // Work around tvOS ScrollView + prefersDefaultFocus bug: set initial focus
                    // (and refocus after channel filter changes) to the first video once cells materialize.
                    guard let newValue else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        focusedVideoID = newValue
                    }
                }
                #endif
            }
            .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                viewWidth = newWidth
            }
        }
        .environment(\.locale, localizationLocale)
    }

    // MARK: - List Layout

    private var listContent: some View {
        VideoListContainer(listStyle: listStyle, rowStyle: rowStyle) {
            Color.clear
                .frame(height: 0)
                .id("top")

            // Section header (channel link is shown in the inline header on tvOS)
            #if !os(tvOS)
            sectionHeaderView
            #endif
        } content: {
            feedContentRows
        } footer: {
            #if os(iOS)
            // Bottom spacer for channel strip overlay (outside the card)
            if channelStripSize != .disabled && subscriptions.count > 1 && !isShowingFullScreenError {
                Color.clear.frame(height: channelStripSize.totalHeight)
            }
            #else
            EmptyView()
            #endif
        }
    }

    /// Section header with proper padding for list style.
    private var sectionHeaderView: some View {
        HStack {
            feedSectionHeader
            Spacer()
        }
        .padding(.horizontal, listStyle == .inset ? 32 : 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    /// Feed content rows or empty/loading states.
    @ViewBuilder
    private var feedContentRows: some View {
        if case .error(let feedError) = feedCache.feedLoadState, feedCache.videos.isEmpty {
            // Show specific error states
            switch feedError {
            case .yatteeServerRequired:
                yatteeServerRequiredView
            case .compatibleSourceRequired:
                gridErrorView(AppLocalization.string("subscriptions.error.compatibleSourceRequired"))
            case .notAuthenticated:
                notAuthenticatedView
            case .networkError(let message):
                gridErrorView(message)
            }
        } else if feedCache.isLoading && feedCache.videos.isEmpty {
            gridLoadingView
        } else if let error = errorMessage, feedCache.videos.isEmpty {
            gridErrorView(error)
        } else if !feedCache.videos.isEmpty {
            if filteredVideos.isEmpty && selectedChannelID != nil {
                ContentUnavailableView {
                    Label(AppLocalization.string("subscriptions.noVideosFromChannel"), systemImage: "video.slash")
                } description: {
                    Text(AppLocalization.string("subscriptions.noVideosFromChannel.description"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(Array(filteredVideos.enumerated()), id: \.element.id) { index, video in
                    VideoListRow(
                        isLast: index == filteredVideos.count - 1,
                        rowStyle: rowStyle,
                        listStyle: listStyle
                    ) {
                        VideoRowView(
                            video: video,
                            style: rowStyle,
                            watchProgress: watchProgress(for: video)
                        )
                        .tappableVideo(
                            video,
                            queueSource: subscriptionsQueueSource,
                            sourceLabel: AppLocalization.string("queue.source.subscriptions"),
                            videoList: filteredVideos,
                            videoIndex: index,
                            loadMoreVideos: loadMoreSubscriptionsCallback
                        )
                    }
                    #if os(tvOS)
                    .focused($focusedVideoID, equals: video.id.videoID)
                    #else
                    .videoSwipeActions(video: video)
                    #endif
                    #if os(iOS)
                    .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                        updateVisibility(of: video.id.id, isVisible: isVisible)
                    }
                    #endif
                }

            }
        } else if feedCache.hasLoadedOnce {
            gridEmptyView
        } else {
            gridLoadingView
        }
    }

    // MARK: - Grid Layout

    private var gridContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id("top")

                // Section header (channel link is shown in the inline header on tvOS)
                #if !os(tvOS)
                HStack {
                    feedSectionHeader
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
                #endif

                // Content
                if case .error(let feedError) = feedCache.feedLoadState, feedCache.videos.isEmpty {
                    // Show specific error states
                    switch feedError {
                    case .yatteeServerRequired:
                        yatteeServerRequiredView
                    case .compatibleSourceRequired:
                        gridErrorView(AppLocalization.string("subscriptions.error.compatibleSourceRequired"))
                    case .notAuthenticated:
                        notAuthenticatedView
                    case .networkError(let message):
                        gridErrorView(message)
                    }
                } else if feedCache.isLoading && feedCache.videos.isEmpty {
                    gridLoadingView
                } else if let error = errorMessage, feedCache.videos.isEmpty {
                    gridErrorView(error)
                } else if !feedCache.videos.isEmpty {
                    gridFeedContent
                } else if feedCache.hasLoadedOnce {
                    gridEmptyView
                } else {
                    gridLoadingView
                }

                // Bottom spacer for channel strip overlay
                if channelStripSize != .disabled && subscriptions.count > 1 && !isShowingFullScreenError {
                    Color.clear.frame(height: channelStripSize.totalHeight)
                }
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }

    // MARK: - Channel Filter Strip

    private var bottomFloatingFilterStrip: some View {
        ViewThatFits(in: .horizontal) {
            // Option 1: Non-scrolling centered layout (used when all chips fit)
            channelChipsHStack
                .padding(.horizontal, 12)
                .padding(.vertical, channelStripSize.verticalPadding)
                .clipShape(Capsule())
                #if os(tvOS)
                .background(Color.black.opacity(0.3))
                #else
                .glassBackground(.regular, in: .capsule, fallback: .regularMaterial)
                #endif

            // Option 2: Scrollable layout (used when chips overflow)
            ScrollView(.horizontal, showsIndicators: false) {
                channelChipsHStack
                    .padding(.horizontal, 12)
                    .padding(.vertical, channelStripSize.verticalPadding)
            }
            .clipShape(Capsule())
            #if os(tvOS)
            .background(Color.black.opacity(0.3))
            #else
            .glassBackground(.regular, in: .capsule, fallback: .regularMaterial)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The HStack containing channel filter chips (extracted to avoid duplication).
    private var channelChipsHStack: some View {
        HStack(spacing: channelStripSize.chipSpacing) {
            ForEach(sortedSubscriptions, id: \.channelID) { subscription in
                ChannelFilterChip(
                    channelID: subscription.channelID,
                    name: subscription.name,
                    avatarURL: subscription.avatarURL,
                    serverURL: yatteeServerURL,
                    source: subscription.contentSource,
                    isSelected: selectedChannelID == subscription.channelID,
                    avatarSize: channelStripSize.avatarSize,
                    onTap: {
                        if selectedChannelID == subscription.channelID {
                            selectedChannelID = nil
                        } else {
                            selectedChannelID = subscription.channelID
                        }
                    },
                    onGoToChannel: {
                        appEnvironment?.navigationCoordinator.navigate(
                            to: .channel(subscription.channelID, subscription.contentSource)
                        )
                    },
                    onUnsubscribe: {
                        unsubscribeChannel(subscription.channelID)
                    },
                    authHeader: yatteeServerAuthHeader
                )
            }
        }
    }

    // MARK: - tvOS Channels Sidebar

    #if os(tvOS)
    private var tvOSViewOptionsButton: some View {
        Button {
            showViewOptions = true
        } label: {
            Label(AppLocalization.string("viewOptions.title"), systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
    }

    private var tvOSChannelsSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            tvOSViewOptionsButton
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    TVSubscriptionsSidebarRow(
                        name: AppLocalization.string("subscriptions.allChannels"),
                        avatarURL: nil,
                        serverURL: nil,
                        authHeader: nil,
                        channelID: nil,
                        isAllChannels: true,
                        isSelected: selectedChannelID == nil,
                        onTap: {
                            if selectedChannelID != nil {
                                selectedChannelID = nil
                            }
                        }
                    )
                    .contextMenu {
                        Button {
                            appEnvironment?.navigationCoordinator.navigate(to: .manageChannels)
                        } label: {
                            Label(AppLocalization.string("sidebar.manageChannels"), systemImage: "person.2.badge.gearshape")
                        }
                    }

                    ForEach(sortedSubscriptions, id: \.channelID) { subscription in
                        TVSubscriptionsSidebarRow(
                            name: subscription.name,
                            avatarURL: subscription.avatarURL,
                            serverURL: yatteeServerURL,
                            authHeader: yatteeServerAuthHeader,
                            channelID: subscription.channelID,
                            source: subscription.contentSource,
                            isAllChannels: false,
                            isSelected: selectedChannelID == subscription.channelID,
                            onTap: {
                                if selectedChannelID == subscription.channelID {
                                    selectedChannelID = nil
                                } else {
                                    selectedChannelID = subscription.channelID
                                }
                            }
                        )
                        .contextMenu {
                            Button {
                                appEnvironment?.navigationCoordinator.navigate(
                                    to: .channel(subscription.channelID, subscription.contentSource)
                                )
                            } label: {
                                Label(AppLocalization.string("subscriptions.goToChannel"), systemImage: "person.circle")
                            }
                            Button(role: .destructive) {
                                unsubscribeChannel(subscription.channelID)
                            } label: {
                                Label(AppLocalization.string("channel.unsubscribe"), systemImage: "person.badge.minus")
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            .scrollClipDisabled()
        }
    }
    #endif

    // MARK: - Channels Sidebar (macOS / iPad)

    #if !os(tvOS)
    private static let sidebarAllChannelsTag = "__all__"

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { selectedChannelID ?? Self.sidebarAllChannelsTag },
            set: { newValue in
                selectedChannelID = (newValue == Self.sidebarAllChannelsTag) ? nil : newValue
            }
        )
    }

    @ViewBuilder
    private var channelsSidebarContent: some View {
        SubscriptionsSidebarRow(
            name: AppLocalization.string("subscriptions.allChannels"),
            avatarURL: nil,
            serverURL: nil,
            authHeader: nil,
            channelID: nil,
            isAllChannels: true
        )
        .tag(Self.sidebarAllChannelsTag)
        .contextMenu {
            Button {
                appEnvironment?.navigationCoordinator.navigate(to: .manageChannels)
            } label: {
                Label(AppLocalization.string("sidebar.manageChannels"), systemImage: "person.2.badge.gearshape")
            }
        }

        ForEach(sortedSubscriptions, id: \.channelID) { subscription in
            SubscriptionsSidebarRow(
                name: subscription.name,
                avatarURL: subscription.avatarURL,
                serverURL: yatteeServerURL,
                authHeader: yatteeServerAuthHeader,
                channelID: subscription.channelID,
                source: subscription.contentSource,
                isAllChannels: false
            )
            .tag(Optional(subscription.channelID))
            .contextMenu {
                Button {
                    appEnvironment?.navigationCoordinator.navigate(
                        to: .channel(subscription.channelID, subscription.contentSource)
                    )
                } label: {
                    Label(AppLocalization.string("subscriptions.goToChannel"), systemImage: "person.circle")
                }
                Button(role: .destructive) {
                    unsubscribeChannel(subscription.channelID)
                } label: {
                    Label(AppLocalization.string("channel.unsubscribe"), systemImage: "person.badge.minus")
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private static let macOSSidebarMinWidth = 180.0
    private static let macOSSidebarMaxWidth = 400.0

    private var clampedMacOSSidebarWidth: CGFloat {
        CGFloat(min(max(macOSSidebarWidth, Self.macOSSidebarMinWidth), Self.macOSSidebarMaxWidth))
    }

    private var macOSChannelsSidebar: some View {
        List(selection: sidebarSelection) {
            channelsSidebarContent
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var macOSSidebarPlaceholder: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var macOSSidebarResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(width: 1)

            Rectangle()
                .fill(.clear)
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .background(.clear)
        .contentShape(Rectangle())
        .highPriorityGesture(macOSSidebarResizeGesture)
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var macOSSidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if macOSSidebarDragStartWidth == nil {
                    macOSSidebarDragStartWidth = macOSSidebarWidth
                }

                let baseWidth = macOSSidebarDragStartWidth ?? macOSSidebarWidth
                let newWidth = baseWidth + value.translation.width
                macOSSidebarWidth = min(max(newWidth, Self.macOSSidebarMinWidth), Self.macOSSidebarMaxWidth)
            }
            .onEnded { _ in
                macOSSidebarDragStartWidth = nil
            }
    }
    #endif

    private var isSidebarVisible: Bool {
        #if os(macOS)
        return showSidebar && subscriptionsLoaded && subscriptions.count > 1
        #elseif os(iOS)
        return isIPadRegular && showSidebar && subscriptionsLoaded && subscriptions.count > 1
        #elseif os(tvOS)
        return showSidebar && subscriptionsLoaded && subscriptions.count > 1
        #else
        return false
        #endif
    }

    #if os(iOS)
    private static let iPadSidebarMinWidth = 220.0
    private static let iPadSidebarMaxWidth = 420.0

    private var isIPadRegular: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private var clampedIPadSidebarWidth: CGFloat {
        CGFloat(min(max(iPadSidebarWidth, Self.iPadSidebarMinWidth), Self.iPadSidebarMaxWidth))
    }

    @ViewBuilder
    private var feedLayout: some View {
        Group {
            switch layout {
            case .list:
                listContent
            case .grid:
                gridContent
            }
        }
    }

    private var iOSChannelsSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                iOSSidebarRow(
                    name: AppLocalization.string("subscriptions.allChannels"),
                    avatarURL: nil,
                    serverURL: nil,
                    authHeader: nil,
                    channelID: nil,
                    isAllChannels: true,
                    isSelected: selectedChannelID == nil
                ) {
                    if selectedChannelID != nil { selectedChannelID = nil }
                }
                .contextMenu {
                    Button {
                        appEnvironment?.navigationCoordinator.navigate(to: .manageChannels)
                    } label: {
                        Label(AppLocalization.string("sidebar.manageChannels"), systemImage: "person.2.badge.gearshape")
                    }
                }

                ForEach(sortedSubscriptions, id: \.channelID) { subscription in
                    iOSSidebarRow(
                        name: subscription.name,
                        avatarURL: subscription.avatarURL,
                        serverURL: yatteeServerURL,
                        authHeader: yatteeServerAuthHeader,
                        channelID: subscription.channelID,
                        source: subscription.contentSource,
                        isAllChannels: false,
                        isSelected: selectedChannelID == subscription.channelID
                    ) {
                        if selectedChannelID == subscription.channelID {
                            selectedChannelID = nil
                        } else {
                            selectedChannelID = subscription.channelID
                        }
                    }
                    .contextMenu {
                        Button {
                            appEnvironment?.navigationCoordinator.navigate(
                                to: .channel(subscription.channelID, subscription.contentSource)
                            )
                        } label: {
                            Label(AppLocalization.string("subscriptions.goToChannel"), systemImage: "person.circle")
                        }
                        Button(role: .destructive) {
                            unsubscribeChannel(subscription.channelID)
                        } label: {
                            Label(AppLocalization.string("channel.unsubscribe"), systemImage: "person.badge.minus")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var iPadSidebarResizeHandle: some View {
        if isIPadRegular {
            Rectangle()
                .fill(.separator.opacity(0.7))
                .frame(width: 1)
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(iPadSidebarResizeGesture)
        }
    }

    private var iPadSidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if iPadSidebarDragStartWidth == nil {
                    iPadSidebarDragStartWidth = iPadSidebarWidth
                }

                let baseWidth = iPadSidebarDragStartWidth ?? iPadSidebarWidth
                let newWidth = baseWidth + value.translation.width
                iPadSidebarWidth = min(max(newWidth, Self.iPadSidebarMinWidth), Self.iPadSidebarMaxWidth)
            }
            .onEnded { _ in
                iPadSidebarDragStartWidth = nil
            }
    }

    @ViewBuilder
    private func iOSSidebarRow(
        name: String,
        avatarURL: URL?,
        serverURL: URL?,
        authHeader: String?,
        channelID: String?,
        source: ContentSource? = nil,
        isAllChannels: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SubscriptionsSidebarRow(
                name: name,
                avatarURL: avatarURL,
                serverURL: serverURL,
                authHeader: authHeader,
                channelID: channelID,
                source: source,
                isAllChannels: isAllChannels,
                isSelected: isSelected
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.2) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Content Views

    private var subscriptionsQueueSource: QueueSource {
        .subscriptions(continuation: nil)
    }

    @ViewBuilder
    private var gridFeedContent: some View {
        if filteredVideos.isEmpty && selectedChannelID != nil {
            ContentUnavailableView {
                Label(AppLocalization.string("subscriptions.noVideosFromChannel"), systemImage: "video.slash")
            } description: {
                Text(AppLocalization.string("subscriptions.noVideosFromChannel.description"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 40)
        } else {
            VideoGridContent(columns: gridConfig.effectiveColumns) {
                ForEach(Array(filteredVideos.enumerated()), id: \.element.id) { index, video in
                    VideoCardView(
                        video: video,
                        watchProgress: watchProgress(for: video),
                        isCompact: gridConfig.isCompactCards
                    )
                    .tappableVideo(
                        video,
                        queueSource: subscriptionsQueueSource,
                        sourceLabel: AppLocalization.string("queue.source.subscriptions"),
                        videoList: filteredVideos,
                        videoIndex: index,
                        loadMoreVideos: loadMoreSubscriptionsCallback
                    )
                    #if os(tvOS)
                    .focused($focusedVideoID, equals: video.id.videoID)
                    #endif
                    #if os(iOS)
                    .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                        updateVisibility(of: video.id.id, isVisible: isVisible)
                    }
                    #endif
                }
            }

        }
    }

    private var feedSectionHeader: some View {
        HStack {
            feedSectionHeaderLabel
            Spacer()
        }
    }

    @ViewBuilder
    private var feedSectionHeaderLabel: some View {
        if isSidebarVisible {
            EmptyView()
        } else if let subscription = selectedSubscription {
            Button {
                appEnvironment?.navigationCoordinator.navigate(
                    to: .channel(subscription.channelID, subscription.contentSource)
                )
            } label: {
                HStack(spacing: 4) {
                    Text(subscription.name)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: NavigationDestination.manageChannels) {
                HStack(spacing: 4) {
                    Text(AppLocalization.string("subscriptions.allChannels"))
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    #if os(iOS)
    private var feedSyncObservation: FeedSyncObservation {
        FeedSyncObservation(
            loadState: feedCache.feedLoadState,
            isLoading: feedCache.isLoading,
            hasCachedVideos: !feedCache.videos.isEmpty
        )
    }

    @ViewBuilder
    private func feedSyncCapsule(for state: FeedSyncCapsuleState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .synchronizing:
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(accentColor)
                    .symbolEffect(.rotate, options: .repeating)

                Text(AppLocalization.string("subscriptions.feedSync.synchronizing"))

            case .progress(let completed, let total):
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(accentColor)
                    .symbolEffect(.rotate, options: .repeating)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(AppLocalization.string("subscriptions.feedSync.synchronizing"))
                        Spacer(minLength: 4)
                        Text(verbatim: "\(Int((Double(completed) / Double(total)) * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
                .frame(width: 210)

            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(AppLocalization.string("subscriptions.feedSync.upToDate"))

            case .partial:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(AppLocalization.string("subscriptions.feedSync.incomplete"))

            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(AppLocalization.string("subscriptions.feedSync.error"))
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackground(.regular, in: .capsule, fallback: .regularMaterial)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }

    private func updateFeedSyncCapsule(for observation: FeedSyncObservation) {
        guard isTabActive else {
            resetFeedSyncCapsulePresentation()
            return
        }

        switch observation.loadState {
        case .loading:
            hasObservedFeedSynchronization = true
            presentFeedSyncCapsule(.synchronizing)

        case .partiallyLoaded(let ready, let pending, let errors):
            if observation.isLoading {
                hasObservedFeedSynchronization = true
                let total = ready + pending + errors
                if pending > 0, total > 0 {
                    presentFeedSyncCapsule(.progress(completed: ready, total: total))
                } else {
                    presentFeedSyncCapsule(.synchronizing)
                }
            } else {
                guard hasObservedFeedSynchronization else { return }
                hasObservedFeedSynchronization = false
                presentFeedSyncCapsule(.partial, dismissAfter: .seconds(3))
            }

        case .ready:
            guard hasObservedFeedSynchronization else { return }
            hasObservedFeedSynchronization = false
            presentFeedSyncCapsule(.success, dismissAfter: .seconds(2))

        case .error:
            guard hasObservedFeedSynchronization else { return }
            hasObservedFeedSynchronization = false
            if observation.hasCachedVideos {
                presentFeedSyncCapsule(.error, dismissAfter: .seconds(3))
            } else {
                dismissFeedSyncCapsule()
            }

        case .idle, .loadingMore:
            hasObservedFeedSynchronization = false
            dismissFeedSyncCapsule()
        }
    }

    private func presentFeedSyncCapsule(
        _ state: FeedSyncCapsuleState,
        dismissAfter delay: Duration? = nil
    ) {
        feedSyncCapsuleDismissTask?.cancel()
        feedSyncCapsuleDismissTask = nil

        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            feedSyncCapsuleState = state
        }

        guard let delay else { return }
        feedSyncCapsuleDismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, feedSyncCapsuleState == state else { return }
            dismissFeedSyncCapsule()
        }
    }

    private func dismissFeedSyncCapsule() {
        feedSyncCapsuleDismissTask?.cancel()
        feedSyncCapsuleDismissTask = nil
        withAnimation(.easeOut(duration: 0.22)) {
            feedSyncCapsuleState = nil
        }
    }

    private func resetFeedSyncCapsulePresentation() {
        feedSyncCapsuleDismissTask?.cancel()
        feedSyncCapsuleDismissTask = nil
        feedSyncCapsuleState = nil
        hasObservedFeedSynchronization = false
    }
    #endif

    // MARK: - Loading/Error/Empty Views

    private var gridLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()

            if let progress = feedCache.loadingProgress {
                Text(verbatim: "\(progress.loaded)/\(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var gridEmptyView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("subscriptions.feed.title"), systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text(AppLocalization.string("subscriptions.empty.description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    /// Empty state shown when Yattee Server is required but not configured.
    private var yatteeServerRequiredView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("subscriptions.yatteeServerRequired.title"), systemImage: "server.rack")
        } description: {
            Text(AppLocalization.string("subscriptions.yatteeServerRequired.description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    /// Empty state shown when Invidious account is not authenticated.
    private var notAuthenticatedView: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("subscriptions.notAuthenticated.title"), systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(AppLocalization.string("subscriptions.notAuthenticated.description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func gridErrorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label(AppLocalization.string("common.error"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button(AppLocalization.string("common.retry")) {
                Task { await loadFeed(forceRefresh: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data Loading

    private func loadSubscriptions() {
        subscriptions = dataManager?.subscriptions() ?? []
        subscriptionsLoaded = true
        sidebarExpected = subscriptions.count > 1

        if let selectedID = selectedChannelID,
           !subscriptions.contains(where: { $0.channelID == selectedID }) {
            selectedChannelID = nil
        }
    }

    /// Keeps the async call site used by the view lifecycle while sourcing the
    /// list exclusively from local SwiftData storage.
    private func loadSubscriptionsAsync() async {
        loadSubscriptions()
    }

    private func loadWatchEntries() {
        watchEntriesMap = dataManager?.watchEntriesMap() ?? [:]
    }

    #if os(iOS)
    private func updateVisibility(of videoID: String, isVisible: Bool) {
        if isVisible {
            visibleVideoIDs.insert(videoID)
            consultVisibleNoveltiesIfEligible()
        } else {
            visibleVideoIDs.remove(videoID)
        }
    }

    private func consultVisibleNoveltiesIfEligible() {
        let candidates = visibleVideoIDs.subtracting(pendingConsultedVideoIDs)
        guard FeedNoveltyConsultationPolicy.shouldConsult(
            isTabActive: isTabActive,
            isSceneActive: scenePhase == .active,
            visibleVideoIDs: candidates
        ), let scope = activeNoveltyScope else { return }

        #if DEBUG
        if noveltyBadgeDiagnostic.scope == scope {
            noveltyBadgeDiagnostic.markVisible(videoIDs: candidates, in: scope)
            return
        }
        #endif

        pendingConsultedVideoIDs.formUnion(candidates)
        Task {
            await FeedNoveltyRegistry.shared.markConsulted(
                videoIDs: candidates,
                in: scope
            )
            pendingConsultedVideoIDs.subtract(candidates)
        }
    }
    #endif

    private func loadFeed(forceRefresh: Bool) async {
        guard let appEnvironment else { return }

        if !forceRefresh && feedCache.isCacheValid(using: appEnvironment.settingsManager) {
            return
        }

        errorMessage = nil
        await feedCache.refresh(using: appEnvironment)
    }

    private func unsubscribeChannel(_ channelID: String) {
        dataManager?.unsubscribe(from: channelID)
        subscriptions.removeAll { $0.channelID == channelID }
    }

    @Sendable
    private func loadMoreSubscriptionsCallback() async throws -> ([Video], String?) {
        return ([], nil)
    }
}

#if os(iOS)
private struct FeedSyncObservation: Equatable {
    let loadState: FeedLoadState
    let isLoading: Bool
    let hasCachedVideos: Bool
}

private enum FeedSyncCapsuleState: Equatable {
    case synchronizing
    case progress(completed: Int, total: Int)
    case success
    case partial
    case error
}
#endif

// MARK: - Preview

#Preview("With Subscriptions") {
    PreviewWrapper()
}

private struct PreviewWrapper: View {
    let dataManager: DataManager
    let previewEnvironment: AppEnvironment

    init() {
        let dataManager = try! DataManager.preview()

        let channel1 = Channel(
            id: ChannelID(source: .global(provider: ContentSource.youtubeProvider), channelID: "UC1"),
            name: "Apple Developer",
            thumbnailURL: nil
        )
        let channel2 = Channel(
            id: ChannelID(source: .global(provider: ContentSource.youtubeProvider), channelID: "UC2"),
            name: "Marques Brownlee",
            thumbnailURL: nil
        )
        let channel3 = Channel(
            id: ChannelID(source: .global(provider: ContentSource.youtubeProvider), channelID: "UC3"),
            name: "Music Channel",
            thumbnailURL: nil
        )

        dataManager.subscribe(to: channel1)
        dataManager.subscribe(to: channel2)
        dataManager.subscribe(to: channel3)

        self.dataManager = dataManager
        self.previewEnvironment = AppEnvironment(dataManager: dataManager)

        let cache = SubscriptionFeedCache.shared
        cache.videos = [
            Video(
                id: VideoID(source: .global(provider: ContentSource.youtubeProvider), videoID: "video1"),
                title: "SwiftUI Tutorial: Building Amazing Apps",
                description: "Learn how to build amazing apps with SwiftUI",
                author: Author(id: "UC1", name: "Apple Developer"),
                duration: 600,
                publishedAt: Date().addingTimeInterval(-3600),
                publishedText: "1 hour ago",
                viewCount: 10000,
                likeCount: 500,
                thumbnails: [],
                isLive: false,
                isUpcoming: false,
                scheduledStartTime: nil
            ),
            Video(
                id: VideoID(source: .global(provider: ContentSource.youtubeProvider), videoID: "video2"),
                title: "Tech Review: Latest Innovations",
                description: "Reviewing the latest tech innovations",
                author: Author(id: "UC2", name: "Marques Brownlee"),
                duration: 900,
                publishedAt: Date().addingTimeInterval(-7200),
                publishedText: "2 hours ago",
                viewCount: 50000,
                likeCount: 2000,
                thumbnails: [],
                isLive: false,
                isUpcoming: false,
                scheduledStartTime: nil
            ),
            Video(
                id: VideoID(source: .global(provider: ContentSource.youtubeProvider), videoID: "video3"),
                title: "Music Production Tips and Tricks",
                description: "Professional music production techniques",
                author: Author(id: "UC3", name: "Music Channel"),
                duration: 450,
                publishedAt: Date().addingTimeInterval(-10800),
                publishedText: "3 hours ago",
                viewCount: 5000,
                likeCount: 250,
                thumbnails: [],
                isLive: false,
                isUpcoming: false,
                scheduledStartTime: nil
            )
        ]
        cache.hasLoadedOnce = true
        cache.lastUpdated = Date()
    }

    var body: some View {
        NavigationStack {
            SubscriptionsView()
        }
        .appEnvironment(previewEnvironment)
    }
}

#Preview("Empty") {
    NavigationStack {
        SubscriptionsView()
    }
    .appEnvironment(.preview)
}
