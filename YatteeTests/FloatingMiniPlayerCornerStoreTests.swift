//
//  FloatingMiniPlayerCornerStoreTests.swift
//  Yattee
//
//  Tests for semantic floating mini player corner persistence.
//

import Foundation
import Testing
@testable import YaTubee

@Suite("Floating Mini Player Corner Store Tests")
struct FloatingMiniPlayerCornerStoreTests {
    @Test("Missing and invalid values restore the default corner")
    func defaultRestoration() {
        withStore { store, defaults in
            #expect(store.load() == .bottomTrailing)

            defaults.set("invalid", forKey: FloatingMiniPlayerCornerStore.storageKey)
            #expect(store.load() == .bottomTrailing)
        }
    }

    @Test("Each semantic corner survives a persistence round trip")
    func cornerRoundTrip() {
        withStore { store, _ in
            for corner in FloatingMiniPlayerCorner.allCases {
                store.save(corner)
                #expect(store.load() == corner)
            }
        }
    }

    @Test("Missing and non-finite size values restore the default scale")
    func defaultSizeScaleRestoration() {
        withStore { store, defaults in
            #expect(store.loadSizeScale() == 0.85)

            defaults.set(Double.nan, forKey: FloatingMiniPlayerCornerStore.sizeScaleStorageKey)
            #expect(store.loadSizeScale() == 0.85)

            defaults.set("invalid", forKey: FloatingMiniPlayerCornerStore.sizeScaleStorageKey)
            #expect(store.loadSizeScale() == 0.85)
        }
    }

    @Test("Size scale is clamped and survives persistence")
    func sizeScaleRoundTrip() {
        withStore { store, _ in
            store.saveSizeScale(0.92)
            #expect(store.loadSizeScale() == 0.92)

            store.saveSizeScale(0.4)
            #expect(store.loadSizeScale() == 0.70)

            store.saveSizeScale(1.4)
            #expect(store.loadSizeScale() == 1.00)
        }
    }

    private func withStore(
        _ operation: (FloatingMiniPlayerCornerStore, UserDefaults) -> Void
    ) {
        let suiteName = "FloatingMiniPlayerCornerStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        operation(FloatingMiniPlayerCornerStore(defaults: defaults), defaults)
    }
}
