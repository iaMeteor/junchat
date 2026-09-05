//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreFoundation
import Darwin
import Foundation

struct NotificationBadgeServerSnapshot: Codable, Equatable, Sendable {
    let userID: String
    let generation: String
    let revision: UInt64
    let total: Int

    init?(payload: [AnyHashable: Any]) {
        guard let state = payload["junchat_badge_state"] as? [String: Any],
              Set(state.keys) == ["user_id", "generation", "revision"],
              let userID = state["user_id"] as? String,
              userID.range(of: #"^@[^:\s]+:\S+\z"#, options: .regularExpression) != nil,
              let generation = state["generation"] as? String,
              UUID(uuidString: generation)?.uuidString.lowercased() == generation,
              let revisionString = state["revision"] as? String,
              revisionString.range(of: #"^[1-9][0-9]{0,18}\z"#, options: .regularExpression) != nil,
              let revision = UInt64(revisionString), revision <= UInt64(Int64.max),
              let total = payload["badge_total"] as? NSNumber,
              CFGetTypeID(total) != CFBooleanGetTypeID(),
              total.doubleValue.isFinite, total.int64Value >= 0,
              total.int64Value <= 9_007_199_254_740_991,
              total.compare(NSNumber(value: total.int64Value)) == .orderedSame else { return nil }
        self.userID = userID
        self.generation = generation
        self.revision = revision
        self.total = total.intValue
    }

    var metadata: [String: String] {
        ["user_id": userID, "generation": generation, "revision": String(revision)]
    }
}

struct NotificationBadgeSnapshot: Equatable {
    let userID: String
    let count: Int
    let isReconciled: Bool
    let recentAuthoritativeCount: Int?
    let revision: UInt64
}

private func saturatingBadgeTotal<S: Sequence>(_ counts: S) -> Int where S.Element == Int {
    counts.reduce(into: 0) { result, count in
        let (sum, overflow) = result.addingReportingOverflow(count)
        result = overflow ? Int.max : sum
    }
}

final class NotificationBadgeRoomLedger: @unchecked Sendable {
    private struct RecentEvent: Codable, Equatable {
        let roomID: String
        let countAfterEvent: Int
        let date: Date
    }

    private struct State: Codable, Equatable {
        let userID: String
        var isReconciled: Bool
        var revision: UInt64
        var unreadCountsByRoom: [String: Int]
        var recentAuthoritativeCount: Int?
        var recentAuthoritativeDate: Date?
        var recentAuthoritativeRoomCounts: [String: Int]?
        var recentNotificationEvents: [String: RecentEvent]
        var provisionalNotificationEvents: [String: RecentEvent]
        var recentSeenEventDates: [String: Date]
        var recentReadDates: [String: Date]
        var serverSnapshot: NotificationBadgeServerSnapshot?

        var confirmedBadgeRoomCounts: [String: Int] {
            var counts = unreadCountsByRoom.filter { roomID, count in
                count > 0 && recentReadDates[roomID] == nil
            }
            for event in recentNotificationEvents.values {
                if let readDate = recentReadDates[event.roomID], readDate >= event.date {
                    continue
                }
                counts[event.roomID] = max(counts[event.roomID] ?? 0, event.countAfterEvent)
            }
            return counts
        }

        var badgeRoomCounts: [String: Int] {
            var counts = confirmedBadgeRoomCounts
            for event in provisionalNotificationEvents.values {
                if let readDate = recentReadDates[event.roomID], readDate >= event.date {
                    continue
                }
                counts[event.roomID] = max(counts[event.roomID] ?? 0, event.countAfterEvent)
            }
            return counts
        }

        var badgeCount: Int {
            saturatingBadgeTotal(badgeRoomCounts.values)
        }

        var confirmedBadgeCount: Int {
            saturatingBadgeTotal(confirmedBadgeRoomCounts.values)
        }

        var authoritativeCountIsReconciled: Bool {
            guard let recentAuthoritativeCount,
                  recentAuthoritativeCount == badgeCount else {
                return false
            }
            guard recentAuthoritativeCount > 0 else {
                return true
            }
            let authoritativeRoomCounts = recentAuthoritativeRoomCounts ?? [:]
            return saturatingBadgeTotal(authoritativeRoomCounts.values) == recentAuthoritativeCount
                && authoritativeRoomCounts == badgeRoomCounts
        }

        var snapshot: NotificationBadgeSnapshot {
            if let serverSnapshot {
                return .init(userID: userID, count: serverSnapshot.total,
                             isReconciled: true, recentAuthoritativeCount: serverSnapshot.total,
                             revision: revision)
            }
            let count: Int
            if !isReconciled {
                count = recentAuthoritativeCount ?? badgeCount
            } else if recentAuthoritativeCount == 0 {
                count = 0
            } else if let recentAuthoritativeCount {
                // Provisional events without a stable event ID must not push a
                // server snapshot ahead, but confirmed distinct events may.
                count = max(recentAuthoritativeCount, confirmedBadgeCount)
            } else {
                count = badgeCount
            }
            return .init(userID: userID,
                         count: count,
                         isReconciled: isReconciled,
                         recentAuthoritativeCount: recentAuthoritativeCount,
                         revision: revision)
        }
    }

    private struct LegacyStateV5: Codable {
        let userID: String
        var isReconciled: Bool
        var revision: UInt64
        var unreadRoomIDs: Set<String>
        var recentAuthoritativeCount: Int?
        var recentAuthoritativeDate: Date?
        var recentAuthoritativeRoomIDs: Set<String>?
        var recentNotificationDates: [String: Date]
        var provisionalNotificationDates: [String: Date]
        var recentReadDates: [String: Date]
    }

    private static let storageKey = "junchat.notificationBadgeRoomLedger.v6"
    private static let legacyStorageKey = "junchat.notificationBadgeRoomLedger.v5"
    private static let notificationSyncGracePeriod: TimeInterval = 2 * 60
    private static let eventDeduplicationPeriod: TimeInterval = 24 * 60 * 60
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
                            unreadCountsByRoom: [:],
                            recentAuthoritativeCount: nil,
                            recentAuthoritativeDate: nil,
                            recentAuthoritativeRoomCounts: nil,
                            recentNotificationEvents: [:],
                            provisionalNotificationEvents: [:],
                            recentSeenEventDates: [:],
                            recentReadDates: [:]))
        }
    }

    func reconcile(userID: String, unreadRoomIDs: Set<String>) -> NotificationBadgeSnapshot? {
        reconcile(userID: userID,
                  unreadCountsByRoom: Dictionary(uniqueKeysWithValues: unreadRoomIDs.map { ($0, 1) }))
    }

    func reconcile(userID: String, unreadCountsByRoom: [String: Int]) -> NotificationBadgeSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard let currentState = loadState(), currentState.userID == userID else { return nil }
            let unreadCountsByRoom = unreadCountsByRoom.filter { $0.value > 0 }
            let cutoffDate = now().addingTimeInterval(-Self.notificationSyncGracePeriod)
            let recentNotificationEvents = currentState.recentNotificationEvents.filter { _, event in
                event.date >= cutoffDate && event.countAfterEvent > (unreadCountsByRoom[event.roomID] ?? 0)
            }
            let provisionalNotificationEvents = currentState.provisionalNotificationEvents.filter { _, event in
                event.date >= cutoffDate && event.countAfterEvent > (unreadCountsByRoom[event.roomID] ?? 0)
            }
            let recentReadDates = currentState.recentReadDates.filter { roomID, date in
                unreadCountsByRoom[roomID] != nil && date >= cutoffDate
            }
            let shouldRetainAuthoritativeCount = currentState.recentAuthoritativeDate.map { $0 >= cutoffDate } ?? false
            var reconciledState = State(userID: userID,
                                        isReconciled: true,
                                        revision: currentState.revision,
                                        unreadCountsByRoom: unreadCountsByRoom,
                                        recentAuthoritativeCount: shouldRetainAuthoritativeCount ? currentState.recentAuthoritativeCount : nil,
                                        recentAuthoritativeDate: shouldRetainAuthoritativeCount ? currentState.recentAuthoritativeDate : nil,
                                        recentAuthoritativeRoomCounts: shouldRetainAuthoritativeCount ? currentState.recentAuthoritativeRoomCounts : nil,
                                        recentNotificationEvents: recentNotificationEvents,
                                        provisionalNotificationEvents: provisionalNotificationEvents,
                                        recentSeenEventDates: currentState.recentSeenEventDates,
                                        recentReadDates: recentReadDates,
                                        serverSnapshot: currentState.serverSnapshot)
            if reconciledState.authoritativeCountIsReconciled {
                reconciledState.recentAuthoritativeCount = nil
                reconciledState.recentAuthoritativeDate = nil
                reconciledState.recentAuthoritativeRoomCounts = nil
            }
            let state = persistIfChanged(reconciledState,
                                         currentState: currentState)
            return state.snapshot
        }
    }

    func applyNotification(userID: String?,
                           roomID: String?,
                           eventID: String? = nil,
                           contributesToBadge: Bool?,
                           isAuthoritative: Bool = false,
                           serverSnapshot: NotificationBadgeServerSnapshot? = nil,
                           fallback: NSNumber?) -> NSNumber? {
        withExclusiveLock(fallback: fallback) {
            guard var state = loadStatePruningExpiredProvisionalEntries() else { return fallback }

            guard let userID else {
                return state.isReconciled ? NSNumber(value: state.badgeCount) : fallback
            }

            guard state.userID == userID else {
                return state.isReconciled ? NSNumber(value: state.snapshot.count) : NSNumber(value: 0)
            }

            let previousState = state
            if state.serverSnapshot != nil {
                if isAuthoritative, let serverSnapshot,
                   serverSnapshot.userID == userID,
                   serverSnapshot.generation == state.serverSnapshot?.generation,
                   serverSnapshot.revision > (state.serverSnapshot?.revision ?? 0) {
                    state.serverSnapshot = serverSnapshot
                }
                return NSNumber(value: persistIfChanged(state, currentState: previousState).snapshot.count)
            }
            let wasKnownStableEvent = roomID.flatMap { roomID in
                guard let eventID, !eventID.isEmpty else { return nil }
                return state.recentSeenEventDates[eventKey(eventID: eventID, roomID: roomID)] != nil
            } ?? false
            if let roomID {
                recordNotification(roomID: roomID,
                                   eventID: eventID,
                                   contributesToBadge: contributesToBadge,
                                   fallback: fallback,
                                   state: &state)
            }

            if isAuthoritative, !wasKnownStableEvent, let fallback {
                recordAuthoritativeCount(fallback.intValue,
                                         roomID: roomID,
                                         contributesToBadge: contributesToBadge,
                                         state: &state)
            }

            guard state.isReconciled else {
                state = persistIfChanged(state, currentState: previousState)
                return state.recentAuthoritativeCount.map(NSNumber.init(value:)) ?? fallback
            }

            state = persistIfChanged(state, currentState: previousState)
            return NSNumber(value: state.snapshot.count)
        }
    }

    func serverSnapshot(for userID: String) -> NotificationBadgeServerSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard let state = loadState(), state.userID == userID else { return nil }
            return state.serverSnapshot
        }
    }

    /// Only authenticated responses may establish or replace a generation.
    /// The caller captures the generation before starting its network request.
    func reconcileServerSnapshot(_ snapshot: NotificationBadgeServerSnapshot,
                                 expectedGeneration: String?) -> NotificationBadgeSnapshot? {
        withExclusiveLock(fallback: nil) {
            guard var state = loadState(), state.userID == snapshot.userID else { return nil }
            let previousState = state
            if let current = state.serverSnapshot, current.generation == snapshot.generation {
                guard snapshot.revision > current.revision else { return state.snapshot }
            } else {
                guard state.serverSnapshot?.generation == expectedGeneration else { return state.snapshot }
            }
            state.serverSnapshot = snapshot
            return persistIfChanged(state, currentState: previousState).snapshot
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
            state.unreadCountsByRoom[roomID] = nil
            state.recentNotificationEvents = state.recentNotificationEvents.filter { $0.value.roomID != roomID }
            state.provisionalNotificationEvents = state.provisionalNotificationEvents.filter { $0.value.roomID != roomID }
            state.recentReadDates[roomID] = now()
            var authoritativeRoomCounts = state.recentAuthoritativeRoomCounts ?? [:]
            let contributedCount = authoritativeRoomCounts.removeValue(forKey: roomID) ?? 0
            state.recentAuthoritativeRoomCounts = authoritativeRoomCounts
            if let authoritativeCount = state.recentAuthoritativeCount, contributedCount > 0 {
                state.recentAuthoritativeCount = max(0, authoritativeCount - contributedCount)
                state.recentAuthoritativeDate = now()
            }
            if state.authoritativeCountIsReconciled {
                state.recentAuthoritativeCount = nil
                state.recentAuthoritativeDate = nil
                state.recentAuthoritativeRoomCounts = nil
            }
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
        let resolution = withExclusiveLock(fallback: (didResolve: false, badge: nil as NSNumber?)) {
            (didResolve: true,
             badge: resolvedBadge(userID: userID,
                                  fallback: fallback,
                                  state: loadStatePruningExpiredProvisionalEntries()))
        }
        if resolution.didResolve {
            delivery(resolution.badge)
        } else {
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
                            unreadCountsByRoom: [:],
                            recentAuthoritativeCount: nil,
                            recentAuthoritativeDate: nil,
                            recentAuthoritativeRoomCounts: nil,
                            recentNotificationEvents: [:],
                            provisionalNotificationEvents: [:],
                            recentSeenEventDates: [:],
                            recentReadDates: [:]))
        }
    }

    private func loadState() -> State? {
        userDefaults.synchronize()
        if let data = userDefaults.data(forKey: Self.storageKey),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            return state
        }
        guard let data = userDefaults.data(forKey: Self.legacyStorageKey),
              let legacyState = try? JSONDecoder().decode(LegacyStateV5.self, from: data) else {
            return nil
        }
        let state = migratedState(from: legacyState)
        saveState(state)
        return state
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
        let deduplicationCutoffDate = now().addingTimeInterval(-Self.eventDeduplicationPeriod)
        var state = currentState
        state.provisionalNotificationEvents = state.provisionalNotificationEvents.filter { _, event in
            event.date >= cutoffDate
        }
        state.recentSeenEventDates = state.recentSeenEventDates.filter { _, date in
            date >= deduplicationCutoffDate
        }
        if let authoritativeDate = state.recentAuthoritativeDate, authoritativeDate < cutoffDate {
            state.recentAuthoritativeCount = nil
            state.recentAuthoritativeDate = nil
            state.recentAuthoritativeRoomCounts = nil
        }
        return persistIfChanged(state, currentState: currentState)
    }

    private func resolvedBadge(userID: String?, fallback: NSNumber?, state: State?) -> NSNumber? {
        guard let state else { return fallback }
        guard let userID else {
            return state.isReconciled ? NSNumber(value: state.snapshot.count) : fallback
        }
        guard state.userID == userID else {
            return state.isReconciled ? NSNumber(value: state.snapshot.count) : NSNumber(value: 0)
        }
        if state.isReconciled {
            return NSNumber(value: state.snapshot.count)
        }
        if let recentAuthoritativeCount = state.recentAuthoritativeCount {
            return NSNumber(value: recentAuthoritativeCount)
        }
        return fallback
    }

    private func migratedState(from legacyState: LegacyStateV5) -> State {
        let unreadCountsByRoom = Dictionary(uniqueKeysWithValues: legacyState.unreadRoomIDs.map { ($0, 1) })
        let recentNotificationEvents = Dictionary(uniqueKeysWithValues: legacyState.recentNotificationDates.map { roomID, date in
            (eventKey(eventID: nil, roomID: roomID),
             RecentEvent(roomID: roomID, countAfterEvent: max(1, unreadCountsByRoom[roomID] ?? 0), date: date))
        })
        let provisionalNotificationEvents = Dictionary(uniqueKeysWithValues: legacyState.provisionalNotificationDates.map { roomID, date in
            ("provisional:\(roomID)",
             RecentEvent(roomID: roomID, countAfterEvent: max(1, unreadCountsByRoom[roomID] ?? 0), date: date))
        })
        let recentAuthoritativeRoomCounts = legacyState.recentAuthoritativeRoomIDs.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0, 1) })
        }
        return .init(userID: legacyState.userID,
                     isReconciled: legacyState.isReconciled,
                     revision: legacyState.revision,
                     unreadCountsByRoom: unreadCountsByRoom,
                     recentAuthoritativeCount: legacyState.recentAuthoritativeCount,
                     recentAuthoritativeDate: legacyState.recentAuthoritativeDate,
                     recentAuthoritativeRoomCounts: recentAuthoritativeRoomCounts,
                     recentNotificationEvents: recentNotificationEvents,
                     provisionalNotificationEvents: provisionalNotificationEvents,
                     recentSeenEventDates: [:],
                     recentReadDates: legacyState.recentReadDates)
    }

    private func eventKey(eventID: String?, roomID: String) -> String {
        if let eventID, !eventID.isEmpty {
            return "event:\(eventID)"
        }
        return "room:\(roomID)"
    }

    private func incremented(_ count: Int) -> Int {
        count == Int.max ? Int.max : count + 1
    }

    private func recordNotification(roomID: String,
                                    eventID: String?,
                                    contributesToBadge: Bool?,
                                    fallback: NSNumber?,
                                    state: inout State) {
        let eventKey = eventKey(eventID: eventID, roomID: roomID)
        let hasStableEventID = eventID?.isEmpty == false
        let wasSeen = hasStableEventID && state.recentSeenEventDates[eventKey] != nil
        switch contributesToBadge {
        case true:
            recordConfirmedNotification(roomID: roomID,
                                        eventKey: eventKey,
                                        hasStableEventID: hasStableEventID,
                                        wasSeen: wasSeen,
                                        state: &state)
        case false:
            state.provisionalNotificationEvents[eventKey] = nil
            if hasStableEventID, !wasSeen {
                state.recentSeenEventDates[eventKey] = now()
            }
        case nil:
            recordProvisionalNotification(roomID: roomID,
                                          eventKey: eventKey,
                                          hasStableEventID: hasStableEventID,
                                          wasSeen: wasSeen,
                                          fallback: fallback,
                                          state: &state)
        }
    }

    private func recordConfirmedNotification(roomID: String,
                                             eventKey: String,
                                             hasStableEventID: Bool,
                                             wasSeen: Bool,
                                             state: inout State) {
        var didAddContribution = false
        if state.recentNotificationEvents[eventKey] == nil {
            if let provisionalEvent = state.provisionalNotificationEvents.removeValue(forKey: eventKey) {
                state.recentNotificationEvents[eventKey] = .init(roomID: provisionalEvent.roomID,
                                                                 countAfterEvent: provisionalEvent.countAfterEvent,
                                                                 date: now())
                didAddContribution = true
            } else if state.isReconciled, !wasSeen {
                state.recentNotificationEvents[eventKey] = .init(roomID: roomID,
                                                                 countAfterEvent: incremented(state.badgeRoomCounts[roomID] ?? 0),
                                                                 date: now())
                didAddContribution = true
            }
        }
        if hasStableEventID, !wasSeen {
            state.recentSeenEventDates[eventKey] = now()
        }
        if didAddContribution {
            state.recentReadDates[roomID] = nil
        }
    }

    private func recordProvisionalNotification(roomID: String,
                                               eventKey: String,
                                               hasStableEventID: Bool,
                                               wasSeen: Bool,
                                               fallback: NSNumber?,
                                               state: inout State) {
        guard !wasSeen,
              state.recentNotificationEvents[eventKey] == nil,
              state.provisionalNotificationEvents[eventKey] == nil,
              fallback?.intValue == incremented(state.badgeCount) else {
            return
        }
        state.provisionalNotificationEvents[eventKey] = .init(roomID: roomID,
                                                              countAfterEvent: incremented(state.badgeRoomCounts[roomID] ?? 0),
                                                              date: now())
        if hasStableEventID {
            state.recentSeenEventDates[eventKey] = now()
        }
        state.recentReadDates[roomID] = nil
    }

    private func recordAuthoritativeCount(_ count: Int,
                                          roomID: String?,
                                          contributesToBadge: Bool?,
                                          state: inout State) {
        state.recentAuthoritativeCount = count
        state.recentAuthoritativeDate = now()
        let roomCounts = state.badgeRoomCounts
        guard count > 0, contributesToBadge == true, let roomID else {
            state.recentAuthoritativeRoomCounts = [:]
            return
        }
        if saturatingBadgeTotal(roomCounts.values) == count {
            state.recentAuthoritativeRoomCounts = roomCounts
            return
        }

        guard state.isReconciled else {
            state.recentAuthoritativeRoomCounts = [roomID: 1]
            return
        }

        let otherRoomTotal = saturatingBadgeTotal(roomCounts.lazy
            .filter { $0.key != roomID }
            .map(\.value))
        let localRoomCount = roomCounts[roomID] ?? 0
        if count >= otherRoomTotal,
           count - otherRoomTotal >= localRoomCount {
            var inferredRoomCounts = roomCounts
            inferredRoomCounts[roomID] = count - otherRoomTotal
            state.recentAuthoritativeRoomCounts = inferredRoomCounts
        } else {
            state.recentAuthoritativeRoomCounts = [roomID: 1]
        }
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
