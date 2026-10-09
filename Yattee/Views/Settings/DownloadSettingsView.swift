//
//  DownloadSettingsView.swift
//  Yattee
//
//  Settings view for download configuration.
//

import SwiftUI

#if !os(tvOS)
struct DownloadSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let downloadSettings = appEnvironment?.downloadSettings,
               let downloadManager = appEnvironment?.downloadManager {
                StorageSection(downloadManager: downloadManager)
                QualitySection(downloadSettings: downloadSettings)
                ConcurrencySection(downloadSettings: downloadSettings)
                #if os(iOS)
                CellularSection(
                    downloadSettings: downloadSettings,
                    downloadManager: downloadManager
                )
                #endif
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.downloads.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Storage Section

private struct StorageSection: View {
    let downloadManager: DownloadManager

    private var storageUsed: Int64 {
        downloadManager.storageUsed
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        SettingsFormSection {
            #if os(iOS)
            NavigationLink {
                DownloadsStorageView()
            } label: {
                HStack {
                    Text(AppLocalization.string("settings.downloads.usedStorage"))
                    Spacer()
                    Text(formatBytes(storageUsed))
                        .foregroundStyle(.secondary)
                }
            }
            #else
            SettingsNavigationRow(
                "settings.downloads.usedStorage",
                systemImage: "internaldrive",
                trailing: { Text(formatBytes(storageUsed)) }
            ) {
                DownloadsStorageView()
            }
            #endif
        }
    }
}

// MARK: - Quality Section

private struct QualitySection: View {
    @Bindable var downloadSettings: DownloadSettings

    var body: some View {
        SettingsFormSection("settings.downloads.quality.header") {
            Picker(
                AppLocalization.string("settings.downloads.preferredQuality"),
                selection: $downloadSettings.preferredDownloadQuality
            ) {
                ForEach(DownloadQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }

            if downloadSettings.preferredDownloadQuality != .ask {
                Toggle(
                    AppLocalization.string("settings.downloads.includeSubtitles"),
                    isOn: $downloadSettings.includeSubtitlesInAutoDownload
                )
            }
        } footer: {
            if downloadSettings.preferredDownloadQuality == .ask {
                Text(AppLocalization.string("settings.downloads.quality.ask.footer"))
            } else {
                Text(AppLocalization.string("settings.downloads.quality.auto.footer"))
            }
        }
    }
}

// MARK: - Concurrency Section

private struct ConcurrencySection: View {
    @Bindable var downloadSettings: DownloadSettings

    var body: some View {
        SettingsFormSection {
            #if os(iOS)
            Stepper(value: $downloadSettings.maxConcurrentDownloads, in: 1...5) {
                HStack {
                    Text(AppLocalization.string("settings.downloads.maxConcurrent"))
                    Spacer()
                    Text("\(downloadSettings.maxConcurrentDownloads)")
                        .foregroundStyle(.secondary)
                }
            }
            #else
            Stepper(
                "\(AppLocalization.string("settings.downloads.maxConcurrent")): \(downloadSettings.maxConcurrentDownloads)",
                value: $downloadSettings.maxConcurrentDownloads,
                in: 1...5
            )
            #endif
        }
    }
}

// MARK: - Cellular Section

#if os(iOS)
private struct CellularSection: View {
    @Bindable var downloadSettings: DownloadSettings
    let downloadManager: DownloadManager?

    var body: some View {
        SettingsFormSection(footer: "settings.downloads.allowCellular.footer") {
            Toggle(
                AppLocalization.string("settings.downloads.allowCellular"),
                isOn: $downloadSettings.allowCellularDownloads
            )
            .onChange(of: downloadSettings.allowCellularDownloads) {
                downloadManager?.refreshCellularAccessSetting()
            }
        }
    }
}
#endif

#Preview {
    NavigationStack {
        DownloadSettingsView()
    }
    .appEnvironment(.preview)
}
#endif
