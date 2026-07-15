//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct MessageForwardingLedgerStoreTests {
    @Test
    func restoresAdmissionAfterStoreReconstruction() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let item = makeItem(eventID: "$event")
        let owner = MessageForwardingLedgerOwner()

        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [item]) == .stored)
        #expect(store.setState(.admitted,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!destination:example.org",
                               item: item) == .stored)

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: item) == .admitted)
    }

    @Test
    func isolatesAccountsDestinationsAndItems() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let item = makeItem(eventID: "$event")
        let otherItem = makeItem(eventID: "$other-event")
        let owner = MessageForwardingLedgerOwner()

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [item]) == .stored)

        #expect(store.state(accountID: "@bob:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: item) == nil)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!other-destination:example.org",
                            item: item) == nil)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: otherItem) == nil)
    }

    @Test
    func removesRequestedAdmissionsAndCleansEmptyLedger() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let firstItem = makeItem(eventID: "$first")
        let secondItem = makeItem(eventID: "$second")
        let owner = MessageForwardingLedgerOwner()

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [firstItem, secondItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!destination:example.org",
                               item: firstItem) == .stored)
        #expect(store.setState(.unknown,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!destination:example.org",
                               item: secondItem) == .stored)

        #expect(store.removeStates(owner: owner,
                                   accountID: "@alice:example.org",
                                   destinationRoomID: "!destination:example.org",
                                   items: [firstItem],
                                   includingPreviousLaunches: false))
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: firstItem) == nil)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: secondItem) == .unknown)

        #expect(store.removeStates(owner: owner,
                                   accountID: "@alice:example.org",
                                   destinationRoomID: "!destination:example.org",
                                   items: [secondItem],
                                   includingPreviousLaunches: false))
        let domain = testDefaults.userDefaults.persistentDomain(forName: testDefaults.suiteName)
        #expect(domain == nil || domain?.isEmpty == true)
    }

    @Test
    func persistsNoRawMatrixIdentifiers() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let identifiers = ["@alice:example.org", "!destination:example.org", "!source:example.org", "$event:example.org"]
        let item = makeItem(eventID: identifiers[3], sourceRoomID: identifiers[2])
        let owner = MessageForwardingLedgerOwner()

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: identifiers[0],
                                        destinationRoomID: identifiers[1],
                                        items: [item]) == .stored)
        #expect(store.setState(.admitted,
                               owner: owner,
                               accountID: identifiers[0],
                               destinationRoomID: identifiers[1],
                               item: item) == .stored)

        let persistedDescription = String(describing: testDefaults.userDefaults.persistentDomain(forName: testDefaults.suiteName))
        for identifier in identifiers {
            #expect(!persistedDescription.contains(identifier))
        }
    }

    @Test
    func capacityIsAccountWideAndPersistsWithoutEvictingAdmissions() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let firstItem = makeItem(eventID: "$first")
        let secondItem = makeItem(eventID: "$second")
        let refusedItem = makeItem(eventID: "$refused")
        let owner = MessageForwardingLedgerOwner()
        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults, maximumEntryCount: 2)

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!first-destination:example.org",
                                        items: [firstItem]) == .stored)
        #expect(store.setState(.unknown,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!first-destination:example.org",
                               item: firstItem) == .stored)
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!second-destination:example.org",
                                        items: [secondItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!second-destination:example.org",
                               item: secondItem) == .stored)

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults, maximumEntryCount: 2)

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!third-destination:example.org",
                                        items: [refusedItem]) == .capacityExceeded)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!first-destination:example.org",
                            item: firstItem) == .unknown)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!second-destination:example.org",
                            item: secondItem) == .admitted)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!third-destination:example.org",
                            item: refusedItem) == nil)
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@bob:example.org",
                                        destinationRoomID: "!third-destination:example.org",
                                        items: [refusedItem]) == .stored)
    }

    @Test
    func capacityAllowsMutatingExistingAdmissionsAndRemovalFreesSpace() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults, maximumEntryCount: 1)
        let firstItem = makeItem(eventID: "$first")
        let secondItem = makeItem(eventID: "$second")
        let owner = MessageForwardingLedgerOwner()

        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [firstItem]) == .stored)
        #expect(store.setState(.unknown,
                               owner: owner,
                               accountID: "@alice:example.org",
                               destinationRoomID: "!destination:example.org",
                               item: firstItem) == .stored)
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [secondItem]) == .capacityExceeded)
        #expect(store.state(accountID: "@alice:example.org",
                            destinationRoomID: "!destination:example.org",
                            item: firstItem) == .unknown)

        #expect(store.removeStates(owner: owner,
                                   accountID: "@alice:example.org",
                                   destinationRoomID: "!destination:example.org",
                                   items: [firstItem],
                                   includingPreviousLaunches: false))
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: "@alice:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: [secondItem]) == .stored)
    }

    @Test
    func enforcesThe150MessageAdmissionLimitAtomically() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults, maximumEntryCount: 1000)
        let acceptedItems = (1...150).map { makeItem(eventID: "$accepted-\($0)") }
        let rejectedItems = (1...151).map { makeItem(eventID: "$rejected-\($0)") }

        #expect(store.reserveAdmissions(owner: .init(),
                                        accountID: "@accepted:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: acceptedItems) == .stored)
        #expect(store.reserveAdmissions(owner: .init(),
                                        accountID: "@rejected:example.org",
                                        destinationRoomID: "!destination:example.org",
                                        items: rejectedItems) == .capacityExceeded)
        #expect(rejectedItems.allSatisfy { item in
            store.state(accountID: "@rejected:example.org",
                        destinationRoomID: "!destination:example.org",
                        item: item) == nil
        })
    }

    @Test
    func corruptLedgerFailsClosedWithoutReplacingUncertainAdmissions() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let otherDestinationRoomID = "!other-destination:example.org"
        let admittedItem = makeItem(eventID: "$admitted")
        let otherAdmittedItem = makeItem(eventID: "$other-admitted")
        let newItem = makeItem(eventID: "$new")
        let owner = MessageForwardingLedgerOwner()
        let otherOwner = MessageForwardingLedgerOwner()
        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        #expect(store.reserveAdmissions(owner: owner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [admittedItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: owner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: admittedItem) == .stored)
        #expect(store.reserveAdmissions(owner: otherOwner,
                                        accountID: accountID,
                                        destinationRoomID: otherDestinationRoomID,
                                        items: [otherAdmittedItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: otherOwner,
                               accountID: accountID,
                               destinationRoomID: otherDestinationRoomID,
                               item: otherAdmittedItem) == .stored)
        let domain = try #require(testDefaults.userDefaults.persistentDomain(forName: testDefaults.suiteName))
        let ledgerKey = try #require(domain.keys.first)
        let corruptLedger = Data("not-a-forwarding-ledger".utf8)
        testDefaults.userDefaults.set(corruptLedger, forKey: ledgerKey)
        #expect(testDefaults.userDefaults.synchronize())

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.state(accountID: accountID,
                            destinationRoomID: destinationRoomID,
                            item: admittedItem) == .unknown)
        #expect(!store.removeStates(owner: owner,
                                    accountID: accountID,
                                    destinationRoomID: destinationRoomID,
                                    items: [admittedItem],
                                    includingPreviousLaunches: false))
        #expect(store.setState(.admitting,
                               owner: owner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: newItem) == .persistenceFailed)
        #expect(store.state(accountID: accountID,
                            destinationRoomID: otherDestinationRoomID,
                            item: otherAdmittedItem) == .unknown)
        #expect(store.apply([.remove(item: otherAdmittedItem)],
                            owner: otherOwner,
                            accountID: accountID,
                            destinationRoomID: otherDestinationRoomID) == .persistenceFailed)
        #expect(testDefaults.userDefaults.data(forKey: ledgerKey) == corruptLedger)
    }

    @Test
    func existingReservationRejectsNonOwnerTransitionsAndRemoval() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let firstStore = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let secondStore = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let item = makeItem(eventID: "$exclusive")
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let firstOwner = MessageForwardingLedgerOwner()
        let secondOwner = MessageForwardingLedgerOwner()

        #expect(firstStore.reserveAdmissions(owner: firstOwner,
                                             accountID: accountID,
                                             destinationRoomID: destinationRoomID,
                                             items: [item]) == .stored)
        #expect(firstStore.setState(.admitting,
                                    owner: firstOwner,
                                    accountID: accountID,
                                    destinationRoomID: destinationRoomID,
                                    item: item) == .stored)
        #expect(secondStore.reserveAdmissions(owner: secondOwner,
                                              accountID: accountID,
                                              destinationRoomID: destinationRoomID,
                                              items: [item]) == .alreadyReserved)
        #expect(secondStore.setState(.unknown,
                                     owner: secondOwner,
                                     accountID: accountID,
                                     destinationRoomID: destinationRoomID,
                                     item: item) == .notOwner)
        #expect(!secondStore.removeStates(owner: secondOwner,
                                          accountID: accountID,
                                          destinationRoomID: destinationRoomID,
                                          items: [item],
                                          includingPreviousLaunches: false))
        #expect(!secondStore.removeStates(owner: secondOwner,
                                          accountID: accountID,
                                          destinationRoomID: destinationRoomID,
                                          items: [item],
                                          includingPreviousLaunches: true))
        #expect(firstStore.state(accountID: accountID,
                                 destinationRoomID: destinationRoomID,
                                 item: item) == .admitting)
    }

    @Test
    func previousLaunchCanReclaimAdmissionsThatNeverReachedTheSDK() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let firstItem = makeItem(eventID: "$first-safe-reservation")
        let secondItem = makeItem(eventID: "$second-safe-reservation")
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let previousOwner = MessageForwardingLedgerOwner(launchID: "previous-launch", reservationID: "previous-reservation")
        let currentOwner = MessageForwardingLedgerOwner(launchID: "current-launch", reservationID: "current-reservation")
        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.reserveAdmissions(owner: previousOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [firstItem, secondItem]) == .stored)
        #expect(store.states(accountID: accountID,
                             destinationRoomID: destinationRoomID,
                             items: [firstItem, secondItem]) == [nil, nil])

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        #expect(store.reserveAdmissions(owner: currentOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [firstItem, secondItem]) == .stored)
        #expect(store.setState(.admitting,
                               owner: currentOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: firstItem) == .stored)
        #expect(store.states(accountID: accountID,
                             destinationRoomID: destinationRoomID,
                             items: [firstItem, secondItem]) == [.admitting, nil])
    }

    @Test
    func restorationSeparatesSameLaunchForeignOwnersFromPreviousLaunchAdmissions() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let currentOwner = MessageForwardingLedgerOwner(launchID: "current-launch", reservationID: "current")
        let foreignOwner = MessageForwardingLedgerOwner(launchID: "current-launch", reservationID: "foreign")
        let previousOwner = MessageForwardingLedgerOwner(launchID: "previous-launch", reservationID: "previous")
        let currentSafeItem = makeItem(eventID: "$current-safe")
        let foreignSafeItem = makeItem(eventID: "$foreign-safe")
        let foreignAdmittedItem = makeItem(eventID: "$foreign-admitted")
        let previousSafeItem = makeItem(eventID: "$previous-safe")
        let previousAdmittedItem = makeItem(eventID: "$previous-admitted")

        #expect(store.reserveAdmissions(owner: currentOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [currentSafeItem]) == .stored)
        #expect(store.reserveAdmissions(owner: foreignOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [foreignSafeItem, foreignAdmittedItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: foreignOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: foreignAdmittedItem) == .stored)
        #expect(store.reserveAdmissions(owner: previousOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [previousSafeItem, previousAdmittedItem]) == .stored)
        #expect(store.setState(.admitted,
                               owner: previousOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: previousAdmittedItem) == .stored)

        #expect(store.restorationStates(owner: currentOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [currentSafeItem,
                                                foreignSafeItem,
                                                foreignAdmittedItem,
                                                previousSafeItem,
                                                previousAdmittedItem]) == [
                .state(.admitting),
                .sameLaunchForeignOwner,
                .sameLaunchForeignOwner,
                nil,
                .state(.admitted)
            ])
    }

    @Test
    func previousLaunchReservationRequiresExplicitResolution() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let item = makeItem(eventID: "$previous-launch")
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let previousOwner = MessageForwardingLedgerOwner(launchID: "previous-launch", reservationID: "reservation")
        let currentOwner = MessageForwardingLedgerOwner(launchID: "current-launch", reservationID: "reservation")
        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.reserveAdmissions(owner: previousOwner,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [item]) == .stored)
        #expect(store.setState(.unknown,
                               owner: previousOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: item) == .stored)

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.setState(.admitted,
                               owner: currentOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: item) == .notOwner)
        #expect(!store.removeStates(owner: currentOwner,
                                    accountID: accountID,
                                    destinationRoomID: destinationRoomID,
                                    items: [item],
                                    includingPreviousLaunches: false))
        #expect(store.removeStates(owner: currentOwner,
                                   accountID: accountID,
                                   destinationRoomID: destinationRoomID,
                                   items: [item],
                                   includingPreviousLaunches: true))
        #expect(store.state(accountID: accountID,
                            destinationRoomID: destinationRoomID,
                            item: item) == nil)
    }

    @Test
    func legacyReservationDecodesAndRequiresExplicitResolution() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let item = makeItem(eventID: "$legacy")
        let accountID = "@alice:example.org"
        let destinationRoomID = "!destination:example.org"
        let legacyWriter = MessageForwardingLedgerOwner(launchID: "legacy-writer", reservationID: "reservation")
        let currentOwner = MessageForwardingLedgerOwner(launchID: "current-launch", reservationID: "reservation")
        var store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)
        #expect(store.reserveAdmissions(owner: legacyWriter,
                                        accountID: accountID,
                                        destinationRoomID: destinationRoomID,
                                        items: [item]) == .stored)

        let domain = try #require(testDefaults.userDefaults.persistentDomain(forName: testDefaults.suiteName))
        let ledgerKey = try #require(domain.keys.first)
        let encodedLedger = try #require(testDefaults.userDefaults.data(forKey: ledgerKey))
        var ledger = try #require(JSONSerialization.jsonObject(with: encodedLedger) as? [String: Any])
        var destinations = try #require(ledger["destinations"] as? [String: Any])
        let destinationKey = try #require(destinations.keys.first)
        var destination = try #require(destinations[destinationKey] as? [String: Any])
        let itemKey = try #require(destination.keys.first)
        destination[itemKey] = MessageForwardingLedgerState.unknown.rawValue
        destinations[destinationKey] = destination
        ledger["destinations"] = destinations
        try testDefaults.userDefaults.set(JSONSerialization.data(withJSONObject: ledger), forKey: ledgerKey)
        #expect(testDefaults.userDefaults.synchronize())

        store = MessageForwardingLedgerStore(userDefaults: testDefaults.userDefaults)

        #expect(store.state(accountID: accountID,
                            destinationRoomID: destinationRoomID,
                            item: item) == .unknown)
        #expect(store.setState(.admitted,
                               owner: currentOwner,
                               accountID: accountID,
                               destinationRoomID: destinationRoomID,
                               item: item) == .notOwner)
        #expect(!store.removeStates(owner: currentOwner,
                                    accountID: accountID,
                                    destinationRoomID: destinationRoomID,
                                    items: [item],
                                    includingPreviousLaunches: false))
        #expect(store.removeStates(owner: currentOwner,
                                   accountID: accountID,
                                   destinationRoomID: destinationRoomID,
                                   items: [item],
                                   includingPreviousLaunches: true))
    }

    @Test
    func concurrentReservationLoopsAdmitExactlyOneClaimant() throws {
        let testDefaults = try makeTestDefaults()
        defer { testDefaults.cleanup() }
        let runners = [
            LedgerReservationRunner(store: .init(userDefaults: testDefaults.userDefaults), owner: .init()),
            LedgerReservationRunner(store: .init(userDefaults: testDefaults.userDefaults), owner: .init())
        ]
        var storedCounts = [Int]()

        for iteration in 0..<50 {
            let item = makeItem(eventID: "$concurrent-\(iteration)")
            let results = LedgerReservationResults()
            DispatchQueue.concurrentPerform(iterations: runners.count) { index in
                results.append(runners[index].reserve(item: item))
            }
            storedCounts.append(results.values.count { $0 == .stored })
        }

        #expect(storedCounts == Array(repeating: 1, count: 50))
    }

    private func makeItem(eventID: String, sourceRoomID: String = "!source:example.org") -> MessageForwardingItem {
        MessageForwardingItem(id: .event(uniqueID: .init(eventID), eventOrTransactionID: .eventID(eventID)),
                              roomID: sourceRoomID,
                              content: .init(noHandle: .init()))
    }

    private func makeTestDefaults() throws -> TestUserDefaults {
        let suiteName = "MessageForwardingLedgerStoreTests.\(UUID().uuidString)"
        return try TestUserDefaults(suiteName: suiteName)
    }
}

private final class LedgerReservationRunner: @unchecked Sendable {
    private let store: MessageForwardingLedgerStore
    private let owner: MessageForwardingLedgerOwner

    init(store: MessageForwardingLedgerStore, owner: MessageForwardingLedgerOwner) {
        self.store = store
        self.owner = owner
    }

    func reserve(item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult {
        store.reserveAdmissions(owner: owner,
                                accountID: "@alice:example.org",
                                destinationRoomID: "!destination:example.org",
                                items: [item])
    }
}

private final class LedgerReservationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results = [MessageForwardingLedgerMutationResult]()

    var values: [MessageForwardingLedgerMutationResult] {
        lock.withLock { results }
    }

    func append(_ result: MessageForwardingLedgerMutationResult) {
        lock.withLock { results.append(result) }
    }
}

private struct TestUserDefaults {
    let suiteName: String
    let userDefaults: UserDefaults

    init(suiteName: String) throws {
        self.suiteName = suiteName
        userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
