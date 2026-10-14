//
//  AppStartupCoordinatorTests.swift
//  YatteeTests
//
//  Tests safe persistent-storage startup and retry behavior.
//

import Foundation
import SwiftData
import Testing
@testable import Yattee

@MainActor
@Suite("App Startup Coordinator")
struct AppStartupCoordinatorTests {
    private enum TestError: Error {
        case unavailable
    }

    @Test("Successful startup constructs services once")
    func successfulStartup() async throws {
        var dataManagerAttempts = 0
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: {
                dataManagerAttempts += 1
                return try DataManager(inMemory: true)
            },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        #expect(coordinator.readyEnvironment != nil)
        #expect(dataManagerAttempts == 1)
        #expect(environmentConstructions.value == 1)
    }

    @Test("Storage failure does not construct dependent services")
    func failedStartupDoesNotConstructEnvironment() async {
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: { throw TestError.unavailable },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        guard case .failed = coordinator.state else {
            Issue.record("Expected failed startup state")
            return
        }
        #expect(environmentConstructions.value == 0)
        #expect(coordinator.readyEnvironment == nil)
    }

    @Test("A retry can recover after an opening failure")
    func failedStartupThenSuccessfulRetry() async {
        var attempts = 0
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: {
                attempts += 1
                if attempts == 1 { throw TestError.unavailable }
                return try DataManager(inMemory: true)
            },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()
        guard case .failed = coordinator.state else {
            Issue.record("Expected the first attempt to fail")
            return
        }

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        #expect(coordinator.readyEnvironment != nil)
        #expect(attempts == 2)
        #expect(environmentConstructions.value == 1)
    }

    @Test("Repeated failures remain retryable without services")
    func repeatedFailures() async {
        var attempts = 0
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: {
                attempts += 1
                throw TestError.unavailable
            },
            environmentConstructions: environmentConstructions
        )

        for _ in 0..<3 {
            coordinator.startOrRetry()
            await coordinator.waitForCurrentAttempt()
            guard case .failed = coordinator.state else {
                Issue.record("Expected failed startup state")
                return
            }
        }

        #expect(attempts == 3)
        #expect(environmentConstructions.value == 0)
    }

    @Test("Double retry starts only one SwiftData attempt")
    func doubleRetryDoesNotStartTwice() async {
        var attempts = 0
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: {
                attempts += 1
                throw TestError.unavailable
            },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        #expect(attempts == 1)
        #expect(environmentConstructions.value == 0)
    }

    @Test("Production failure never substitutes an in-memory manager")
    func noInMemoryFallbackAfterFailure() async {
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: { throw TestError.unavailable },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        #expect(coordinator.readyEnvironment == nil)
        #expect(environmentConstructions.value == 0)
    }

    @Test("Retry preserves an isolated persistent store")
    func retryPreservesPersistentStore() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yatubee-startup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storeURL = directoryURL.appendingPathComponent("startup.store")
        let configuration = ModelConfiguration(
            "StartupPreservation",
            schema: DataManager.schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        var initialManager: DataManager? = try DataManager(configuration: configuration)
        initialManager?.addSearchQuery("preserve-me")
        initialManager?.save()
        initialManager = nil

        var attempts = 0
        let environmentConstructions = Counter()
        let coordinator = makeCoordinator(
            dataManagerFactory: {
                attempts += 1
                if attempts == 1 { throw TestError.unavailable }
                return try DataManager(configuration: configuration)
            },
            environmentConstructions: environmentConstructions
        )

        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()
        coordinator.startOrRetry()
        await coordinator.waitForCurrentAttempt()

        let history = coordinator.readyEnvironment?.dataManager.fetchSearchHistory(limit: 10)
        #expect(history?.contains(where: { $0.query == "preserve-me" }) == true)
        #expect(environmentConstructions.value == 1)
    }

    @Test("Preview manager remains explicitly in memory")
    func previewCompatibility() throws {
        let manager = try DataManager.preview()
        manager.addSearchQuery("preview-only")
        #expect(manager.fetchSearchHistory(limit: 10).count == 1)
    }

    private func makeCoordinator(
        dataManagerFactory: @escaping AppStartupCoordinator.DataManagerFactory,
        environmentConstructions: Counter
    ) -> AppStartupCoordinator {
        return AppStartupCoordinator(
            dataManagerFactory: dataManagerFactory,
            environmentFactory: { dataManager, notificationManager, backgroundRefreshManager in
                environmentConstructions.value += 1
                return AppEnvironment(
                    dataManager: dataManager,
                    notificationManager: notificationManager,
                    backgroundRefreshManager: backgroundRefreshManager
                )
            }
        )
    }
}

@MainActor
private final class Counter {
    var value = 0
}
