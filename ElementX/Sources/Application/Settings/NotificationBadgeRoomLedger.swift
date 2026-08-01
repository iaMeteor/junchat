//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Darwin
import Foundation

struct NotificationBadgeSnapshot: Equatable {
    let userID: String
    let count: Int
    let revision: UInt64
}

final class NotificationBadgeRoomLedger: @unchecked Sendable {
    private struct State: Codable, Equatable {
        let userID: String
        var isReconciled: Bool
        var revision: UInt64
        var unreadRoomIDs: Set<String>
        var recentNotificationDates: [String: Date]
        var provisionalNotificationDates: [String: Date]
        var recentReadDates: [String: Date]

        var badgeRoomIDs: Set<String> {
            unreadRoomIDs
                .union(recentNotificationDates.keys)
                .union(provisionalNotificationDates.keys)
                .subtracting(recentReadDates.keys)
        }

        var badgeCount: Int {
            badgeRoomIDs.count
        }

        var snapshot: NotificationBadgeSnapshot {
            .init(userID: userID, count: badgeCount, revision: revision)
        }
    }

    private static let storageKey = "junchat.notificationBadgeRoomLedger.v5"
    private static let notificationSyncGracePeriod: TimeInterval = 2 * 60
    private static let processLock = NSLock()

    private let userDefaults: UserDefaults
    private let lockFileURL: URL
    private let now: @Sendable () -> Date

    init(userDefaults: UserDefaults,
         lockFileURL: URL,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.userDefaults = userDefaults
        self.lockFileURL = lockFileURL
        self.now = now
    }

    func prepare(for userID: String) {
        withExclusiveLock(fallback: ()) {
            let currentState = loadState()
            guard currentState?.userID != userID else { return }
            saveState(.init(userID: userID,
                            isReconciled: false,
                            revision: (currentState?.revision ?? 0) &+ 1,
                            unreadRoomIDs: [],
                            recentNotificationDates: [:],
                            provisionalNotificationDates: [:],
                            recentReadDates: [:]))
        }
    }

    func reconcile(userID: String, unreadRoomIDs: Set<String>) -> NotificationBadgeSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard let currentState = loadState(), currentState.userID == userID else { return nil }
            let cutoffDate = now().addingTimeInterval(-Self.notificationSyncGracePeriod)
            let recentNotificationDates = currentState.recentNotificationDates.filter { roomID, date in
                !unreadRoomIDs.contains(roomID) && date >= cutoffDate
            }
            let provisionalNotificationDates = currentState.provisionalNotificationDates.filter { roomID, date in
                !unreadRoomIDs.contains(roomID) && date >= cutoffDate
            }
            let recentReadDates = currentState.recentReadDates.filter { roomID, date in
                unreadRoomIDs.contains(roomID) && date >= cutoffDate
            }
            let state = persistIfChanged(.init(userID: userID,
                                               isReconciled: true,
                                               revision: currentState.revision,
                                               unreadRoomIDs: unreadRoomIDs,
                                               recentNotificationDates: recentNotificationDates,
                                               provisionalNotificationDates: provisionalNotificationDates,
                                               recentReadDates: recentReadDates),
                                         currentState: currentState)
            return state.snapshot
        }
    }

    func applyNotification(userID: String?,
                           roomID: String?,
                           contributesToBadge: Bool?,
                           fallback: NSNumber?) -> NSNumber? {
        withExclusiveLock(fallback: fallback) {
            guard var state = loadStatePruningExpiredProvisionalEntries() else { return fallback }

            guard let userID else {
                return state.isReconciled ? NSNumber(value: state.badgeCount) : fallback
            }

            guard state.userID == userID else {
                return state.isReconciled ? NSNumber(value: state.badgeCount) : NSNumber(value: 0)
            }

            guard state.isReconciled else { return fallback }

            let previousState = state
            if let roomID {
                switch contributesToBadge {
                case true:
                    state.recentNotificationDates[roomID] = now()
                    state.provisionalNotificationDates[roomID] = nil
                    state.recentReadDates[roomID] = nil
                case false:
                    state.provisionalNotificationDates[roomID] = nil
                case nil:
                    let fallbackCount = fallback?.intValue
                    if !state.badgeRoomIDs.contains(roomID),
                       state.recentNotificationDates[roomID] == nil,
                       state.provisionalNotificationDates[roomID] == nil,
                       fallbackCount == state.badgeCount + 1 {
                        state.provisionalNotificationDates[roomID] = now()
                        state.recentReadDates[roomID] = nil
                    }
                }
            }

            state = persistIfChanged(state, currentState: previousState)
            return NSNumber(value: state.badgeCount)
        }
    }

    func markRoomRead(userID: String, roomID: String) -> NotificationBadgeSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard var state = loadStatePruningExpiredProvisionalEntries(),
                  state.userID == userID,
                  state.isReconciled else {
                return nil
            }

            let previousState = state
            state.unreadRoomIDs.remove(roomID)
            state.recentNotificationDates[roomID] = nil
            state.provisionalNotificationDates[roomID] = nil
            state.recentReadDates[roomID] = now()
            return persistIfChanged(state, currentState: previousState).snapshot
        }
    }

    func snapshot(for userID: String) -> NotificationBadgeSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard let state = loadStatePruningExpiredProvisionalEntries(), state.userID == userID else { return nil }
            return state.snapshot
        }
    }

    func withCurrentBadge(userID: String?,
                          fallback: NSNumber?,
                          delivery: (NSNumber?) -> Void) {
        let didDeliver = withExclusiveLock(fallback: false) {
            delivery(resolvedBadge(userID: userID,
                                   fallback: fallback,
                                   state: loadStatePruningExpiredProvisionalEntries()))
            return true
        }
        if !didDeliver {
            // Omitting a badge is safer than replaying a frozen value after a
            // newer notification when the app-group lock is unavailable.
            delivery(nil)
        }
    }

    func reset() {
        withExclusiveLock(fallback: ()) {
            let revision = (loadState()?.revision ?? 0) &+ 1
            saveState(.init(userID: "",
                            isReconciled: true,
                            revision: revision,
                            unreadRoomIDs: [],
                            recentNotificationDates: [:],
                            provisionalNotificationDates: [:],
                            recentReadDates: [:]))
        }
    }

    private func loadState() -> State? {
        userDefaults.synchronize()
        guard let data = userDefaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        userDefaults.synchronize()
    }

    private func persistIfChanged(_ state: State, currentState: State) -> State {
        guard state != currentState else { return state }
        var state = state
        state.revision = currentState.revision &+ 1
        saveState(state)
        return state
    }

    private func loadStatePruningExpiredProvisionalEntries() -> State? {
        guard let currentState = loadState() else { return nil }
        let cutoffDate = now().addingTimeInterval(-Self.notificationSyncGracePeriod)
        var state = currentState
        state.provisionalNotificationDates = state.provisionalNotificationDates.filter { _, date in
            date >= cutoffDate
        }
        return persistIfChanged(state, currentState: currentState)
    }

    private func resolvedBadge(userID: String?, fallback: NSNumber?, state: State?) -> NSNumber? {
        guard let state else { return fallback }
        guard let userID else {
            return state.isReconciled ? NSNumber(value: state.badgeCount) : fallback
        }
        guard state.userID == userID else {
            return state.isReconciled ? NSNumber(value: state.badgeCount) : NSNumber(value: 0)
        }
        return state.isReconciled ? NSNumber(value: state.badgeCount) : fallback
    }

    private func withExclusiveLock<T>(fallback: T, operation: () -> T) -> T {
        Self.processLock.withLock {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: lockFileURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)

            let descriptor = Darwin.open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return fallback }
            defer { Darwin.close(descriptor) }

            guard flock(descriptor, LOCK_EX) == 0 else { return fallback }
            defer { flock(descriptor, LOCK_UN) }

            return operation()
        }
    }
}
