//
//  ContentView.swift
//  Yattee
//
//  Root content view with tab-based navigation.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        Group {
            if let appEnvironment {
                #if os(iOS)
                if #available(iOS 26.1, *) {
                    iOS26AdaptiveTabView(appEnvironment: appEnvironment)
                } else {
                    iOS18AdaptiveTabView(appEnvironment: appEnvironment)
                }
                #elseif os(macOS)
                unifiedContentView(appEnvironment: appEnvironment)
                #elseif os(tvOS)
                unifiedContentView(appEnvironment: appEnvironment)
                #endif
            } else {
                ProgressView(AppLocalization.string("common.loading"))
            }
        }
        .onChange(of: appEnvironment?.settingsManager.resolvedVideoMetadataLanguage) { oldValue, newValue in
            guard oldValue != newValue, let appEnvironment, let newValue else { return }
            Task {
                if case .yatteeServer = LocalFeedSource.resolve(
                    from: appEnvironment.instancesManager.instances,
                    preference: appEnvironment.settingsManager.localFeedSourcePreference
                ) {
                    await SubscriptionFeedCache.shared.loadFromDiskIfNeeded(using: appEnvironment)
                    // The language-scoped cache is the same immediate snapshot shown by
                    // Feed. Reconcile persisted cards now instead of waiting for the
                    // grouped network refresh to finish.
                    appEnvironment.dataManager.updatePersistedMetadata(
                        from: SubscriptionFeedCache.shared.videos
                    )
                    await SubscriptionFeedCache.shared.refresh(using: appEnvironment)
                }
                await appEnvironment.playerService.videoMetadataLanguageDidChange(to: newValue)
            }
        }
        .toastOverlay()
    }

    // MARK: - Unified Content View (macOS 15+, tvOS 18+)

    @ViewBuilder
    private func unifiedContentView(appEnvironment: AppEnvironment) -> some View {
        ZStack(alignment: .bottom) {
            #if os(macOS)
            UnifiedTabView(
                selectedTab: Binding(
                    get: { appEnvironment.navigationCoordinator.selectedTab },
                    set: { appEnvironment.navigationCoordinator.selectedTab = $0 }
                )
            )
            .environment(appEnvironment.settingsManager)
            #elseif os(tvOS)
            UnifiedTabView(
                selectedTab: Binding(
                    get: { appEnvironment.navigationCoordinator.selectedTab },
                    set: { appEnvironment.navigationCoordinator.selectedTab = $0 }
                )
            )
            .environment(appEnvironment.settingsManager)
            #endif

            // Mini player overlay (macOS only)
            #if os(macOS)
            miniPlayerOverlay(appEnvironment: appEnvironment)

            // Inline expanded player: presented as a full-window overlay
            // (no native sheet — a window with an attached sheet can't go
            // fullscreen, so fullscreen is just the window's native toggle).
            if isInlinePlayerOverlayActive(appEnvironment: appEnvironment) {
                ZStack {
                    Color.black
                    ExpandedPlayerSheet()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            #endif
        }
        #if os(macOS)
        // Registers the hosting window so the inline overlay targets the real
        // main window even when another window (e.g. Settings) has focus.
        .background(MainContentWindowReader())
        .animation(.easeInOut(duration: 0.2), value: isInlinePlayerOverlayActive(appEnvironment: appEnvironment))
        .onChange(of: isInlinePlayerOverlayActive(appEnvironment: appEnvironment)) { _, active in
            if active {
                ExpandedPlayerWindowManager.shared.beginInlineOverlay()
            } else {
                ExpandedPlayerWindowManager.shared.endInlineOverlay()
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.playerExpandTrigger) { _, _ in
            if appEnvironment.settingsManager.macPlayerSeparateWindow {
                presentExpandedPlayerWindow(appEnvironment: appEnvironment)
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.isPlayerExpanded) { _, isExpanded in
            if !isExpanded {
                ExpandedPlayerWindowManager.shared.hide()
            }
        }
        .onChange(of: appEnvironment.settingsManager.macPlayerSeparateWindow) { _, separateWindow in
            guard appEnvironment.navigationCoordinator.isPlayerExpanded else { return }

            if separateWindow {
                // Inline overlay → separate window: the overlay unmounts via the
                // presentation condition; present the window directly.
                presentExpandedPlayerWindow(appEnvironment: appEnvironment)
            } else {
                // Separate window → inline overlay: hide the window so the overlay
                // (isPlayerExpanded && !separateWindow) takes over.
                ExpandedPlayerWindowManager.shared.hide(animated: false)
            }
        }
        .onChange(of: appEnvironment.settingsManager.macPlayerFloating) { _, floating in
            guard appEnvironment.navigationCoordinator.isPlayerExpanded,
                  appEnvironment.settingsManager.macPlayerSeparateWindow else { return }
            ExpandedPlayerWindowManager.shared.updateWindowLevel(floating: floating)
        }
        .sheet(isPresented: Binding(
            get: { appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented },
            set: { appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented = $0 }
        )) {
            QueueManagementSheet()
        }
        .sheet(isPresented: Binding(
            get: { appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented },
            set: { appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented = $0 }
        )) {
            if let video = appEnvironment.playerService.state.currentVideo {
                PlaylistSelectorSheet(video: video)
            }
        }
        #elseif os(tvOS)
        .fullScreenCover(isPresented: Binding(
            get: { appEnvironment.navigationCoordinator.isPlayerExpanded },
            set: { appEnvironment.navigationCoordinator.isPlayerExpanded = $0 }
        )) {
            TVPlayerView()
        }
        #endif
    }

    #if os(macOS)
    private func presentExpandedPlayerWindow(appEnvironment: AppEnvironment) {
        ExpandedPlayerWindowManager.shared.show(with: appEnvironment, animated: true)
    }

    /// Whether the inline (non-separate-window) expanded player overlay should
    /// be presented. Shared by the overlay mount and the begin/end onChange so
    /// the two can't drift apart.
    private func isInlinePlayerOverlayActive(appEnvironment: AppEnvironment) -> Bool {
        appEnvironment.navigationCoordinator.isPlayerExpanded &&
            !appEnvironment.settingsManager.macPlayerSeparateWindow
    }
    #endif

    #if os(macOS)
    @ViewBuilder
    private func miniPlayerOverlay(appEnvironment: AppEnvironment) -> some View {
        let playerState = appEnvironment.playerService.state
        let hasActiveVideo = playerState.currentVideo != nil
        let isExpanded = appEnvironment.navigationCoordinator.isPlayerExpanded
        // The expanded player is a separate window in window mode, so keep the capsule
        // visible alongside it. The inline overlay covers the window, so hide it there.
        let usesWindow = appEnvironment.settingsManager.macPlayerSeparateWindow

        if hasActiveVideo && (!isExpanded || usesWindow) {
            VStack(spacing: 0) {
                Spacer()
                MiniPlayerView()
            }
            // Float the capsule above the bottom edge (macOS uses a sidebar, not a tab bar)
            .padding(.bottom, 16)
            // Use move-only transition (no opacity) to prevent thumbnail flash during collapse
            .transition(.move(edge: .bottom))
            .animation(.spring(response: 0.3), value: hasActiveVideo)
        }
    }
    #endif
}

// MARK: - iOS 18+ Adaptive Tab View

#if os(iOS)
/// Switches between CompactTabView and UnifiedTabView based on horizontal size class.
/// Compact width (iPhone, iPad Stage Manager small): CompactTabView with settings-based customization
/// Regular width (iPad full, iPad larger windows): UnifiedTabView with sidebar adaptable
struct iOS18AdaptiveTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let appEnvironment: AppEnvironment

    @State private var showingMiniPlayerQueueSheet = false
    @State private var showingMiniPlayerPlaylistSheet = false

    /// Whether to show the black overlay that covers scaled content when player is expanded
    private var shouldShowExpandedOverlay: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show overlay only when:
        // - Player window is actually visible (not just isPlayerExpanded intent)
        // - Expand animation has completed (not animating)
        // - Dismiss gesture is not active (so user can see scaled content during drag)
        return nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating && !nav.isPlayerDismissGestureActive
    }

    /// Whether to show loading spinner while waiting for player window to appear
    private var shouldShowExpandPendingSpinner: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show spinner when expand is requested but window isn't visible yet
        return nav.isPlayerExpanded && !nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone {
                CompactTabView()
                    .environment(appEnvironment.settingsManager)
            } else {
                UnifiedTabView(
                    selectedTab: Binding(
                        get: { appEnvironment.navigationCoordinator.selectedTab },
                        set: { appEnvironment.navigationCoordinator.selectedTab = $0 }
                    )
                )
                .environment(appEnvironment.settingsManager)
            }

            // Mini player overlay
            FloatingMiniPlayerHost(
                isEnabled: true,
                hasActiveVideo: appEnvironment.playerService.state.currentVideo != nil,
                isPlayerExpanded: appEnvironment.navigationCoordinator.isPlayerExpanded,
                style: appEnvironment.activeMiniPlayerStyle
            )

            // Black overlay when player is fully expanded
            // Hides scaled content behind player sheet, removed during dismiss gesture for parallax effect
            if shouldShowExpandedOverlay {
                Color.black
                    .ignoresSafeArea()
                    .transaction { $0.animation = nil }
            }

            // Loading spinner when expand is pending but window not yet visible
            // This handles the case when scene is transitioning (e.g., Control Center)
            if shouldShowExpandPendingSpinner {
                ZStack {
                    Color.black.opacity(0.7)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.playerExpandTrigger) { _, _ in
            presentExpandedPlayer()
        }
        .onChange(of: appEnvironment.navigationCoordinator.isPlayerExpanded) { _, isExpanded in
            if !isExpanded {
                ExpandedPlayerWindowManager.shared.hide()
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented) { _, newValue in
            showingMiniPlayerQueueSheet = newValue
        }
        .onChange(of: appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented) { _, newValue in
            showingMiniPlayerPlaylistSheet = newValue
        }
        .sheet(isPresented: $showingMiniPlayerQueueSheet, onDismiss: {
            appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented = false
        }) {
            QueueManagementSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingMiniPlayerPlaylistSheet, onDismiss: {
            appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented = false
        }) {
            if let video = appEnvironment.playerService.state.currentVideo {
                PlaylistSelectorSheet(video: video)
                    .presentationDetents([.medium, .large])
            }
        }
        .modifier(IPhoneOrientationCoordinator(appEnvironment: appEnvironment))
    }

    private func presentExpandedPlayer() {
        let shouldAnimate = !appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation
        appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation = false
        ExpandedPlayerWindowManager.shared.show(with: appEnvironment, animated: shouldAnimate)
    }

}

// MARK: - iOS 26+ Adaptive Tab View

/// iOS 26.1+ version with bottom accessory mini player support.
/// Uses UnifiedTabView with sidebarAdaptable for regular width, CompactTabView for compact.
@available(iOS 26.1, *)
struct iOS26AdaptiveTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let appEnvironment: AppEnvironment

    @State private var showingMiniPlayerQueueSheet = false
    @State private var showingMiniPlayerPlaylistSheet = false

    private var miniPlayerPresentation: MiniPlayerPresentation {
        MiniPlayerPresentation.resolve(
            style: appEnvironment.activeMiniPlayerStyle,
            supportsTabAccessory: true
        )
    }

    /// Whether to show the black overlay that covers scaled content when player is expanded
    private var shouldShowExpandedOverlay: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show overlay only when:
        // - Player window is actually visible (not just isPlayerExpanded intent)
        // - Expand animation has completed (not animating)
        // - Dismiss gesture is not active (so user can see scaled content during drag)
        return nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating && !nav.isPlayerDismissGestureActive
    }

    /// Whether to show loading spinner while waiting for player window to appear
    private var shouldShowExpandPendingSpinner: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show spinner when expand is requested but window isn't visible yet
        return nav.isPlayerExpanded && !nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone {
                    // Compact: Use CompactTabView with settings-based customization
                    CompactTabView(
                        usesMiniPlayerAccessory: miniPlayerPresentation == .tabAccessory
                    )
                        .environment(appEnvironment.settingsManager)
                } else {
                    // Regular: Use UnifiedTabView which has bottom accessory support via sidebarAdaptable
                    UnifiedTabView(
                        selectedTab: Binding(
                            get: { appEnvironment.navigationCoordinator.selectedTab },
                            set: { appEnvironment.navigationCoordinator.selectedTab = $0 }
                        ),
                        usesMiniPlayerAccessory: miniPlayerPresentation == .tabAccessory
                    )
                    .environment(appEnvironment.settingsManager)
                }
            }

            FloatingMiniPlayerHost(
                isEnabled: miniPlayerPresentation == .rootOverlay,
                hasActiveVideo: appEnvironment.playerService.state.currentVideo != nil,
                isPlayerExpanded: appEnvironment.navigationCoordinator.isPlayerExpanded,
                style: appEnvironment.activeMiniPlayerStyle
            )

            // Black overlay when player is fully expanded
            // Hides scaled content behind player sheet, removed during dismiss gesture for parallax effect
            if shouldShowExpandedOverlay {
                Color.black
                    .ignoresSafeArea()
                    .transaction { $0.animation = nil }
            }

            // Loading spinner when expand is pending but window not yet visible
            // This handles the case when scene is transitioning (e.g., Control Center)
            if shouldShowExpandPendingSpinner {
                ZStack {
                    Color.black.opacity(0.7)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.playerExpandTrigger) { _, _ in
            presentExpandedPlayer()
        }
        #if DEBUG
        .onAppear {
            logMiniPlayerPresentation(reason: "appear")
        }
        .onChange(of: appEnvironment.activeMiniPlayerStyle) { _, _ in
            logMiniPlayerPresentation(reason: "styleChanged")
        }
        #endif
        .onChange(of: appEnvironment.navigationCoordinator.isPlayerExpanded) { _, isExpanded in
            if !isExpanded {
                ExpandedPlayerWindowManager.shared.hide()
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented) { _, newValue in
            showingMiniPlayerQueueSheet = newValue
        }
        .onChange(of: appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented) { _, newValue in
            showingMiniPlayerPlaylistSheet = newValue
        }
        .sheet(isPresented: $showingMiniPlayerQueueSheet, onDismiss: {
            appEnvironment.navigationCoordinator.isMiniPlayerQueueSheetPresented = false
        }) {
            QueueManagementSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingMiniPlayerPlaylistSheet, onDismiss: {
            appEnvironment.navigationCoordinator.isMiniPlayerPlaylistSheetPresented = false
        }) {
            if let video = appEnvironment.playerService.state.currentVideo {
                PlaylistSelectorSheet(video: video)
                    .presentationDetents([.medium, .large])
            }
        }
        .modifier(IPhoneOrientationCoordinator(appEnvironment: appEnvironment))
    }

    private func presentExpandedPlayer() {
        let shouldAnimate = !appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation
        appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation = false
        ExpandedPlayerWindowManager.shared.show(with: appEnvironment, animated: shouldAnimate)
    }

    #if DEBUG
    private func logMiniPlayerPresentation(reason: String) {
        let variant = horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone
            ? "compact"
            : "regular"
        LoggingService.shared.debug(
            "[MiniPlayerPresentation] ContentView reason=\(reason) variant=\(variant) " +
                "style=\(appEnvironment.activeMiniPlayerStyle.rawValue) " +
                "presentation=\(String(describing: miniPlayerPresentation))",
            category: .general
        )
    }
    #endif
}

// MARK: - iPhone Orientation Coordination

/// Coordinates navigation portrait locking and opt-in automatic landscape
/// rotation while the expanded player is visible.
private struct IPhoneOrientationCoordinator: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    let appEnvironment: AppEnvironment

    private var settings: SettingsManager { appEnvironment.settingsManager }
    private var navigation: NavigationCoordinator { appEnvironment.navigationCoordinator }
    private var playerState: PlayerState { appEnvironment.playerService.state }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard isPhone else { return }
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                logAutoLandscape("coordinator enabled orientation=\(UIDevice.current.orientation.rawValue)")
                updateNavigationPolicy(requestPortrait: true)
            }
            .onDisappear {
                guard isPhone else { return }
                logAutoLandscape("coordinator disabled")
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                handlePhysicalOrientationChange(UIDevice.current.orientation)
            }
            .onChange(of: settings.preferPortraitBrowsing) { _, _ in
                updateNavigationPolicy(requestPortrait: true)
            }
            .onChange(of: settings.automaticLandscapeFullscreen) { _, isEnabled in
                guard !isEnabled else { return }
                logAutoLandscape("setting disabled; cancelling automatic ownership")
                navigation.isAutomaticLandscapeFullscreen = false
            }
            .onChange(of: navigation.isPlayerExpanded) { _, isExpanded in
                OrientationManager.shared.updateNavigationPolicy(
                    prefersPortrait: settings.preferPortraitBrowsing,
                    playerExpanded: isExpanded
                )

                if !isExpanded {
                    navigation.isAutomaticLandscapeFullscreen = false
                    if settings.preferPortraitBrowsing {
                        requestInterfaceOrientation(.portrait)
                    }
                }
            }
            .onChange(of: navigation.isPlayerWindowVisible) { _, isVisible in
                logAutoLandscape(
                    "expanded window visibility=\(isVisible) automatic=\(navigation.isAutomaticLandscapeFullscreen)"
                )
            }
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var hasActiveVideoPlayback: Bool {
        guard playerState.currentVideo != nil else { return false }
        switch playerState.playbackState {
        case .ready, .playing, .paused, .buffering:
            return true
        case .idle, .loading, .ended, .failed:
            return false
        }
    }

    private func updateNavigationPolicy(requestPortrait: Bool) {
        guard isPhone else { return }
        OrientationManager.shared.updateNavigationPolicy(
            prefersPortrait: settings.preferPortraitBrowsing,
            playerExpanded: navigation.isPlayerExpanded
        )
        if requestPortrait,
           settings.preferPortraitBrowsing,
           !navigation.isPlayerExpanded {
            requestInterfaceOrientation(.portrait)
        }
    }

    private func handlePhysicalOrientationChange(_ orientation: UIDeviceOrientation) {
        guard isPhone else { return }
        logAutoLandscape(
            "physical orientation=\(orientation.rawValue) scene=\(String(describing: scenePhase)) " +
                "setting=\(settings.automaticLandscapeFullscreen) playback=\(String(describing: playerState.playbackState)) " +
                "expanded=\(navigation.isPlayerExpanded) visible=\(navigation.isPlayerWindowVisible) " +
                "locked=\(settings.inAppOrientationLock)"
        )
        guard scenePhase == .active else {
            logAutoLandscape("ignored: scene is not active")
            return
        }

        switch orientation {
        case .landscapeLeft, .landscapeRight:
            beginAutomaticLandscapeFullscreen(for: orientation)
        case .portrait:
            endAutomaticLandscapeFullscreen()
        case .portraitUpsideDown, .faceUp, .faceDown, .unknown:
            break
        @unknown default:
            break
        }
    }

    private func beginAutomaticLandscapeFullscreen(for deviceOrientation: UIDeviceOrientation) {
        guard settings.automaticLandscapeFullscreen else {
            logAutoLandscape("ignored landscape: setting is disabled")
            return
        }
        guard hasActiveVideoPlayback else {
            logAutoLandscape("ignored landscape: no active playable video")
            return
        }
        guard navigation.isPlayerExpanded,
              navigation.isPlayerWindowVisible else {
            logAutoLandscape("ignored landscape: expanded player is not visible")
            return
        }
        guard !navigation.isPlayerExpanding,
              !navigation.isPlayerCollapsing,
              !navigation.isPlayerSheetAnimating else {
            logAutoLandscape("ignored landscape: player transition is active")
            return
        }
        guard playerState.pipState != .active else {
            logAutoLandscape("ignored landscape: PiP is active")
            return
        }
        guard playerState.currentVideo?.contentKind != .short else {
            logAutoLandscape("ignored landscape: current video is a Short")
            return
        }
        guard !playerState.isVerticalVideo else {
            logAutoLandscape("ignored landscape: current video is vertical")
            return
        }
        guard !navigation.isAutomaticLandscapeFullscreen else {
            logAutoLandscape("ignored landscape: automatic transition already owns fullscreen")
            return
        }
        if let interfaceOrientation = foregroundWindowScene?.interfaceOrientation,
           interfaceOrientation.isLandscape {
            logAutoLandscape("ignored landscape: expanded player is already landscape")
            return
        }

        let interfaceOrientation: UIInterfaceOrientationMask = deviceOrientation == .landscapeLeft
            ? .landscapeRight
            : .landscapeLeft

        navigation.isAutomaticLandscapeFullscreen = true
        logAutoLandscape("using visible expanded player; requesting landscape")
        requestInterfaceOrientation(interfaceOrientation, cancelAutomaticPresentationOnError: true)
    }

    private func endAutomaticLandscapeFullscreen() {
        guard navigation.isAutomaticLandscapeFullscreen else {
            logAutoLandscape("portrait detected without automatic ownership")
            return
        }
        guard navigation.isPlayerExpanded,
              !navigation.isPlayerCollapsing else {
            logAutoLandscape("ignored portrait: player is not expanded or is collapsing")
            return
        }

        logAutoLandscape("portrait return detected")

        Task { @MainActor in
            // A physical portrait event may arrive during the presentation
            // animation. Defer this single event instead of losing it.
            await navigation.waitForPlayerSheetAnimation()
            guard UIDevice.current.orientation == .portrait,
                  navigation.isAutomaticLandscapeFullscreen,
                  navigation.isPlayerExpanded,
                  !navigation.isPlayerCollapsing else { return }

            if settings.inAppOrientationLock {
                OrientationManager.shared.lock(to: .portrait)
            }
            requestInterfaceOrientation(.portrait, cancelAutomaticPresentationOnError: true)

            try? await Task.sleep(for: .milliseconds(350))
            guard navigation.isAutomaticLandscapeFullscreen else { return }
            navigation.isAutomaticLandscapeFullscreen = false
            logAutoLandscape("portrait restored; preserving expanded player")
        }
    }

    private func requestInterfaceOrientation(
        _ orientation: UIInterfaceOrientationMask,
        cancelAutomaticPresentationOnError: Bool = false
    ) {
        guard let windowScene = foregroundWindowScene else {
            logAutoLandscape("orientation request cancelled: no foreground window scene")
            if cancelAutomaticPresentationOnError {
                navigation.isAutomaticLandscapeFullscreen = false
            }
            return
        }

        logAutoLandscape("requestGeometryUpdate orientationMask=\(orientation.rawValue)")

        if settings.inAppOrientationLock {
            OrientationManager.shared.lock(to: orientation == .portrait ? .portrait : .landscape)
        }

        for window in windowScene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
            LoggingService.shared.warning(
                "[AutoLandscape] requestGeometryUpdate rejected: \(error.localizedDescription)",
                category: .player
            )
            guard cancelAutomaticPresentationOnError else { return }
            Task { @MainActor in
                navigation.isAutomaticLandscapeFullscreen = false
                if settings.inAppOrientationLock {
                    OrientationManager.shared.lockToCurrentOrientation()
                }
            }
        }
    }

    private func logAutoLandscape(_ message: String) {
        LoggingService.shared.debug("[AutoLandscape] \(message)", category: .player)
    }

    private var foregroundWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
#endif

// MARK: - Preview

#Preview {
    ContentView()
        .appEnvironment(.preview)
}
