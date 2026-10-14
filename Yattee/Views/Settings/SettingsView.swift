//
//  SettingsView.swift
//  Yattee
//
//  Main settings view.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    var showCloseButton: Bool = true

    #if os(macOS)
    @State private var selectedSection: SettingsSection? = .sources
    #endif

    var body: some View {
        #if os(macOS)
        macOSSettings
            .frame(minWidth: 600, minHeight: 520)
        #elseif os(tvOS)
        tvOSSettings
        #else
        iOSSettings
        #endif
    }

    // MARK: - macOS Settings

    #if os(macOS)
    private var macOSSettings: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)

                Divider()
                macOSSidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if appEnvironment != nil {
                NavigationStack {
                    Group {
                        switch selectedSection {
                        case .sources:
                            SourcesListView()
                        case .icloud:
                            iCloudSettingsView()
                        case .appearance:
                            AppearanceSettingsView()
                        case .language:
                            LanguageSettingsView()
                        case .layoutNavigation:
                            LayoutNavigationSettingsView()
                        case .playback:
                            PlaybackSettingsView()
                        case .playerControls:
                            PlayerControlsSettingsView()
                        case .notifications:
                            NotificationSettingsView()
                        case .downloads:
                            DownloadSettingsView()
                        case .privacy:
                            PrivacySettingsView()
                        case .youtubeEnhancements:
                            YouTubeEnhancementsSettingsView()
                        case .advanced:
                            AdvancedSettingsView()
                        case .about:
                            AboutView()
                        case .none:
                            Text(AppLocalization.string("settings.placeholder.selectSection"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                // Covers all section pages and their pushed sub-pages, which
                // otherwise sit on the translucent wallpaper-tinted material.
                .opaqueWindowBackground()
            }
        }
    }

    private var macOSSidebarFooter: some View {
        VStack(spacing: 6) {
            Image("AppIconPreview")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(verbatim: "YaTubee")
                .font(.callout)
                .fontWeight(.semibold)

            Text("\(appVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .allowsHitTesting(false)
    }
    #endif

    // MARK: - tvOS Settings

    #if os(tvOS)
    private var tvOSSettings: some View {
        List {
            if let appEnvironment {
                    NavigationLink {
                        SourcesListView()
                    } label: {
                        HStack {
                            Label(AppLocalization.string("sources.title"), systemImage: "server.rack")
                            Spacer()
                            if appEnvironment.mediaSourcesManager.hasSourcesNeedingPassword {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.row.sources")

                    NavigationLink {
                        TVSidebarDetailContainer(systemImage: "icloud", title: AppLocalization.string("settings.icloud.title")) { iCloudSettingsView() }
                    } label: {
                        HStack {
                            Label(AppLocalization.string("settings.icloud.title"), systemImage: "icloud")
                            #if DEBUG
                            Spacer()
                            Text(AppLocalization.string("settings.icloud.dev.badge"))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                            #endif
                        }
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "paintbrush", title: AppLocalization.string("settings.appearance.sectionTitle")) { AppearanceSettingsView() } } label: {
                        Label(AppLocalization.string("settings.appearance.sectionTitle"), systemImage: "paintbrush")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "globe", title: AppLocalization.string("settings.language.title")) { LanguageSettingsView() } } label: {
                        Label("settings.language.title", systemImage: "globe")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "hand.tap", title: AppLocalization.string("settings.layoutNavigation.title")) { LayoutNavigationSettingsView() } } label: {
                        Label(AppLocalization.string("settings.layoutNavigation.title"), systemImage: "hand.tap")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "rectangle.on.rectangle.angled", title: AppLocalization.string("settings.topShelf.title", defaultValue: "Top Shelf")) { TopShelfSettingsView() } } label: {
                        Label(AppLocalization.string("settings.topShelf.title", defaultValue: "Top Shelf"), systemImage: "rectangle.on.rectangle.angled")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "play.circle", title: AppLocalization.string("settings.playback.sectionTitle")) { PlaybackSettingsView() } } label: {
                        Label(AppLocalization.string("settings.playback.sectionTitle"), systemImage: "play.circle")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "hand.raised", title: AppLocalization.string("settings.privacy.title")) { PrivacySettingsView() } } label: {
                        Label(AppLocalization.string("settings.privacy.title"), systemImage: "hand.raised")
                    }

                    if appEnvironment.instancesManager.enabledInstances.contains(where: \.isYouTubeInstance) {
                        NavigationLink { TVSidebarDetailContainer(systemImage: "puzzlepiece.extension", title: AppLocalization.string("settings.youtubeEnhancements.title")) { YouTubeEnhancementsSettingsView() } } label: {
                            Label(AppLocalization.string("settings.youtubeEnhancements.title"), systemImage: "puzzlepiece.extension")
                        }
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "gearshape.2", title: AppLocalization.string("settings.advanced.title")) { AdvancedSettingsView() } } label: {
                        Label(AppLocalization.string("settings.advanced.title"), systemImage: "gearshape.2")
                    }

                    NavigationLink { TVSidebarDetailContainer(systemImage: "info.circle", title: AppLocalization.string("settings.about.title")) { AboutView() } } label: {
                        Label(AppLocalization.string("settings.about.title"), systemImage: "info.circle")
                    }
                }
            }
            .listStyle(.grouped)
            .safeAreaInset(edge: .leading) {
                VStack(spacing: 20) {
                    Spacer()

                    Image("AppIconPreview")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 46))

                    Text(verbatim: "YaTubee")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("\(appVersion) (\(buildNumber))")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .frame(width: 400)
                .allowsHitTesting(false)
            }
            .accessibilityIdentifier("settings.view")
    }
    #endif

    // MARK: - iOS Settings

    #if os(iOS)
    private var iOSSettings: some View {
        NavigationStack {
            List {
                if let appEnvironment {
                    Section {
                    NavigationLink {
                        SourcesListView()
                    } label: {
                        HStack {
                            Label(AppLocalization.string("sources.title"), systemImage: "server.rack")
                            Spacer()
                            if appEnvironment.mediaSourcesManager.hasSourcesNeedingPassword {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.row.sources")
                    }

                    Section {
                        NavigationLink {
                            iCloudSettingsView()
                        } label: {
                            HStack {
                                Label(AppLocalization.string("settings.icloud.title"), systemImage: "icloud")
                                #if DEBUG
                                Spacer()
                                Text(AppLocalization.string("settings.icloud.dev.badge"))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                                #endif
                            }
                        }

                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.appearance.sectionTitle"), systemImage: "paintbrush")
                        }

                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            Label("settings.language.title", systemImage: "globe")
                        }

                        NavigationLink {
                            LayoutNavigationSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.layoutNavigation.title"), systemImage: "hand.tap")
                        }

                        NavigationLink {
                            PlaybackSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.playback.sectionTitle"), systemImage: "play.circle")
                        }

                        #if os(iOS)
                        NavigationLink {
                            PlayerControlsSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.playerControls.title"), systemImage: "slider.horizontal.below.rectangle")
                        }

                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.notifications.title"), systemImage: "bell.badge")
                        }

                        NavigationLink {
                            DownloadSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.downloads.title"), systemImage: "arrow.down.circle")
                        }
                        #endif

                        NavigationLink {
                            PrivacySettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.privacy.title"), systemImage: "hand.raised")
                        }

                        if appEnvironment.instancesManager.enabledInstances.contains(where: \.isYouTubeInstance) {
                            NavigationLink {
                                YouTubeEnhancementsSettingsView()
                            } label: {
                                Label(AppLocalization.string("settings.youtubeEnhancements.title"), systemImage: "puzzlepiece.extension")
                            }
                        }

                        NavigationLink {
                            AdvancedSettingsView()
                        } label: {
                            Label(AppLocalization.string("settings.advanced.title"), systemImage: "gearshape.2")
                        }
                    }

                    Section {
                        NavigationLink {
                            AboutView()
                        } label: {
                            Label(AppLocalization.string("settings.about.title"), systemImage: "info.circle")
                        }
                    }

                }
            }
            .reactiveNavigationTitle(AppLocalization.string("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showCloseButton {
                    sheetCloseToolbarItem(identifier: "settings.doneButton") { dismiss() }
                }
            }
            .accessibilityIdentifier("settings.view")
        }
    }
    #endif

    // MARK: - App Info

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}

private struct ReactiveNavigationTitleModifier: ViewModifier {
    @Environment(\.appEnvironment) private var appEnvironment

    let title: () -> String

    func body(content: Content) -> some View {
        let language = appEnvironment?.settingsManager.appLanguage ?? .english
        content.navigationTitle(resolvedTitle(for: language))
    }

    private func resolvedTitle(for language: AppLanguage) -> String {
        switch language {
        case .english, .french:
            title()
        }
    }
}

extension View {
    func reactiveNavigationTitle(_ title: @autoclosure @escaping () -> String) -> some View {
        modifier(ReactiveNavigationTitleModifier(title: title))
    }
}

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case sources
    case icloud
    case appearance
    case language
    case layoutNavigation
    case playback
    case playerControls
    case notifications
    case downloads
    case privacy
    case youtubeEnhancements
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return AppLocalization.string("sources.title")
        case .icloud: return AppLocalization.string("settings.icloud.title")
        case .appearance: return AppLocalization.string("settings.appearance.sectionTitle")
        case .language: return AppLocalization.string("settings.language.title")
        case .layoutNavigation: return AppLocalization.string("settings.layoutNavigation.title")
        case .playback: return AppLocalization.string("settings.playback.sectionTitle")
        case .playerControls: return AppLocalization.string("settings.playerControls.title")
        case .notifications: return AppLocalization.string("settings.notifications.title")
        case .downloads: return AppLocalization.string("settings.downloads.title")
        case .privacy: return AppLocalization.string("settings.privacy.title")
        case .youtubeEnhancements: return AppLocalization.string("settings.youtubeEnhancements.title")
        case .advanced: return AppLocalization.string("settings.advanced.title")
        case .about: return AppLocalization.string("settings.about.title")
        }
    }

    var icon: String {
        switch self {
        case .sources: return "server.rack"
        case .icloud: return "icloud"
        case .appearance: return "paintbrush"
        case .language: return "globe"
        case .layoutNavigation: return "hand.tap"
        case .playback: return "play.circle"
        case .playerControls: return "slider.horizontal.below.rectangle"
        case .notifications: return "bell.badge"
        case .downloads: return "arrow.down.circle"
        case .privacy: return "hand.raised"
        case .youtubeEnhancements: return "puzzlepiece.extension"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        }
    }
}

private struct LanguageSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let settings = appEnvironment?.settingsManager {
                SettingsFormSection(footer: "settings.language.footer") {
                    Picker("settings.language.title", selection: Bindable(settings).appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.language.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    SettingsView()
        .appEnvironment(.preview)
}
