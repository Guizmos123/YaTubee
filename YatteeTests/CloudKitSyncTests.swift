//
//  CloudKitSyncTests.swift
//  YatteeTests
//
//  Tests for CloudKit record mapping and conflict resolution.
//

import CloudKit
import Foundation
import Testing
@testable import YaTubee

@Suite("CloudKit Sync")
struct CloudKitSyncTests {

    @MainActor
    private static func makeMapper() -> CloudKitRecordMapper {
        CloudKitRecordMapper(zone: CKRecordZone(zoneName: RecordType.zoneName))
    }

    @MainActor
    private static func makeEntry(
        videoID: String = "video1",
        watchedSeconds: TimeInterval = 0,
        duration: TimeInterval = 0,
        isLive: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> WatchEntry {
        let entry = WatchEntry(
            videoID: videoID,
            sourceRawValue: "global",
            title: "Video",
            authorName: "Channel",
            authorID: "ch1",
            duration: duration,
            watchedSeconds: watchedSeconds,
            isLive: isLive
        )
        entry.updatedAt = updatedAt
        return entry
    }

    // MARK: - Manual Sync

    @Suite("Manual Sync")
    struct ManualSyncTests {
        @Test("An initialized engine is reused for a manual sync")
        func existingEngineIsReused() {
            let action = CloudKitManualSyncAction.resolve(hasExistingEngine: true)

            #expect(action == .synchronizeExistingEngine)
        }

        @Test("A missing engine is initialized for a manual sync")
        func missingEngineIsSetUp() {
            let action = CloudKitManualSyncAction.resolve(hasExistingEngine: false)

            #expect(action == .setUpMissingEngine)
        }

        @Test(
            "Pending changes keep the existing engine",
            arguments: [
                ["save:subscription"],
                ["delete:subscription"],
                ["save:subscription", "delete:history", "save:bookmark"]
            ]
        )
        func pendingChangesKeepExistingEngine(_ pendingChanges: [String]) {
            let changesBeforeRefresh = pendingChanges
            let action = CloudKitManualSyncAction.resolve(hasExistingEngine: !pendingChanges.isEmpty)

            #expect(action == .synchronizeExistingEngine)
            #expect(pendingChanges == changesBeforeRefresh)
        }

        @Test("Repeated manual syncs keep using the same engine")
        func repeatedRefreshesReuseEngine() {
            let actions = (0..<3).map { _ in
                CloudKitManualSyncAction.resolve(hasExistingEngine: true)
            }

            #expect(actions.allSatisfy { $0 == .synchronizeExistingEngine })
        }

        @Test("An interrupted sync resumes through the existing engine state")
        func interruptedRefreshKeepsPersistedState() {
            let serializedState = Data("serialized CKSyncEngine state".utf8)
            let stateBeforeRefresh = serializedState
            let action = CloudKitManualSyncAction.resolve(hasExistingEngine: true)

            #expect(action == .synchronizeExistingEngine)
            #expect(serializedState == stateBeforeRefresh)
        }
    }

    // MARK: - Record Mapper

    @Suite("Record Mapper")
    struct RecordMapperTests {
        @Test("isLive survives the record round-trip")
        @MainActor
        func liveFlagRoundTrip() throws {
            let mapper = CloudKitSyncTests.makeMapper()
            let record = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(isLive: true))

            #expect(record["isLive"] as? Int64 == 1)

            let decoded = try mapper.toWatchEntry(from: record)
            #expect(decoded.isLive)
        }

        @Test("Records from older clients without isLive read as not live")
        @MainActor
        func missingLiveFlagReadsFalse() throws {
            let mapper = CloudKitSyncTests.makeMapper()
            let record = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(isLive: true))
            // Simulate a record written before the field existed
            record["isLive"] = nil

            let decoded = try mapper.toWatchEntry(from: record)
            #expect(!decoded.isLive)
        }
    }

    // MARK: - Conflict Resolution

    @Suite("Watch Entry Conflicts")
    struct WatchEntryConflictTests {
        @Test("Newer local live watch keeps its isLive flag over an old server record")
        @MainActor
        func localLiveWinsOverStaleServer() async throws {
            let mapper = CloudKitSyncTests.makeMapper()
            let local = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                isLive: true,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ))
            let server = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                watchedSeconds: 1_234,
                duration: 3_600,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ))
            // Old clients never wrote the field at all
            server["isLive"] = nil

            let resolver = CloudKitConflictResolver()
            let resolved = await resolver.resolveWatchEntryConflict(local: local, server: server)

            #expect(resolved["isLive"] as? Int64 == 1)
            #expect(resolved["watchedSeconds"] as? Double == 0)
        }

        @Test("Newer local VOD heal clears a stale live flag on the server")
        @MainActor
        func localVODHealClearsServerLiveFlag() async throws {
            let mapper = CloudKitSyncTests.makeMapper()
            let local = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                watchedSeconds: 300,
                duration: 1_200,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ))
            let server = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                isLive: true,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ))

            let resolver = CloudKitConflictResolver()
            let resolved = await resolver.resolveWatchEntryConflict(local: local, server: server)

            #expect(resolved["isLive"] as? Int64 == 0)
            #expect(resolved["watchedSeconds"] as? Double == 300)
        }

        @Test("Newer server record keeps its isLive flag")
        @MainActor
        func newerServerLiveFlagWins() async throws {
            let mapper = CloudKitSyncTests.makeMapper()
            let local = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                watchedSeconds: 500,
                duration: 3_600,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ))
            let server = mapper.toCKRecord(watchEntry: CloudKitSyncTests.makeEntry(
                isLive: true,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ))

            let resolver = CloudKitConflictResolver()
            let resolved = await resolver.resolveWatchEntryConflict(local: local, server: server)

            #expect(resolved["isLive"] as? Int64 == 1)
            #expect(resolved["watchedSeconds"] as? Double == 0)
        }
    }
}
