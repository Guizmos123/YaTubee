//
//  NotificationSettingsView.swift
//  Yattee
//
//  Settings view for background notifications configuration.
//

import SwiftUI
#if DEBUG && os(iOS)
import UIKit
#endif

struct NotificationSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var authorizationChecked = false

    var body: some View {
        SettingsFormContainer {
            if let settings = appEnvironment?.settingsManager,
               let notificationManager = appEnvironment?.notificationManager {
                // Master toggle section
                EnableSection(
                    settings: settings,
                    notificationManager: notificationManager,
                    appEnvironment: appEnvironment
                )

                // Permission status section
                if authorizationChecked {
                    PermissionSection(notificationManager: notificationManager)
                }

                // Default for new subscriptions
                if settings.backgroundNotificationsEnabled {
                    DefaultsSection(settings: settings)

                    // Manage channels section
                    ManageChannelsSection()
                }

                BadgesSection(settings: settings)

                #if DEBUG
                BadgeDiagnosticSection(appEnvironment: appEnvironment)
                #if os(iOS)
                NotificationPipelineDiagnosticSection(appEnvironment: appEnvironment)
                #endif
                #endif
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.notifications.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await appEnvironment?.notificationManager.refreshAuthorizationStatus()
            authorizationChecked = true
        }
    }
}

#if DEBUG
// MARK: - Notification Pipeline Diagnostic Section

#if os(iOS)
private struct NotificationPipelineDiagnosticSection: View {
    let appEnvironment: AppEnvironment?
    @State private var diagnostic = NotificationPipelineDiagnostic.shared
    @State private var didCopy = false

    var body: some View {
        SettingsFormSection("settings.notifications.diagnostic.title") {
            LabeledContent(
                AppLocalization.string("settings.notifications.diagnostic.registration"),
                value: diagnostic.registrationResult.map {
                    $0
                        ? AppLocalization.string("settings.notifications.diagnostic.status.succeeded")
                        : AppLocalization.string("settings.notifications.diagnostic.status.failed")
                } ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown")
            )

            if diagnostic.pendingRequests.isEmpty {
                LabeledContent(
                    AppLocalization.string("settings.notifications.diagnostic.nextRequest"),
                    value: AppLocalization.string("settings.notifications.diagnostic.noneDetected")
                )
            } else {
                ForEach(diagnostic.pendingRequests, id: \.self) { request in
                    Text(request)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let latest = diagnostic.runs.first {
                runDetails(
                    latest,
                    title: AppLocalization.string("settings.notifications.diagnostic.lastRun")
                )
            } else {
                LabeledContent(
                    AppLocalization.string("settings.notifications.diagnostic.lastRun"),
                    value: AppLocalization.string("settings.notifications.diagnostic.none")
                )
            }

            ForEach(Array(diagnostic.runs.dropFirst())) { run in
                DisclosureGroup("Run \(run.id.uuidString.prefix(8)) · \(run.finalResult ?? AppLocalization.string("settings.notifications.diagnostic.inProgress"))") {
                    runText(run)
                }
            }

            Button {
                UIPasteboard.general.string = diagnostic.textReport
                didCopy = true
            } label: {
                Label(
                    didCopy
                        ? AppLocalization.string("settings.notifications.diagnostic.copied")
                        : AppLocalization.string("settings.notifications.diagnostic.copy"),
                    systemImage: "doc.on.doc"
                )
            }
        }
        .task {
            appEnvironment?.backgroundRefreshManager.refreshPendingTaskDiagnostics()
        }
    }

    @ViewBuilder
    private func runDetails(_ run: NotificationPipelineDiagnostic.Run, title: String) -> some View {
        DisclosureGroup("\(title) · \(run.finalResult ?? AppLocalization.string("settings.notifications.diagnostic.inProgress"))") {
            runText(run)
        }
    }

    private func runText(_ run: NotificationPipelineDiagnostic.Run) -> some View {
        let values = [
            "runID=\(run.id.uuidString)",
            "date=\(run.startedAt.formatted(date: .numeric, time: .standard))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.origin"))=\(run.origin)",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.account"))=\(run.account ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.source"))=\(run.source ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "instance=\(run.instanceID ?? AppLocalization.string("settings.notifications.diagnostic.none"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.authorization"))=\(run.authorizationStatus.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.globalSetting"))=\(run.globalSettingEnabled.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.channels"))=\(run.enabledChannelCount.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "baseline=\(run.hadBaseline.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "feed=\(run.feedResult ?? AppLocalization.string("settings.notifications.diagnostic.notReached"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.videos"))=\(run.feedVideoCount.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.eligible"))=\(run.eligibleCount.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.ignored"))=\(run.ignoredCount.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.deferred"))=\(run.deferredCount.map(String.init) ?? AppLocalization.string("settings.notifications.diagnostic.status.unknown"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.submission"))=\(run.notificationSubmission ?? AppLocalization.string("settings.notifications.diagnostic.notAttempted"))",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.expiration"))=\(run.expired)",
            "\(AppLocalization.string("settings.notifications.diagnostic.field.result"))=\(run.finalResult ?? AppLocalization.string("settings.notifications.diagnostic.inProgress"))"
        ]
        return Text(values.joined(separator: "\n"))
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }
}
#endif

// MARK: - Badge Diagnostic Section

private struct BadgeDiagnosticSection: View {
    let appEnvironment: AppEnvironment?
    @State private var diagnostic = FeedNoveltyBadgeDiagnosticState.shared

    var body: some View {
        SettingsFormSection("settings.badges.diagnostic.title") {
            if diagnostic.isActive {
                LabeledContent(
                    AppLocalization.string("settings.badges.diagnostic.selectedVideos"),
                    value: "\(diagnostic.selectedCount)/10"
                )
                LabeledContent(
                    AppLocalization.string("settings.badges.diagnostic.remainingCount"),
                    value: "\(diagnostic.remainingCount)"
                )

                Button(AppLocalization.string("settings.badges.diagnostic.finish"), role: .destructive) {
                    diagnostic.finish()
                }
            } else {
                Button(AppLocalization.string("settings.badges.diagnostic.start")) {
                    guard let scope = FeedNoveltyScope.active(in: appEnvironment) else { return }
                    diagnostic.start(
                        videos: SubscriptionFeedCache.shared.videos,
                        scope: scope
                    )
                }

                Text(AppLocalization.string("settings.badges.diagnostic.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

// MARK: - Enable Section

private struct EnableSection: View {
    @Bindable var settings: SettingsManager
    let notificationManager: NotificationManager
    let appEnvironment: AppEnvironment?

    var body: some View {
        SettingsFormSection(footer: "settings.notifications.footer") {
            Toggle(
                AppLocalization.string("settings.notifications.enable"),
                isOn: Binding(
                    get: { settings.backgroundNotificationsEnabled },
                    set: { newValue in
                        if newValue {
                            enableNotifications()
                        } else {
                            disableNotifications()
                        }
                    }
                )
            )
        }
    }

    private func enableNotifications() {
        Task {
            let granted = await notificationManager.requestAuthorization()
            if granted {
                settings.backgroundNotificationsEnabled = true
                appEnvironment?.backgroundRefreshManager.handleNotificationsEnabledChanged(true)
            }
        }
    }

    private func disableNotifications() {
        settings.backgroundNotificationsEnabled = false
        appEnvironment?.backgroundRefreshManager.handleNotificationsEnabledChanged(false)
    }
}

// MARK: - Permission Section

private struct PermissionSection: View {
    let notificationManager: NotificationManager

    var body: some View {
        SettingsFormSection {
            HStack {
                Text(AppLocalization.string("settings.notifications.permission"))
                Spacer()
                if notificationManager.isAuthorized {
                    HStack(spacing: 4) {
                        Text(AppLocalization.string("settings.notifications.permission.granted"))
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                } else {
                    Button(AppLocalization.string("settings.notifications.openSettings")) {
                        notificationManager.openNotificationSettings()
                    }
                }
            }
        }
    }
}

// MARK: - Defaults Section

private struct DefaultsSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.notifications.defaults.header", footer: "settings.notifications.defaultForNew.footer") {
            Toggle(
                AppLocalization.string("settings.notifications.defaultForNew"),
                isOn: $settings.defaultNotificationsForNewChannels
            )
            Toggle(
                AppLocalization.string("settings.notifications.includeShorts"),
                isOn: $settings.notificationsIncludeShorts
            )
        }
    }
}

// MARK: - Badges Section

private struct BadgesSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection(
            "settings.badges.header",
            footer: "settings.badges.footer"
        ) {
            Toggle(
                AppLocalization.string("settings.badges.videoTab"),
                isOn: $settings.videoTabBadgeEnabled
            )
            Toggle(
                AppLocalization.string("settings.badges.appIcon"),
                isOn: $settings.appIconBadgeEnabled
            )
            Toggle(
                AppLocalization.string("settings.badges.includeShorts"),
                isOn: $settings.badgesIncludeShorts
            )
            SettingsNavigationRow("settings.badges.manageChannels", systemImage: "person.2") {
                ManageChannelBadgesView()
            }
        }
    }
}

// MARK: - Manage Channel Badges View

private struct ManageChannelBadgesView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var subscriptions: [Subscription] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var preferences = ChannelBadgePreferences.shared

    private var activeScope: FeedNoveltyScope? {
        FeedNoveltyScope.active(in: appEnvironment)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("settings.notifications.loadError.title"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                }
            } else if subscriptions.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("settings.notifications.noSubscriptions.title"),
                        systemImage: "person.2.slash"
                    )
                } description: {
                    Text(AppLocalization.string("settings.notifications.noSubscriptions.description"))
                }
            } else {
                SettingsFormContainer {
                    SettingsFormSection(footer: "settings.badges.manageChannels.footer") {
                        ForEach(subscriptions, id: \.channelID) { subscription in
                            Toggle(isOn: Binding(
                                    get: {
                                        guard let activeScope else { return true }
                                        return preferences.isIncluded(
                                            channelID: subscription.channelID,
                                            in: activeScope
                                        )
                                    },
                                    set: { included in
                                        guard let activeScope else { return }
                                        preferences.setIncluded(
                                            included,
                                            channelID: subscription.channelID,
                                            in: activeScope
                                        )
                                    }
                                )) {
                                HStack(spacing: 10) {
                                    SettingsChannelAvatar(subscription: subscription)
                                    Text(subscription.name)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.badges.manageChannels.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: activeScope?.rawValue) {
            await loadSubscriptions()
        }
    }

    private func loadSubscriptions() async {
        guard let appEnvironment else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if appEnvironment.settingsManager.subscriptionAccount.type == .local {
            subscriptions = appEnvironment.dataManager.subscriptions()
            return
        }

        do {
            let channels = try await appEnvironment.subscriptionService.fetchSubscriptions()
            subscriptions = channels.map { Subscription.from(channel: $0) }
        } catch {
            LoggingService.shared.error(
                "Failed to load subscriptions for badge settings: \(error.localizedDescription)",
                category: .general
            )
            errorMessage = error.localizedDescription
            subscriptions = []
        }
    }
}

// MARK: - Manage Channels Section

private struct ManageChannelsSection: View {
    var body: some View {
        SettingsFormSection {
            #if os(tvOS)
            NavigationLink {
                TVSidebarDetailContainer(
                    systemImage: "bell.badge",
                    title: AppLocalization.string("settings.notifications.manageChannels"),
                    showsDismissButton: true
                ) {
                    ManageChannelNotificationsView()
                }
            } label: {
                Label(
                    AppLocalization.string("settings.notifications.manageChannels"),
                    systemImage: "bell.badge"
                )
            }
            #else
            SettingsNavigationRow("settings.notifications.manageChannels", systemImage: "bell.badge") {
                ManageChannelNotificationsView()
            }
            #endif
        }
    }
}

// MARK: - Manage Channel Notifications View

struct ManageChannelNotificationsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var subscriptions: [Subscription] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshID = UUID()

    private var subscriptionService: SubscriptionService? { appEnvironment?.subscriptionService }

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("settings.notifications.loadError.title"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if subscriptions.isEmpty {
                ContentUnavailableView {
                    Label(
                        AppLocalization.string("settings.notifications.noSubscriptions.title"),
                        systemImage: "person.2.slash"
                    )
                } description: {
                    Text(AppLocalization.string("settings.notifications.noSubscriptions.description"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsFormContainer {
                    SettingsFormSection {
                        ForEach(subscriptions, id: \.channelID) { subscription in
                            ChannelNotificationToggle(subscription: subscription)
                        }
                        .id(refreshID)
                    }
                }
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.notifications.manageChannels.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !subscriptions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            setAllNotifications(enabled: true)
                        } label: {
                            Label(AppLocalization.string("settings.notifications.enableAll"), systemImage: "bell.fill")
                        }
                        Button {
                            setAllNotifications(enabled: false)
                        } label: {
                            Label(AppLocalization.string("settings.notifications.disableAll"), systemImage: "bell.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await loadSubscriptionsAsync()
        }
    }

    private func setAllNotifications(enabled: Bool) {
        guard let dataManager = appEnvironment?.dataManager else { return }
        for subscription in subscriptions {
            dataManager.setNotificationsEnabled(enabled, for: subscription.channelID)
        }
        refreshID = UUID()
    }

    /// Loads subscriptions from the current subscription account provider.
    /// For local accounts, loads from DataManager.
    /// For Invidious/Piped accounts, fetches from the respective API.
    private func loadSubscriptionsAsync() async {
        guard let appEnvironment, let subscriptionService else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // For local account, load from DataManager
        if appEnvironment.settingsManager.subscriptionAccount.type == .local {
            subscriptions = appEnvironment.dataManager.subscriptions()
            return
        }

        // For Invidious/Piped, fetch from service
        do {
            let channels = try await subscriptionService.fetchSubscriptions()
            subscriptions = channels.map { Subscription.from(channel: $0) }
        } catch {
            LoggingService.shared.error(
                "Failed to load subscriptions for notifications: \(error.localizedDescription)",
                category: .general
            )
            errorMessage = error.localizedDescription
            subscriptions = []
        }
    }
}

// MARK: - Channel Notification Toggle

private struct ChannelNotificationToggle: View {
    @Environment(\.appEnvironment) private var appEnvironment
    let subscription: Subscription
    @State private var notificationsEnabled: Bool = false

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { newValue in
                notificationsEnabled = newValue
                appEnvironment?.dataManager.setNotificationsEnabled(newValue, for: subscription.channelID)
            }
        )
    }

    var body: some View {
        Toggle(isOn: toggleBinding) {
            HStack(spacing: 10) {
                SettingsChannelAvatar(subscription: subscription)

                // Channel name
                Text(subscription.name)
                    .lineLimit(1)
            }
        }
        .onAppear {
            // Load initial value from ChannelNotificationSettings
            notificationsEnabled = appEnvironment?.dataManager.notificationsEnabled(for: subscription.channelID) ?? false
        }
    }
}

private struct SettingsChannelAvatar: View {
    @Environment(\.appEnvironment) private var appEnvironment
    let subscription: Subscription

    private var yatteeServer: Instance? {
        appEnvironment?.instancesManager.enabledYatteeServerInstances.first
    }

    private var directURL: URL? {
        guard subscription.avatarURL == nil, let appEnvironment else {
            return subscription.avatarURL
        }
        return CachedChannelData.load(
            for: subscription.channelID,
            using: appEnvironment.dataManager
        )?.thumbnailURL
    }

    private var authHeader: String? {
        guard let yatteeServer else { return nil }
        return appEnvironment?.basicAuthCredentialsManager.basicAuthHeader(for: yatteeServer)
    }

    var body: some View {
        ChannelAvatarView(
            channelID: subscription.channelID,
            name: subscription.name,
            directURL: directURL,
            yatteeServerURL: yatteeServer?.url,
            size: 28,
            authHeader: authHeader,
            source: subscription.contentSource
        )
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
}
