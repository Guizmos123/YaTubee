//
//  NotificationManager.swift
//  Yattee
//
//  Local notification management for new video alerts.
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages local notifications for new video alerts.
@MainActor
@Observable
final class NotificationManager: NSObject {
    // MARK: - Constants

    private static let notificationCategoryIdentifier = "NEW_VIDEO"
    private static let watchActionIdentifier = "WATCH_ACTION"
    static let notificationAuthorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    // MARK: - State

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var isAuthorized: Bool {
        Self.permitsNotificationSubmission(authorizationStatus)
    }

    /// Whether iOS permits this app to submit presentable local notifications.
    static func permitsNotificationSubmission(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    /// UserDefaults key for pending navigation flag.
    private nonisolated static let pendingNavigationKey = "pendingSubscriptionsNavigation"

    // MARK: - Initialization

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Authorization

    /// Requests notification authorization from the user.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: Self.notificationAuthorizationOptions
            )
            await refreshAuthorizationStatus()
            LoggingService.shared.info("Notification authorization: \(granted ? "granted" : "denied")", category: .notifications)
            return granted
        } catch {
            LoggingService.shared.logNotificationError("Failed to request notification authorization", error: error)
            return false
        }
    }

    /// Refreshes the current authorization status.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Opens system settings for notification permissions.
    func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    #if !os(tvOS)
    // MARK: - Notification Scheduling

    /// Sends a single combined notification for new videos.
    @discardableResult
    func sendNotification(
        for videos: [(video: Video, channelName: String)],
        appIconBadgeCount: Int?,
        diagnosticRunID: UUID? = nil
    ) async -> Bool {
        await refreshAuthorizationStatus()

        guard isAuthorized else {
            LoggingService.shared.debug("Skipping notification: not authorized", category: .notifications)
            #if DEBUG
            if let diagnosticRunID {
                NotificationPipelineDiagnostic.shared.recordSubmission("rejected:notAuthorized", runID: diagnosticRunID)
            }
            #endif
            return false
        }

        guard !videos.isEmpty else { return false }

        let content = Self.notificationContent(
            for: videos,
            appIconBadgeCount: appIconBadgeCount
        )

        let request = UNNotificationRequest(
            identifier: "feed-update-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            let uniqueChannels = Set(videos.map { $0.channelName }).count
            LoggingService.shared.info("Sent notification for \(videos.count) videos from \(uniqueChannels) channels", category: .notifications)
            #if DEBUG
            if let diagnosticRunID {
                NotificationPipelineDiagnostic.shared.recordSubmission("accepted", runID: diagnosticRunID)
            }
            #endif
            return true
        } catch {
            LoggingService.shared.logNotificationError("Failed to schedule notification", error: error)
            #if DEBUG
            if let diagnosticRunID {
                NotificationPipelineDiagnostic.shared.recordSubmission(
                    "error:\(String(describing: type(of: error)))",
                    runID: diagnosticRunID
                )
            }
            #endif
            return false
        }
    }

    static func notificationContent(
        for videos: [(video: Video, channelName: String)],
        appIconBadgeCount: Int?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = notificationCategoryIdentifier
        if let appIconBadgeCount {
            content.badge = NSNumber(value: max(0, appIconBadgeCount))
        }

        let totalCount = videos.count

        if totalCount == 1 {
            // Single video: "Channel Name" / "New video: Title"
            let video = videos[0].video
            let channelName = videos[0].channelName
            content.title = channelName
            content.body = localizedFormat("notification.singleVideo %@", video.title)
        } else if totalCount <= 3 {
            // 2-3 videos: List each video as "Author: Title" on separate lines
            content.title = AppLocalization.string("notification.newVideos.title")
            let videoLines = videos.map { item in
                localizedFormat(
                    "notification.videoItem %@ %@",
                    item.channelName,
                    item.video.title
                )
            }
            content.body = videoLines.joined(separator: "\n")
        } else {
            // 4+ videos: Group by channel
            let groupedByChannel = Dictionary(grouping: videos) { $0.channelName }
            let channelCount = groupedByChannel.count

            if channelCount == 1, let (channelName, channelVideos) = groupedByChannel.first {
                // Multiple videos from one channel: "4 new videos from X"
                content.title = AppLocalization.string("notification.newVideos.title")
                content.body = localizedFormat(
                    "notification.multipleVideosOneChannel %lld %@",
                    channelVideos.count,
                    channelName
                )
            } else {
                // Multiple channels
                content.title = AppLocalization.string("notification.newVideos.title")

                let channelNames = groupedByChannel
                    .sorted { $0.value.count > $1.value.count }
                    .map { $0.key }

                if channelNames.count == 2 {
                    content.body = localizedFormat(
                        "notification.twoChannels %@ %@",
                        channelNames[0],
                        channelNames[1]
                    )
                } else {
                    let allButLast = channelNames.dropLast().joined(separator: ", ")
                    let last = channelNames.last ?? ""
                    content.body = localizedFormat(
                        "notification.multipleChannels %@ %@",
                        allButLast,
                        last
                    )
                }
            }
        }

        return content
    }

    // MARK: - Debug / Testing

    /// Sends a test notification to verify notification permissions and appearance.
    func sendTestNotification() async {
        await refreshAuthorizationStatus()

        guard isAuthorized else {
            LoggingService.shared.warning("Cannot send test notification: not authorized", category: .notifications)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Test Channel"
        content.body = Self.localizedFormat("notification.singleVideo %@", "Test Video Title")
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: "test-notification-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            LoggingService.shared.info("Sent test notification", category: .notifications)
        } catch {
            LoggingService.shared.logNotificationError("Failed to send test notification", error: error)
        }
    }

    /// Triggers a real background refresh check manually (for debugging).
    /// Performs an actual API fetch like the real background refresh does.
    func triggerBackgroundRefresh(using appEnvironment: AppEnvironment) async {
        LoggingService.shared.info("Manual background refresh triggered - performing real API fetch", category: .notifications)

        let refresher = BackgroundFeedRefresher(notificationManager: self)
        refresher.setAppEnvironment(appEnvironment)
        await refresher.performBackgroundRefresh(origin: "manualDebug")

        LoggingService.shared.info("Manual background refresh completed", category: .notifications)
    }

    // MARK: - Category Registration

    func registerNotificationCategories() {
        let watchAction = UNNotificationAction(
            identifier: Self.watchActionIdentifier,
            title: AppLocalization.string("notification.action.watch"),
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryIdentifier,
            actions: [watchAction],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private static func localizedFormat(
        _ key: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: AppLocalization.string(key),
            locale: AppLocalization.selectedLocale,
            arguments: arguments
        )
    }
    #endif
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground
        completionHandler([.banner, .sound])
    }

    #if !os(tvOS)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Set flag in UserDefaults - completely thread-safe
        UserDefaults.standard.set(true, forKey: Self.pendingNavigationKey)
        completionHandler()
    }

    /// Handles pending navigation if any. Call this when the app becomes active.
    func handlePendingNavigation(using coordinator: NavigationCoordinator) {
        guard UserDefaults.standard.bool(forKey: Self.pendingNavigationKey) else { return }
        UserDefaults.standard.set(false, forKey: Self.pendingNavigationKey)
        coordinator.navigateToSubscriptions()
    }
    #endif
}
