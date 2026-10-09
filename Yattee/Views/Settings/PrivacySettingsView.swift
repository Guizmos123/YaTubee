//
//  PrivacySettingsView.swift
//  Yattee
//
//  Privacy settings including incognito mode and history retention.
//

import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    private let historyRetentionOptions: [Int] = [0, 30, 60, 90, 180, 365]
    private let searchHistoryLimitOptions: [Int] = [10, 15, 25, 50, 100]

    var body: some View {
        SettingsFormContainer {
            incognitoSection
            historySection
            searchSection
        }
        #if !os(tvOS)
        .reactiveNavigationTitle(AppLocalization.string("settings.privacy.title"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private var incognitoSection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection(footer: "settings.privacy.incognito.footer") {
                Toggle(isOn: Bindable(settingsManager).incognitoModeEnabled) {
                    Label {
                        Text(AppLocalization.string("settings.behavior.incognitoMode"))
                    } icon: {
                        #if os(macOS)
                        Image("incognito")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        #else
                        Image("incognito")
                        #endif
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection("settings.behavior.historyRetention.header", footer: "settings.behavior.historyRetention.footer") {
                Toggle(
                    AppLocalization.string("settings.privacy.saveWatchHistory"),
                    isOn: Bindable(settingsManager).saveWatchHistory
                )

                PlatformMenuPicker(
                    AppLocalization.string("settings.behavior.historyRetention"),
                    selection: Binding(
                        get: { settingsManager.historyRetentionDays },
                        set: { settingsManager.historyRetentionDays = $0 }
                    )
                ) {
                    ForEach(historyRetentionOptions, id: \.self) { days in
                        Text(labelForHistoryRetentionDays(days))
                            .tag(days)
                    }
                }
            }
        }
    }

    private func labelForHistoryRetentionDays(_ days: Int) -> String {
        switch days {
        case 0:
            return AppLocalization.string("settings.behavior.historyRetention.never")
        case 365:
            return AppLocalization.string("settings.behavior.historyRetention.year")
        default:
            return AppLocalization.string("settings.behavior.historyRetention.days \(days)")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection("settings.behavior.searchHistoryLimit.header", footer: "settings.behavior.searchHistoryLimit.footer") {
                Toggle(
                    AppLocalization.string("settings.privacy.saveRecentSearches"),
                    isOn: Bindable(settingsManager).saveRecentSearches
                )

                Toggle(
                    AppLocalization.string("settings.privacy.saveRecentChannels"),
                    isOn: Bindable(settingsManager).saveRecentChannels
                )

                Toggle(
                    AppLocalization.string("settings.privacy.saveRecentPlaylists"),
                    isOn: Bindable(settingsManager).saveRecentPlaylists
                )

                PlatformMenuPicker(
                    AppLocalization.string("settings.behavior.searchHistoryLimit"),
                    selection: Binding(
                        get: { settingsManager.searchHistoryLimit },
                        set: { settingsManager.searchHistoryLimit = $0 }
                    )
                ) {
                    ForEach(searchHistoryLimitOptions, id: \.self) { limit in
                        Text(AppLocalization.string("settings.behavior.searchHistoryLimit.queries \(limit)"))
                            .tag(limit)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
    .appEnvironment(.preview)
}
