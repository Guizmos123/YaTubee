//
//  LayoutNavigationSettingsView.swift
//  Yattee
//
//  Settings view for layout and navigation customization.
//

import SwiftUI

struct LayoutNavigationSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let settings = appEnvironment?.settingsManager {
                CustomizationSection()
                #if os(iOS)
                HapticsSection(settings: settings)
                #endif
                #if os(tvOS)
                TVVideoActionsSection(settings: settings)
                #else
                VideoActionsSection(settings: settings)
                LinkActionSection(settings: settings)
                ClipboardSection(settings: settings)
                #endif
                #if os(iOS)
                if #available(iOS 26, *) {
                    TabBarMinimizeBehaviorSection(settings: settings)
                }
                #endif
                #if !os(tvOS)
                HandoffSection(settings: settings)
                #endif
            }
        }
        #if !os(tvOS)
        .reactiveNavigationTitle(AppLocalization.string("settings.layoutNavigation.title"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Haptics Section

#if os(iOS)
private struct HapticsSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        if SettingsManager.deviceSupportsHaptics {
            SettingsFormSection {
                Toggle(
                    AppLocalization.string("settings.haptics.title"),
                    isOn: $settings.hapticFeedbackEnabled
                )

                if settings.hapticFeedbackEnabled {
                    Picker(
                        AppLocalization.string("settings.haptics.intensity"),
                        selection: $settings.hapticFeedbackIntensity
                    ) {
                        ForEach(HapticFeedbackIntensity.allCases.filter { $0 != .off }, id: \.self) { intensity in
                            Text(intensity.displayName).tag(intensity)
                        }
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Customization Section

private struct CustomizationSection: View {
    var body: some View {
        SettingsFormSection {
            #if os(tvOS)
            NavigationLink {
                TVSidebarDetailContainer(
                    systemImage: SidebarItem.home.systemImage,
                    title: AppLocalization.string("settings.appearance.home.customize")
                ) { HomeSettingsView() }
            } label: {
                Label(AppLocalization.string("settings.appearance.home.customize"), systemImage: SidebarItem.home.systemImage)
            }
            #else
            SettingsNavigationRow("settings.appearance.home.customize", systemImage: SidebarItem.home.systemImage) {
                HomeSettingsView()
            }
            #endif

            #if os(iOS)
            SettingsNavigationRow("settings.tabBar.title", systemImage: "square.grid.3x3") {
                TabBarSettingsView()
            }

            // Sidebar settings only on iPad (not iPhone)
            if UIDevice.current.userInterfaceIdiom == .pad {
                SettingsNavigationRow("settings.sidebar.title", systemImage: "sidebar.leading") {
                    SidebarSettingsView()
                }
            }
            #endif

            #if os(macOS)
            SettingsNavigationRow("settings.sidebar.title", systemImage: "sidebar.leading") {
                SidebarSettingsView()
            }
            #elseif os(tvOS)
            NavigationLink {
                TVSidebarDetailContainer(
                    systemImage: "sidebar.leading",
                    title: AppLocalization.string("settings.sidebar.title")
                ) { SidebarSettingsView() }
            } label: {
                Label(AppLocalization.string("settings.sidebar.title"), systemImage: "sidebar.leading")
            }
            #endif
        }
    }
}

// MARK: - Link Action Section

private struct LinkActionSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.behavior.linkAction.header", footer: "settings.behavior.linkAction.footer") {
            Picker(
                AppLocalization.string("settings.behavior.linkAction"),
                selection: $settings.defaultLinkAction
            ) {
                ForEach(DefaultLinkAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
        }
    }
}

// MARK: - Clipboard Section

private struct ClipboardSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.dataPrivacy.clipboard.header", footer: "settings.behavior.clipboardMonitoring.footer") {
            Toggle(
                AppLocalization.string("settings.behavior.clipboardMonitoring"),
                isOn: $settings.clipboardURLDetectionEnabled
            )
        }
    }
}

// MARK: - Video Actions Section

#if !os(tvOS)
private struct VideoActionsSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.videoActions.header") {
            Picker(
                AppLocalization.string("settings.behavior.thumbnailTapAction"),
                selection: $settings.thumbnailTapAction
            ) {
                ForEach(VideoTapAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }

            Picker(
                AppLocalization.string("settings.behavior.textAreaTapAction"),
                selection: $settings.textAreaTapAction
            ) {
                ForEach(VideoTapAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }

            #if os(iOS)
            NavigationLink {
                SwipeActionsSettingsView()
            } label: {
                Label(AppLocalization.string("settings.appearance.swipeActions"), systemImage: "hand.draw")
            }
            #endif
        }
    }
}
#endif

// MARK: - TV Video Actions Section

#if os(tvOS)
private struct TVVideoActionsSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.videoActions.header") {
            LabeledContent(AppLocalization.string("settings.behavior.tvOSVideoTapAction")) {
                Picker(
                    AppLocalization.string("settings.behavior.tvOSVideoTapAction"),
                    selection: $settings.tvOSVideoTapAction
                ) {
                    Text(VideoTapAction.openInfo.displayName).tag(VideoTapAction.openInfo)
                    Text(VideoTapAction.playVideo.displayName).tag(VideoTapAction.playVideo)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }
}
#endif

// MARK: - Tab Bar Minimize Behavior Section (iOS 26+)

#if os(iOS)
@available(iOS 26, *)
private struct TabBarMinimizeBehaviorSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection(footer: "settings.behavior.miniPlayer.minimizeBehavior.footer") {
            Toggle(
                AppLocalization.string("settings.behavior.miniPlayer.minimizeBehavior"),
                isOn: Binding(
                    get: { settings.miniPlayerMinimizeBehavior == .onScrollDown },
                    set: { settings.miniPlayerMinimizeBehavior = $0 ? .onScrollDown : .never }
                )
            )
        }
    }
}
#endif

// MARK: - Handoff Section

private struct HandoffSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.behavior.handoff.header", footer: "settings.behavior.handoff.footer") {
            Toggle(
                AppLocalization.string("settings.behavior.handoff"),
                isOn: $settings.handoffEnabled
            )
        }
    }
}

#Preview {
    NavigationStack {
        LayoutNavigationSettingsView()
    }
    .appEnvironment(.preview)
}
