//
//  FeedRefreshSingleFlightTests.swift
//  YatteeTests
//
//  Tests for joining concurrent subscription feed refreshes.
//

import Foundation
import Testing
@testable import YaTubee

@MainActor
@Suite("Feed Refresh Single Flight Tests")
struct FeedRefreshSingleFlightTests {
    @Test("Concurrent callers share one operation and wait for it")
    func concurrentCallersShareOperation() async {
        let singleFlight = FeedRefreshSingleFlight()
        let started = AsyncGate()
        let gate = AsyncGate()
        var operationCount = 0
        var completionCount = 0

        let first = Task { @MainActor in
            await singleFlight.run {
                operationCount += 1
                await started.open()
                await gate.wait()
            }
            completionCount += 1
        }
        await started.wait()

        let second = Task { @MainActor in
            await singleFlight.run {
                operationCount += 1
            }
            completionCount += 1
        }
        let third = Task { @MainActor in
            await singleFlight.run {
                operationCount += 1
            }
            completionCount += 1
        }
        await Task.yield()

        #expect(operationCount == 1)
        #expect(completionCount == 0)

        await gate.open()
        await first.value
        await second.value
        await third.value

        #expect(operationCount == 1)
        #expect(completionCount == 3)
    }

    @Test("A later refresh starts after the shared operation finishes")
    func laterRefreshStartsNormally() async {
        let singleFlight = FeedRefreshSingleFlight()
        var operationCount = 0

        await singleFlight.run {
            operationCount += 1
        }
        await singleFlight.run {
            operationCount += 1
        }

        #expect(operationCount == 2)
    }

    @Test("A completed failing operation releases the next refresh")
    func handledFailureReleasesOperation() async {
        let singleFlight = FeedRefreshSingleFlight()
        var operationCount = 0
        var recordedFailure = false

        await singleFlight.run {
            operationCount += 1
            do {
                throw TestFailure.expected
            } catch {
                recordedFailure = true
            }
        }
        await singleFlight.run {
            operationCount += 1
        }

        #expect(recordedFailure)
        #expect(operationCount == 2)
    }

    @Test("Cancelling a joining caller does not cancel the shared operation")
    func cancellingJoinerDoesNotCancelSharedOperation() async {
        let singleFlight = FeedRefreshSingleFlight()
        let started = AsyncGate()
        let gate = AsyncGate()
        var operationCount = 0
        var operationFinished = false

        let first = Task { @MainActor in
            await singleFlight.run {
                operationCount += 1
                await started.open()
                await gate.wait()
                operationFinished = true
            }
        }
        await started.wait()

        let joiningCaller = Task { @MainActor in
            await singleFlight.run {
                operationCount += 1
            }
        }
        await Task.yield()
        joiningCaller.cancel()

        #expect(operationCount == 1)
        #expect(!operationFinished)

        await gate.open()
        _ = await first.value
        _ = await joiningCaller.value

        #expect(operationCount == 1)
        #expect(operationFinished)
    }
}

private enum TestFailure: Error {
    case expected
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
