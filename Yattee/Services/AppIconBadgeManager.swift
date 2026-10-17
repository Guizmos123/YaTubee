//
//  AppIconBadgeManager.swift
//  Yattee
//
//  Manages iOS badge authorization and mirrors the Feed novelty count.
//

import Foundation
#if os(iOS)
import Observation
import UserNotifications

enum AppIconBadgeAuthorizationState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

protocol AppIconBadgeProviding: Sendable {
    func authorizationState() async -> AppIconBadgeAuthorizationState
    func requestBadgeAuthorization() async throws -> Bool
    func setBadgeCount(_ count: Int) async throws
}

final class SystemAppIconBadgeProvider: AppIconBadgeProviding, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> AppIconBadgeAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.authorizationState(
            status: settings.authorizationStatus,
            badgeSetting: settings.badgeSetting
        )
    }

    static func authorizationState(
        status: UNAuthorizationStatus,
        badgeSetting: UNNotificationSetting
    ) -> AppIconBadgeAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return badgeSetting == .enabled ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    func requestBadgeAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.badge])
    }

    func setBadgeCount(_ count: Int) async throws {
        try await center.setBadgeCount(max(0, count))
    }
}

@MainActor
@Observable
final class AppIconBadgeManager {
    static let shared = AppIconBadgeManager(provider: SystemAppIconBadgeProvider())

    private let provider: any AppIconBadgeProviding
    private(set) var authorizationState: AppIconBadgeAuthorizationState?
    private var isEnabled = false

    init(provider: any AppIconBadgeProviding) {
        self.provider = provider
    }

    /// The only path that may display the system permission prompt.
    @discardableResult
    func enable(count: Int) async -> Bool {
        isEnabled = true
        var state = await provider.authorizationState()
        guard isEnabled else { return false }

        if state == .notDetermined {
            let granted = (try? await provider.requestBadgeAuthorization()) == true
            state = granted ? .authorized : .denied
        }

        guard isEnabled else { return false }
        authorizationState = state
        await apply(count: count, enabled: true)
        return state == .authorized
    }

    /// Applies a changed count without displaying an authorization prompt.
    func apply(count: Int, enabled: Bool) async {
        guard enabled else {
            isEnabled = false
            do {
                try await provider.setBadgeCount(0)
            } catch {
                LoggingService.shared.logNotificationError("Failed to clear app icon badge", error: error)
            }
            return
        }

        guard isEnabled, authorizationState == .authorized else { return }
        do {
            try await provider.setBadgeCount(max(0, count))
        } catch {
            LoggingService.shared.logNotificationError("Failed to update app icon badge", error: error)
        }
    }

    /// Re-reads the real system setting after launch or returning from Settings.
    @discardableResult
    func reconcile(count: Int, enabled: Bool) async -> Bool {
        guard enabled else {
            isEnabled = false
            authorizationState = nil
            await apply(count: 0, enabled: false)
            return true
        }

        isEnabled = true
        let state = await provider.authorizationState()
        guard isEnabled else { return false }
        authorizationState = state
        await apply(count: count, enabled: true)
        return state == .authorized
    }

    /// Refreshes status for settings UI without requesting permission or changing the badge.
    @discardableResult
    func refreshAuthorizationState() async -> AppIconBadgeAuthorizationState {
        let state = await provider.authorizationState()
        authorizationState = state
        return state
    }
}
#endif
