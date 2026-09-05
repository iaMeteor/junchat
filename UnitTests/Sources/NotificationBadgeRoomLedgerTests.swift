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
    func authoritativeBadgeIsRememberedBeforeFirstReconciliation() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        let initialRevision = try #require(ledger.snapshot(for: "@alice:example.org")?.revision)

        let badge = ledger.applyNotification(userID: "@alice:example.org",
                                             roomID: "!one:example.org",
                                             contributesToBadge: true,
                                             isAuthoritative: true,
                                             fallback: 1)
        let snapshot = try #require(ledger.snapshot(for: "@alice:example.org"))

        #expect(badge == 1)
        #expect(!snapshot.isReconciled)
        #expect(snapshot.count == 1)
        #expect(snapshot.recentAuthoritativeCount == 1)
        #expect(snapshot.revision > initialRevision)

        var currentBadge: NSNumber?
        ledger.withCurrentBadge(userID: "@alice:example.org", fallback: 0) { currentBadge = $0 }
        #expect(currentBadge == 1)

        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: []))
        #expect(staleReconciliation.recentAuthoritativeCount == 1)
        #expect(staleReconciliation.count == 1)

        let caughtUpReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                   unreadRoomIDs: ["!one:example.org"]))
        #expect(caughtUpReconciliation.recentAuthoritativeCount == nil)
        #expect(caughtUpReconciliation.count == 1)
    }

    @Test
    func authoritativeZeroSurvivesAStaleUnreadFirstReconciliation() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: false,
                                     isAuthoritative: true,
                                     fallback: 0)
        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                unreadRoomIDs: ["!stale:example.org"]))
        #expect(staleReconciliation.recentAuthoritativeCount == 0)
        #expect(staleReconciliation.count == 0)

        let caughtUpReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: []))
        #expect(caughtUpReconciliation.recentAuthoritativeCount == nil)
        #expect(caughtUpReconciliation.count == 0)
    }

    @Test
    func readingOneRoomDecrementsAStillAheadAuthoritativeCountOnce() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 3)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        let firstRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                         roomID: "!one:example.org"))
        let repeatedRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                            roomID: "!one:example.org"))

        #expect(firstRead.recentAuthoritativeCount == 2)
        #expect(firstRead.count == 2)
        #expect(repeatedRead.recentAuthoritativeCount == 2)
        #expect(repeatedRead.count == 2)
    }

    @Test
    func readingAnUnrelatedRoomDoesNotDecrementAnAuthoritativeCount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!contributing:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 3)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        let unrelatedRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!unrelated:example.org"))

        #expect(unrelatedRead.recentAuthoritativeCount == 3)
        #expect(unrelatedRead.count == 3)
    }

    @Test
    func noncontributingSnapshotDoesNotReuseEarlierRoomEvidence() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: false,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        let read = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                    roomID: "!one:example.org"))

        #expect(read.recentAuthoritativeCount == 1)
        #expect(read.count == 1)
    }

    @Test
    func decreasedAuthoritativeTotalDoesNotKeepAmbiguousRoomEvidence() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 2)
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!other:example.org",
                                     contributesToBadge: false,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        let read = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                    roomID: "!one:example.org"))

        #expect(read.recentAuthoritativeCount == 1)
        #expect(read.count == 1)
    }

    @Test
    func sameTotalFromANewRoomReplacesAmbiguousRoomEvidence() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!one:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!two:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!one:example.org"))
        let contributingRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                                    roomID: "!two:example.org"))

        #expect(staleRoomRead.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.count == 1)
        #expect(contributingRoomRead.recentAuthoritativeCount == nil)
        #expect(contributingRoomRead.count == 0)
    }

    @Test
    func equalCountFromDifferentRoomsDoesNotClearAuthoritativeEvidence() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!real:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 1)
        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                unreadRoomIDs: ["!stale:example.org"]))
        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!stale:example.org"))
        let caughtUpReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                   unreadRoomIDs: ["!real:example.org"]))

        #expect(staleReconciliation.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.count == 1)
        #expect(caughtUpReconciliation.recentAuthoritativeCount == nil)
        #expect(caughtUpReconciliation.count == 1)
    }

    @Test
    func positiveAuthoritativeCountWithoutRoomEvidenceSurvivesEqualStaleCount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!unknown:example.org",
                                     contributesToBadge: nil,
                                     isAuthoritative: true,
                                     fallback: 1)
        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                unreadRoomIDs: ["!stale:example.org"]))
        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!stale:example.org"))

        #expect(staleReconciliation.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.count == 1)
    }

    @Test
    func partialRoomEvidenceDoesNotClearAnEqualAuthoritativeCount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!real:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 2)
        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                unreadRoomIDs: ["!real:example.org", "!stale:example.org"]))
        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!stale:example.org"))

        #expect(staleReconciliation.recentAuthoritativeCount == 2)
        #expect(staleRoomRead.recentAuthoritativeCount == 2)
        #expect(staleRoomRead.count == 2)
    }

    @Test
    func increasedAuthoritativeSnapshotDoesNotReuseAnEarlierRoomIdentity() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!old:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!new:example.org",
                                     contributesToBadge: true,
                                     isAuthoritative: true,
                                     fallback: 2)
        let staleReconciliation = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                                unreadRoomIDs: ["!old:example.org", "!new:example.org"]))
        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!old:example.org"))

        #expect(staleReconciliation.recentAuthoritativeCount == 2)
        #expect(staleRoomRead.recentAuthoritativeCount == 2)
        #expect(staleRoomRead.count == 2)
    }

    @Test
    func unrelatedReadsCannotConvergeARelevantCountWithoutRoomEvidence() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        _ = ledger.applyNotification(userID: "@alice:example.org",
                                     roomID: "!unknown:example.org",
                                     contributesToBadge: nil,
                                     isAuthoritative: true,
                                     fallback: 1)
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!stale:example.org"])
        let unrelatedRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!unrelated:example.org"))
        let staleRoomRead = try #require(ledger.markRoomRead(userID: "@alice:example.org",
                                                             roomID: "!stale:example.org"))

        #expect(unrelatedRead.recentAuthoritativeCount == 1)
        #expect(unrelatedRead.count == 1)
        #expect(staleRoomRead.recentAuthoritativeCount == 1)
        #expect(staleRoomRead.count == 1)
    }

    @Test
    func distinctEventsInOneRoomAreCountedAsMessagesAndDuplicatesAreIdempotent() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$one",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 1)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$two",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 2)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$two",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 2)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$three",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 3)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$four",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 4)

        #expect(ledger.markRoomRead(userID: "@alice:example.org", roomID: "!one:example.org")?.count == 0)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$four",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 0)
        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$five",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1) == 1)
    }

    @Test
    func aBatchedAuthoritativeRoomTotalIsClearedWhenThatRoomIsRead() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])

        #expect(ledger.applyNotification(userID: "@alice:example.org",
                                         roomID: "!one:example.org",
                                         eventID: "$fourth-delivered",
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 4) == 4)
        #expect(ledger.markRoomRead(userID: "@alice:example.org", roomID: "!one:example.org")?.count == 0)
    }

    @Test
    func reconciliationUsesUnreadMessageCountsInsteadOfUnreadRoomCount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")

        let snapshot = try #require(ledger.reconcile(userID: "@alice:example.org",
                                                     unreadCountsByRoom: ["!one:example.org": 4]))

        #expect(snapshot.count == 4)
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

    @Test
    func versionFiveRoomStateMigratesWithoutLosingItsBadge() throws {
        let fixture = try makeLedger()
        let legacyState = LegacyNotificationBadgeRoomLedgerState(userID: "@alice:example.org",
                                                                 isReconciled: true,
                                                                 revision: 7,
                                                                 unreadRoomIDs: ["!room:example.org"],
                                                                 recentAuthoritativeCount: nil,
                                                                 recentAuthoritativeDate: nil,
                                                                 recentAuthoritativeRoomIDs: nil,
                                                                 recentNotificationDates: [:],
                                                                 provisionalNotificationDates: [:],
                                                                 recentReadDates: [:])
        try fixture.userDefaults.set(JSONEncoder().encode(legacyState),
                                     forKey: "junchat.notificationBadgeRoomLedger.v5")

        #expect(fixture.ledger.snapshot(for: "@alice:example.org")?.count == 1)
        #expect(fixture.ledger.applyNotification(userID: "@alice:example.org",
                                                 roomID: "!room:example.org",
                                                 eventID: "$new",
                                                 contributesToBadge: true,
                                                 fallback: 1) == 2)
        #expect(fixture.userDefaults.data(forKey: "junchat.notificationBadgeRoomLedger.v6") != nil)
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

private struct LegacyNotificationBadgeRoomLedgerState: Codable {
    let userID: String
    let isReconciled: Bool
    let revision: UInt64
    let unreadRoomIDs: Set<String>
    let recentAuthoritativeCount: Int?
    let recentAuthoritativeDate: Date?
    let recentAuthoritativeRoomIDs: Set<String>?
    let recentNotificationDates: [String: Date]
    let provisionalNotificationDates: [String: Date]
    let recentReadDates: [String: Date]
}

extension NotificationBadgeRoomLedgerTests {
    private func serverSnapshot(total: Int, revision: String,
                                generation: String = "16a85460-6ed5-4cf9-ae72-f53689a2f831",
                                userID: String = "@alice:example.org") throws -> NotificationBadgeServerSnapshot {
        try #require(NotificationBadgeServerSnapshot(payload: [
            "badge_total": total,
            "junchat_badge_state": ["user_id": userID, "generation": generation, "revision": revision]
        ]))
    }

    @Test
    func orderedBadgeRejectsDelayedZeroAndUnversionedRoomEstimates() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        let userID = "@alice:example.org"
        ledger.prepare(for: userID)
        let first = try serverSnapshot(total: 1, revision: "2")
        #expect(ledger.reconcileServerSnapshot(first, expectedGeneration: nil)?.count == 1)
        let badge = try ledger.applyNotification(userID: userID, roomID: nil,
                                                 contributesToBadge: nil, isAuthoritative: true,
                                                 serverSnapshot: serverSnapshot(total: 0, revision: "1"), fallback: 0)
        #expect(badge == 1)
        #expect(ledger.reconcile(userID: userID, unreadCountsByRoom: [:])?.count == 1)
        #expect(ledger.applyNotification(userID: userID, roomID: nil,
                                         contributesToBadge: nil, isAuthoritative: true, fallback: 0) == 1)
        #expect(try ledger.reconcileServerSnapshot(serverSnapshot(total: 0, revision: "3"),
                                                   expectedGeneration: first.generation)?.count == 0)
    }

    @Test
    func orderedBadgeSurvivesRestartAndDoesNotExpireIntoOldCounts() throws {
        let clock = NotificationBadgeLedgerTestClock(now: Date(timeIntervalSince1970: 1000))
        let fixture = try makeLedger(now: { clock.now })
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        _ = try ledger.reconcileServerSnapshot(serverSnapshot(total: 4, revision: "9007199254740992"), expectedGeneration: nil)
        clock.advance(by: 3600)
        let reloaded = NotificationBadgeRoomLedger(userDefaults: fixture.userDefaults, lockFileURL: fixture.lockFileURL, now: { clock.now })
        #expect(reloaded.serverSnapshot(for: "@alice:example.org")?.revision == 9_007_199_254_740_992)
        #expect(reloaded.reconcile(userID: "@alice:example.org", unreadCountsByRoom: [:])?.count == 4)
        reloaded.reset()
        reloaded.prepare(for: "@bob:example.org")
        #expect(reloaded.serverSnapshot(for: "@bob:example.org") == nil)
    }

    @Test
    func differentGenerationNeedsCurrentAuthenticatedRequestAndCorrectAccount() throws {
        let fixture = try makeLedger()
        let ledger = fixture.ledger
        ledger.prepare(for: "@alice:example.org")
        let first = try serverSnapshot(total: 1, revision: "9")
        _ = ledger.reconcileServerSnapshot(first, expectedGeneration: nil)
        let next = try serverSnapshot(total: 4, revision: "1", generation: "0699601a-c63e-4c0e-a2d8-0ad5d8963502")
        #expect(ledger.applyNotification(userID: first.userID, roomID: nil, contributesToBadge: nil,
                                         isAuthoritative: true, serverSnapshot: next, fallback: 4) == 1)
        #expect(ledger.reconcileServerSnapshot(next, expectedGeneration: first.generation)?.count == 4)
        #expect(ledger.reconcileServerSnapshot(first, expectedGeneration: first.generation)?.count == 4)
        #expect(try ledger.reconcileServerSnapshot(serverSnapshot(total: 0, revision: "99", userID: "@bob:example.org"),
                                                   expectedGeneration: next.generation) == nil)
    }

    @Test(arguments: ["0", "01", "-1", "1.0", "1\n", "9223372036854775808"])
    func invalidServerRevisionIsNotCoerced(_ revision: String) {
        #expect(NotificationBadgeServerSnapshot(payload: [
            "badge_total": 1,
            "junchat_badge_state": ["user_id": "@alice:example.org",
                                    "generation": "16a85460-6ed5-4cf9-ae72-f53689a2f831", "revision": revision]
        ]) == nil)
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
