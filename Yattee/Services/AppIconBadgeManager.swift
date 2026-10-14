//
//  AppIconBadgeManager.swift
//  Yattee
//
//  Synchronizes the real feed novelty count with the iOS app icon badge.
//

import Foundation
#if os(iOS)
import UserNotifications

struct AppIconBadgeSynchronizationKey: Hashable, Sendable {
    let scopeRawValue: String?
    let realNoveltyCount: Int
    let isEnabled: Bool
    let isSceneActive: Bool
}

protocol AppIconBadgeCenter: Sendable {
    func badgeSetting() async -> UNNotificationSetting
    func setBadgeCount(_ count: Int) async throws
}

struct SystemAppIconBadgeCenter: AppIconBadgeCenter {
    func badgeSetting() async -> UNNotificationSetting {
        await UNUserNotificationCenter.current().notificationSettings().badgeSetting
    }

    func setBadgeCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

actor AppIconBadgeManager {
    static let shared = AppIconBadgeManager(center: SystemAppIconBadgeCenter())

    private let center: any AppIconBadgeCenter
    private var lastAppliedCount: Int?

    init(center: any AppIconBadgeCenter) {
        self.center = center
    }

    func synchronize(realNoveltyCount: Int, isEnabled: Bool) async {
        let desiredCount = isEnabled ? max(0, realNoveltyCount) : 0
        let badgeSetting = await center.badgeSetting()

        guard badgeSetting == .enabled else {
            LoggingService.shared.debug(
                "App icon badge not updated: badge setting is \(badgeSetting.rawValue)",
                category: .notifications
            )
            return
        }
        guard lastAppliedCount != desiredCount else { return }

        do {
            try await center.setBadgeCount(desiredCount)
            lastAppliedCount = desiredCount
            LoggingService.shared.debug(
                "App icon badge updated | count: \(desiredCount)",
                category: .notifications
            )
        } catch {
            LoggingService.shared.logNotificationError("Failed to update app icon badge", error: error)
        }
    }
}
#endif
