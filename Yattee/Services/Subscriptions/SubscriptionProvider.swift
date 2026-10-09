//
//  SubscriptionProvider.swift
//  Yattee
//
//  Protocol defining subscription management operations.
//  Implementations handle different subscription sources (local, Invidious, Piped).
//

import Foundation

/// Protocol for subscription management providers.
/// Each provider implementation handles a specific subscription source.
@MainActor
protocol SubscriptionProvider: Sendable {
    /// The type of subscription account this provider handles.
    var accountType: SubscriptionAccountType { get }

    /// Fetches all subscriptions from the provider.
    /// - Returns: Array of channels the user is subscribed to.
    func fetchSubscriptions() async throws -> [Channel]

    /// Subscribes to a channel.
    /// - Parameter channel: The channel to subscribe to.
    func subscribe(to channel: Channel) async throws

    /// Unsubscribes from a channel.
    /// - Parameter channelID: The channel ID to unsubscribe from.
    func unsubscribe(from channelID: String) async throws

    /// Checks if subscribed to a channel.
    /// - Parameter channelID: The channel ID to check.
    /// - Returns: `true` if subscribed, `false` otherwise.
    func isSubscribed(to channelID: String) async -> Bool

    /// The subscription count known without a network fetch.
    /// Returns nil when the provider hasn't populated its cache yet.
    var cachedSubscriptionCount: Int? { get }

    /// Refreshes the local cache of subscriptions from the remote source.
    /// For local provider, this is a no-op.
    func refreshCache() async throws
}

// MARK: - Default Implementations

extension SubscriptionProvider {
    /// Default implementation for providers that don't need cache refresh.
    func refreshCache() async throws {
        // No-op by default
    }
}

// MARK: - Subscription Provider Error

/// Errors that can occur during subscription provider operations.
enum SubscriptionProviderError: Error, LocalizedError, Equatable, Sendable {
    case notAuthenticated
    case networkError(String)
    case channelNotFound
    case alreadySubscribed
    case notSubscribed
    case instanceNotConfigured
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return AppLocalization.string("subscription.error.notAuthenticated")
        case .networkError(let message):
            return AppLocalization.string("subscription.error.network \(message)")
        case .channelNotFound:
            return AppLocalization.string("subscription.error.channelNotFound")
        case .alreadySubscribed:
            return AppLocalization.string("subscription.error.alreadySubscribed")
        case .notSubscribed:
            return AppLocalization.string("subscription.error.notSubscribed")
        case .instanceNotConfigured:
            return AppLocalization.string("subscription.error.instanceNotConfigured")
        case .operationFailed(let message):
            return AppLocalization.string("subscription.error.operationFailed \(message)")
        }
    }
}
