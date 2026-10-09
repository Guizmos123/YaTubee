//
//  ReturnYouTubeDislikeSettingsView.swift
//  Yattee
//
//  Return YouTube Dislike settings.
//

import SwiftUI

struct ReturnYouTubeDislikeSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let settings = appEnvironment?.settingsManager {
                SettingsFormSection(footer: "settings.returnYouTubeDislike.footer") {
                    Toggle(
                        AppLocalization.string("settings.returnYouTubeDislike.enabled"),
                        isOn: Bindable(settings).returnYouTubeDislikeEnabled
                    )
                }

                SettingsFormSection("settings.returnYouTubeDislike.about.header") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalization.string("settings.returnYouTubeDislike.about.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Link(destination: URL(string: "https://returnyoutubedislike.com")!) {
                            HStack {
                                Text(AppLocalization.string("settings.returnYouTubeDislike.learnMore"))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.returnYouTubeDislike.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ReturnYouTubeDislikeSettingsView()
    }
    .appEnvironment(.preview)
}
