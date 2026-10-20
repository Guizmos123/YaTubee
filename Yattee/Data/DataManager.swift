//
//  DataManager.swift
//  Yattee
//
//  Central manager for all local data operations using SwiftData.
//

import Foundation
import SwiftData

/// Observable state of a count read from the local SwiftData store.
enum LocalCountState: Equatable, Sendable {
    case notLoaded
    case value(Int)
    case error

    var value: Int? {
        guard case .value(let count) = self else { return nil }
        return count
    }
}

/// Counts shared by every Home and Hub presentation.
struct LocalDataStatistics: Equatable, Sendable {
    var playlists: LocalCountState = .notLoaded
    var bookmarks: LocalCountState = .notLoaded
    var continueWatching: LocalCountState = .notLoaded
    var history: LocalCountState = .notLoaded
    var subscriptions: LocalCountState = .notLoaded
}

/// Manages all local data persistence using SwiftData with CloudKit sync.
@MainActor
@Observable
final class DataManager {
    // MARK: - Properties

    let modelContainer: ModelContainer
    let modelContext: ModelContext
    
    /// Weak reference to settings manager for accessing search history limit.
    weak var settingsManager: SettingsManager?
    
    /// Weak reference to CloudKit sync engine.
    weak var cloudKitSync: CloudKitSyncEngine?

    /// Whether CloudKit sync is currently enabled for this instance.
    private(set) var isCloudKitEnabled: Bool = false
    
    /// Cached set of bookmarked video IDs for fast O(1) lookup.
    /// Updated when bookmarks are added/removed locally or via CloudKit sync.
    var cachedBookmarkedVideoIDs: Set<String> = []

    /// Local counts consumed by Home and Hub. These are never persisted separately.
    private(set) var localStatistics = LocalDataStatistics()

    @ObservationIgnored private var statisticsObservers: [NSObjectProtocol] = []

    /// Shared schema for all data models.
    static let schema = Schema([
        WatchEntry.self,
        Bookmark.self,
        LocalPlaylist.self,
        LocalPlaylistItem.self,
        Subscription.self,
        SearchHistory.self,
        RecentChannel.self,
        RecentPlaylist.self,
        ChannelNotificationSettings.self
    ])

    // MARK: - Initialization

    convenience init(inMemory: Bool = false, iCloudSyncEnabled _: Bool = false) throws {
        let configuration: ModelConfiguration

        // IMPORTANT: We intentionally do NOT use SwiftData's built-in CloudKit sync.
        // SwiftData CloudKit sync uses internal UUIDs which causes duplicates when
        // the same data is created on multiple devices (each device generates different IDs).
        //
        // Instead, we use CKSyncEngine directly via CloudKitSyncEngine for iCloud sync.
        // This approach:
        // 1. Uses business identifiers (channelID, videoID) for deduplication
        // 2. Gives explicit control over sync timing and conflict resolution
        // 3. Avoids the duplicate data problem inherent in SwiftData CloudKit sync
        if inMemory {
            configuration = ModelConfiguration(
                schema: Self.schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none  // Explicitly disable SwiftData CloudKit sync
            )
        } else {
            configuration = ModelConfiguration(
                schema: Self.schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none  // Explicitly disable SwiftData CloudKit sync
            )
        }

        try self.init(configuration: configuration)
    }

    /// Creates a manager with an explicit configuration. Production uses the
    /// default persistent configuration above; tests use this initializer with
    /// an isolated temporary URL so real application data is never touched.
    init(configuration: ModelConfiguration) throws {
        self.modelContainer = try ModelContainer(
            for: Self.schema,
            configurations: [configuration]
        )
        self.modelContext = modelContainer.mainContext
        self.modelContext.autosaveEnabled = true
        self.isCloudKitEnabled = false

        LoggingService.shared.logCloudKit("SwiftData initialized with local storage (CloudKit sync via CKSyncEngine)")
        
        // Initialize bookmark cache
        refreshBookmarkCache()

        // Local statistics are available as soon as the SwiftData store is open;
        // they do not depend on the optional CloudKit synchronization pass.
        refreshLocalStatistics()
        
        // Listen for bookmark changes from CloudKit sync to refresh cache
        let bookmarkObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.refreshBookmarkCache()
            }
        }
        statisticsObservers.append(bookmarkObserver)

        for name in [
            Notification.Name.bookmarksDidChange,
            .watchHistoryDidChange,
            .playlistsDidChange,
            .subscriptionsDidChange
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalStatistics()
                }
            }
            statisticsObservers.append(observer)
        }
    }

    deinit {
        for observer in statisticsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Refreshes the cached set of bookmarked video IDs.
    /// Called at init and when bookmarks change via CloudKit sync.
    private func refreshBookmarkCache() {
        let descriptor = FetchDescriptor<Bookmark>()
        do {
            let bookmarks = try modelContext.fetch(descriptor)
            cachedBookmarkedVideoIDs = Set(bookmarks.map { $0.videoID })
        } catch {
            cachedBookmarkedVideoIDs = []
            LoggingService.shared.logCloudKitError("Failed to refresh bookmark cache", error: error)
        }
    }

    /// Recomputes local counts with SQL-backed count queries. A failed read stays
    /// distinguishable from a genuine zero and is logged for diagnosis.
    func refreshLocalStatistics() {
        localStatistics = LocalDataStatistics(
            playlists: fetchCount(FetchDescriptor<LocalPlaylist>(), label: "playlists"),
            bookmarks: fetchCount(FetchDescriptor<Bookmark>(), label: "bookmarks"),
            continueWatching: fetchCount(
                FetchDescriptor<WatchEntry>(
                    predicate: #Predicate { !$0.isFinished && !$0.isLive && $0.watchedSeconds > 10 }
                ),
                label: "continue watching"
            ),
            history: fetchCount(FetchDescriptor<WatchEntry>(), label: "watch history"),
            subscriptions: fetchCount(FetchDescriptor<Subscription>(), label: "subscriptions")
        )
    }

    private func fetchCount<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        label: String
    ) -> LocalCountState {
        do {
            return .value(try modelContext.fetchCount(descriptor))
        } catch {
            LoggingService.shared.logCloudKitError("Failed to count local \(label)", error: error)
            return .error
        }
    }

    /// Creates an in-memory DataManager for previews and testing.
    static func preview() throws -> DataManager {
        try DataManager(inMemory: true)
    }

    // MARK: - Utilities

    /// Forces a save of any pending changes.
    func save() {
        do {
            try modelContext.save()
        } catch {
            LoggingService.shared.logCloudKitError("Failed to save data", error: error)
        }
    }

    // MARK: - Subscription Updates

    /// Updates subscriber count and verified status for a subscription by channel ID.
    /// Used to populate cached metadata from Yattee Server.
    func updateSubscriberCount(for channelID: String, count: Int, isVerified: Bool?) {
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.channelID == channelID }
        )

        do {
            if let subscription = try modelContext.fetch(descriptor).first {
                subscription.subscriberCount = count
                if let verified = isVerified {
                    subscription.isVerified = verified
                }
                subscription.lastUpdatedAt = Date()
                save()
            }
        } catch {
            LoggingService.shared.logCloudKitError("Failed to update subscriber count for \(channelID)", error: error)
        }
    }
}
