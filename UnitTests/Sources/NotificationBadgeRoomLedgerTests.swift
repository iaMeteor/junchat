//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NotificationBadgeRoomLedgerTests {
    @Test
    func uninitializedLedgerUsesServerFallback() throws {
        let fixture = try makeLedger()
        fixture.ledger.prepare(for: "@alice:example.org")

        let badge = fixture.ledger.applyNotification(userID: "@alice:example.org",
                                                     roomID: "!one:example.org",
                                                     contributesToBadge: true,
                                                     fallback: 7)

        #expect(badge == 7)
    }

    @Test
    func visibleNotificationsAreCountedOncePerRoom() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         contributesToBadge: true,
                                         fallback: 3) == 1)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         contributesToBadge: true,
                                         fallback: 3) == 1)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!two:example.org",
                                         contributesToBadge: true,
                                         fallback: 3) == 2)
    }

    @Test
    func rtcAndUnknownNotificationsPreserveTheReconciledBadge() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!chat:example.org"])

        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!call:example.org",
                                         contributesToBadge: false,
                                         fallback: 3) == 1)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!unknown:example.org",
                                         contributesToBadge: nil,
                                         fallback: 3) == 1)
    }

    @Test
    func messageContributionAddsTheRoomUntilItIsRead() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!chat:example.org",
                                         contributesToBadge: true,
                                         fallback: 3) == 1)
        #expect(ledger.markRoomRead(userID: "@alice:example.org", roomID: "!chat:example.org")?.count == 0)
    }

    @Test
    func mainAppReconciliationAndRoomReadRemoveStaleRooms() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!stale:example.org"])

        let reconciledBadge = ledger.reconcile(userID: "@alice:example.org",
                                               unreadRoomIDs: ["!real:example.org"])
        let readBadge = ledger.markRoomRead(userID: "@alice:example.org",
                                            roomID: "!real:example.org")

        #expect(reconciledBadge?.count == 1)
        #expect(readBadge?.count == 0)
    }

    @Test
    func notificationForAnotherAccountPreservesTheActiveAccountBadge() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!room:example.org"])

        let badge = ledger.applyNotification(userID: "@bob:example.org",
                                             roomID: "!other:example.org",
                                             contributesToBadge: true,
                                             fallback: 7)

        #expect(badge == 1)
    }

    @Test
    func staleReconciliationCannotReplaceTheActiveAccount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        ledger.prepare(for: "@bob:example.org")

        let staleBadge = ledger.reconcile(userID: "@alice:example.org",
                                          unreadRoomIDs: ["!stale:example.org"])
        let activeBadge = ledger.applyNotification(userID: "@bob:example.org",
                                                   roomID: "!new:example.org",
                                                   contributesToBadge: true,
                                                   fallback: 5)

        #expect(staleBadge == nil)
        #expect(activeBadge == 5)
    }

    @Test
    func concurrentLedgerInstancesDoNotLoseDifferentRooms() async throws {
        let fixture = try makeLedger()
        let firstLedger = fixture.ledger
        let secondLedger = NotificationBadgeRoomLedger(userDefaults: fixture.userDefaults,
                                                       lockFileURL: fixture.lockFileURL)
        firstLedger.prepare(for: "@alice:example.org")
        _ = firstLedger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let ledger = index.isMultiple(of: 2) ? firstLedger : secondLedger
                    _ = ledger.applyNotification(userID: "@alice:example.org",
                                                 roomID: "!\(index):example.org",
                                                 contributesToBadge: true,
                                                 fallback: 0)
                }
            }
        }

        #expect(firstLedger.applyNotification(userID: "@alice:example.org",
                                              roomID: nil,
                                              contributesToBadge: nil,
                                              fallback: 0) == 40)
    }

    @Test
    func accountSwitchBeforeFirstReconciliationClearsLegacyFallback() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        let badge = ledger.applyNotification(userID: "@bob:example.org",
                                             roomID: "!other:example.org",
                                             contributesToBadge: true,
                                             fallback: 7)

        #expect(badge == 0)
    }

    @Test
    func logoutPreventsALatePushFromRestoringTheServerFallback() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!room:example.org"])

        ledger.reset()
        let badge = ledger.applyNotification(userID: "@alice:example.org",
                                             roomID: "!late:example.org",
                                             contributesToBadge: true,
                                             fallback: 7)

        #expect(badge == 0)
    }

    @Test
    func reconciliationRetainsRecentNotificationsUntilSyncCatchesUp() throws {
        let clock = NotificationBadgeLedgerTestClock(now: Date(timeIntervalSince1970: 1000))
        let fixture = try makeLedger { clock.now }
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!new:example.org",
                                     contributesToBadge: true,
                                     fallback: 3)

        let protectedBadge = ledger.reconcile(userID: "@alice:example.org",
                                              unreadRoomIDs: ["!real:example.org"])
        clock.advance(by: 121)
        let expiredBadge = ledger.reconcile(userID: "@alice:example.org",
                                            unreadRoomIDs: ["!real:example.org"])

        #expect(protectedBadge?.count == 2)
        #expect(expiredBadge?.count == 1)
    }

    @Test
    func unknownLegacyContributionIsProvisionalAndCanBeRejected() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])

        let provisionalBadge = ledger.applyNotification(userID: "@alice:example.org",
                                                        roomID: "!new:example.org",
                                                        contributesToBadge: nil,
                                                        fallback: 2)
        let rejectedBadge = ledger.applyNotification(userID: "@alice:example.org",
                                                     roomID: "!new:example.org",
                                                     contributesToBadge: false,
                                                     fallback: 2)

        #expect(provisionalBadge == 2)
        #expect(rejectedBadge == 1)
    }

    @Test
    func provisionalLegacyContributionExpiresWithoutMainAppReconciliation() throws {
        let clock = NotificationBadgeLedgerTestClock(now: Date(timeIntervalSince1970: 1000))
        let fixture = try makeLedger { clock.now }
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!provisional:example.org",
                                     contributesToBadge: nil,
                                     fallback: 2)

        clock.advance(by: 121)

        #expect(ledger.snapshot(for: "@alice:example.org")?.count == 1)
        var deliveredBadge: NSNumber?
        ledger.withCurrentBadge(userID: "@alice:example.org", fallback: 2) { badge in
            deliveredBadge = badge
        }
        #expect(deliveredBadge == 1)
    }

    @Test
    func unavailableLedgerLockOmitsFrozenBadge() throws {
        let fixture = try makeLedger()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        let unavailableLedger = NotificationBadgeRoomLedger(userDefaults: fixture.userDefaults,
                                                            lockFileURL: URL(filePath: "/dev/null/ledger.lock"))

        var deliveredBadge: NSNumber? = 7
        unavailableLedger.withCurrentBadge(userID: "@alice:example.org", fallback: 7) { badge in
            deliveredBadge = badge
        }

        #expect(deliveredBadge == nil)
    }

    @Test
    func unknownLegacyContributionDoesNotTrustAnInflatedJump() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])

        let badge = ledger.applyNotification(userID: "@alice:example.org",
                                             roomID: "!unknown:example.org",
                                             contributesToBadge: nil,
                                             fallback: 3)

        #expect(badge == 1)
    }

    @Test
    func roomReadTombstoneBlocksAStaleUnreadSnapshot() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!room:example.org"])

        let readBadge = ledger.markRoomRead(userID: "@alice:example.org",
                                            roomID: "!room:example.org")
        let staleSnapshotBadge = ledger.reconcile(userID: "@alice:example.org",
                                                  unreadRoomIDs: ["!room:example.org"])
        let caughtUpSnapshotBadge = ledger.reconcile(userID: "@alice:example.org",
                                                     unreadRoomIDs: [])
        let laterUnreadBadge = ledger.reconcile(userID: "@alice:example.org",
                                                unreadRoomIDs: ["!room:example.org"])

        #expect(readBadge?.count == 0)
        #expect(staleSnapshotBadge?.count == 0)
        #expect(caughtUpSnapshotBadge?.count == 0)
        #expect(laterUnreadBadge?.count == 1)
    }

    private func makeLedger(now: @escaping @Sendable () -> Date = { .now }) throws -> LedgerFixture {
        let identifier = UUID().uuidString
        let suiteName = "NotificationBadgeRoomLedgerTests.\(identifier)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "NotificationBadgeRoomLedgerTests")
            .appending(component: identifier)
        let lockFileURL = directoryURL.appending(component: "ledger.lock")
        let ledger = NotificationBadgeRoomLedger(userDefaults: userDefaults,
                                                 lockFileURL: lockFileURL,
                                                 now: now)
        return LedgerFixture(ledger: ledger,
                             suiteName: suiteName,
                             userDefaults: userDefaults,
                             directoryURL: directoryURL,
                             lockFileURL: lockFileURL)
    }
}

private final class NotificationBadgeLedgerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    var now: Date {
        lock.withLock { storedNow }
    }

    init(now: Date) {
        storedNow = now
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            storedNow = storedNow.addingTimeInterval(interval)
        }
    }
}

private final class LedgerFixture {
    let ledger: NotificationBadgeRoomLedger
    let userDefaults: UserDefaults
    let lockFileURL: URL

    private let suiteName: String
    private let directoryURL: URL

    init(ledger: NotificationBadgeRoomLedger,
         suiteName: String,
         userDefaults: UserDefaults,
         directoryURL: URL,
         lockFileURL: URL) {
        self.ledger = ledger
        self.suiteName = suiteName
        self.userDefaults = userDefaults
        self.directoryURL = directoryURL
        self.lockFileURL = lockFileURL
    }

    deinit {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
