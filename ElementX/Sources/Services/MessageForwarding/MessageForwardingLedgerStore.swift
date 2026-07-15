//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

enum MessageForwardingLedgerState: String, Codable {
    case admitting
    case admitted
    case unknown
}

struct MessageForwardingLedgerOwner: Codable, Equatable {
    private static let currentLaunchID = UUID().uuidString

    let launchID: String
    let reservationID: String

    init() {
        launchID = Self.currentLaunchID
        reservationID = UUID().uuidString
    }

    init(launchID: String, reservationID: String) {
        self.launchID = launchID
        self.reservationID = reservationID
    }
}

enum MessageForwardingLedgerMutationResult: Equatable {
    case stored
    case alreadyReserved
    case notOwner
    case capacityExceeded
    case persistenceFailed
}

enum MessageForwardingLedgerUpdate {
    case set(MessageForwardingLedgerState, item: MessageForwardingItem)
    case remove(item: MessageForwardingItem)

    var item: MessageForwardingItem {
        switch self {
        case .set(_, let item), .remove(let item):
            item
        }
    }
}

protocol MessageForwardingLedgerStoreProtocol {
    func state(accountID: String,
               destinationRoomID: String,
               item: MessageForwardingItem) -> MessageForwardingLedgerState?

    func states(accountID: String,
                destinationRoomID: String,
                items: [MessageForwardingItem]) -> [MessageForwardingLedgerState?]

    @discardableResult
    func reserveAdmissions(owner: MessageForwardingLedgerOwner,
                           accountID: String,
                           destinationRoomID: String,
                           items: [MessageForwardingItem]) -> MessageForwardingLedgerMutationResult

    @discardableResult
    func setState(_ state: MessageForwardingLedgerState,
                  owner: MessageForwardingLedgerOwner,
                  accountID: String,
                  destinationRoomID: String,
                  item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult

    @discardableResult
    func apply(_ updates: [MessageForwardingLedgerUpdate],
               owner: MessageForwardingLedgerOwner,
               accountID: String,
               destinationRoomID: String) -> MessageForwardingLedgerMutationResult

    @discardableResult
    func releaseUnknownAdmissions(owner: MessageForwardingLedgerOwner,
                                  accountID: String,
                                  destinationRoomID: String,
                                  items: [MessageForwardingItem]) -> Bool

    @discardableResult
    func removeStates(owner: MessageForwardingLedgerOwner,
                      accountID: String,
                      destinationRoomID: String,
                      items: [MessageForwardingItem],
                      includingPreviousLaunches: Bool) -> Bool
}

extension MessageForwardingLedgerStoreProtocol {
    func states(accountID: String,
                destinationRoomID: String,
                items: [MessageForwardingItem]) -> [MessageForwardingLedgerState?] {
        items.map { state(accountID: accountID, destinationRoomID: destinationRoomID, item: $0) }
    }

    func apply(_ updates: [MessageForwardingLedgerUpdate],
               owner: MessageForwardingLedgerOwner,
               accountID: String,
               destinationRoomID: String) -> MessageForwardingLedgerMutationResult {
        for update in updates {
            switch update {
            case .set(let state, let item):
                let result = setState(state,
                                      owner: owner,
                                      accountID: accountID,
                                      destinationRoomID: destinationRoomID,
                                      item: item)
                guard result == .stored else { return result }
            case .remove(let item):
                guard removeStates(owner: owner,
                                   accountID: accountID,
                                   destinationRoomID: destinationRoomID,
                                   items: [item],
                                   includingPreviousLaunches: false) else {
                    return .notOwner
                }
            }
        }
        return .stored
    }
}

struct MessageForwardingLedgerStore: MessageForwardingLedgerStoreProtocol {
    private static let keyPrefix = "junchat.message-forwarding-ledger.v1."
    static let defaultMaximumEntryCount = 1000
    private static let mutationLock = NSLock()

    private let userDefaults: UserDefaults
    private let storage: UserDefaultsStorage<Ledger>
    private let maximumEntryCount: Int

    init(userDefaults: UserDefaults, maximumEntryCount: Int = Self.defaultMaximumEntryCount) {
        precondition(maximumEntryCount > 0)
        self.userDefaults = userDefaults
        storage = UserDefaultsStorage(userDefaults: userDefaults)
        self.maximumEntryCount = maximumEntryCount
    }

    func state(accountID: String,
               destinationRoomID: String,
               item: MessageForwardingItem) -> MessageForwardingLedgerState? {
        states(accountID: accountID, destinationRoomID: destinationRoomID, items: [item]).first ?? nil
    }

    func states(accountID: String,
                destinationRoomID: String,
                items: [MessageForwardingItem]) -> [MessageForwardingLedgerState?] {
        Self.mutationLock.withLock {
            switch loadLedger(forKey: storageKey(accountID: accountID)) {
            case .missing:
                return Array(repeating: nil, count: items.count)
            case .loaded(let ledger):
                let destination = ledger.destinations[fingerprint([destinationRoomID])]
                return items.map { destination?[itemFingerprint($0)]?.visibleState }
            case .corrupt:
                return Array(repeating: .unknown, count: items.count)
            }
        }
    }

    func reserveAdmissions(owner: MessageForwardingLedgerOwner,
                           accountID: String,
                           destinationRoomID: String,
                           items: [MessageForwardingItem]) -> MessageForwardingLedgerMutationResult {
        guard items.count <= MessageForwardingBatch.maximumItemCount else { return .capacityExceeded }
        guard !items.isEmpty else { return .stored }

        return Self.mutationLock.withLock {
            let key = storageKey(accountID: accountID)
            let destinationKey = fingerprint([destinationRoomID])
            var ledger: Ledger
            switch loadLedger(forKey: key) {
            case .missing:
                ledger = Ledger()
            case .loaded(let storedLedger):
                ledger = storedLedger
            case .corrupt:
                return .persistenceFailed
            }

            let itemKeys = Set(items.map(itemFingerprint))
            let destination = ledger.destinations[destinationKey] ?? [:]
            let existingEntries = itemKeys.compactMap { destination[$0] }
            guard existingEntries.allSatisfy({ entry in
                entry.isSafeReservation && entry.owner?.launchID != owner.launchID
            }) else {
                return .alreadyReserved
            }

            let newEntryCount = itemKeys.count - existingEntries.count
            guard ledger.entryCount <= maximumEntryCount - newEntryCount else {
                return .capacityExceeded
            }

            for itemKey in itemKeys {
                ledger.destinations[destinationKey, default: [:]][itemKey] = .init(state: .admitting,
                                                                                   owner: owner,
                                                                                   admissionStarted: false)
            }
            return persist(ledger, forKey: key) ? .stored : .persistenceFailed
        }
    }

    func setState(_ state: MessageForwardingLedgerState,
                  owner: MessageForwardingLedgerOwner,
                  accountID: String,
                  destinationRoomID: String,
                  item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult {
        Self.mutationLock.withLock {
            let key = storageKey(accountID: accountID)
            let destinationKey = fingerprint([destinationRoomID])
            let itemKey = itemFingerprint(item)
            var ledger: Ledger
            switch loadLedger(forKey: key) {
            case .missing:
                return .notOwner
            case .loaded(let storedLedger):
                ledger = storedLedger
            case .corrupt:
                return .persistenceFailed
            }

            guard var entry = ledger.destinations[destinationKey]?[itemKey], entry.owner == owner else {
                return .notOwner
            }

            entry.state = state
            entry.admissionStarted = true
            ledger.destinations[destinationKey]?[itemKey] = entry
            return persist(ledger, forKey: key) ? .stored : .persistenceFailed
        }
    }

    func apply(_ updates: [MessageForwardingLedgerUpdate],
               owner: MessageForwardingLedgerOwner,
               accountID: String,
               destinationRoomID: String) -> MessageForwardingLedgerMutationResult {
        guard !updates.isEmpty else { return .stored }

        return Self.mutationLock.withLock {
            let key = storageKey(accountID: accountID)
            let destinationKey = fingerprint([destinationRoomID])
            var ledger: Ledger
            switch loadLedger(forKey: key) {
            case .missing:
                return updates.allSatisfy { update in
                    if case .remove = update { true } else { false }
                } ? .stored : .notOwner
            case .loaded(let storedLedger):
                ledger = storedLedger
            case .corrupt:
                return .persistenceFailed
            }

            for update in updates {
                let itemKey = itemFingerprint(update.item)
                switch update {
                case .set:
                    guard ledger.destinations[destinationKey]?[itemKey]?.owner == owner else { return .notOwner }
                case .remove:
                    guard let entry = ledger.destinations[destinationKey]?[itemKey] else { continue }
                    guard entry.owner == owner else { return .notOwner }
                }
            }

            for update in updates {
                let itemKey = itemFingerprint(update.item)
                switch update {
                case .set(let state, _):
                    ledger.destinations[destinationKey]?[itemKey]?.state = state
                    ledger.destinations[destinationKey]?[itemKey]?.admissionStarted = true
                case .remove:
                    ledger.destinations[destinationKey]?.removeValue(forKey: itemKey)
                }
            }

            if ledger.destinations[destinationKey]?.isEmpty == true {
                ledger.destinations.removeValue(forKey: destinationKey)
            }
            return persist(ledger.destinations.isEmpty ? nil : ledger, forKey: key) ? .stored : .persistenceFailed
        }
    }

    func releaseUnknownAdmissions(owner: MessageForwardingLedgerOwner,
                                  accountID: String,
                                  destinationRoomID: String,
                                  items: [MessageForwardingItem]) -> Bool {
        guard !items.isEmpty else { return true }

        return Self.mutationLock.withLock {
            let key = storageKey(accountID: accountID)
            let destinationKey = fingerprint([destinationRoomID])
            var ledger: Ledger
            switch loadLedger(forKey: key) {
            case .missing, .corrupt:
                return false
            case .loaded(let storedLedger):
                ledger = storedLedger
            }
            guard var destination = ledger.destinations[destinationKey] else {
                return false
            }

            let itemKeys = Set(items.map(itemFingerprint))
            for itemKey in itemKeys {
                guard let entry = destination[itemKey], entry.owner == owner, entry.state == .unknown else {
                    return false
                }
            }

            for itemKey in itemKeys {
                destination[itemKey]?.owner = nil
            }
            ledger.destinations[destinationKey] = destination
            return persist(ledger, forKey: key)
        }
    }

    func removeStates(owner: MessageForwardingLedgerOwner,
                      accountID: String,
                      destinationRoomID: String,
                      items: [MessageForwardingItem],
                      includingPreviousLaunches: Bool) -> Bool {
        guard !items.isEmpty else { return true }

        return Self.mutationLock.withLock {
            let key = storageKey(accountID: accountID)
            let destinationKey = fingerprint([destinationRoomID])
            var ledger: Ledger
            switch loadLedger(forKey: key) {
            case .missing:
                return true
            case .loaded(let storedLedger):
                ledger = storedLedger
            case .corrupt:
                return false
            }
            guard var destination = ledger.destinations[destinationKey] else {
                return true
            }

            let itemKeys = Set(items.map(itemFingerprint))
            for itemKey in itemKeys {
                guard let entry = destination[itemKey], entry.owner != owner else { continue }
                let isFromPreviousLaunch = entry.owner == nil || entry.owner?.launchID != owner.launchID
                guard includingPreviousLaunches, isFromPreviousLaunch else { return false }
            }

            for itemKey in itemKeys {
                destination.removeValue(forKey: itemKey)
            }

            if destination.isEmpty {
                ledger.destinations.removeValue(forKey: destinationKey)
            } else {
                ledger.destinations[destinationKey] = destination
            }

            return persist(ledger.destinations.isEmpty ? nil : ledger, forKey: key)
        }
    }

    private func persist(_ ledger: Ledger?, forKey key: String) -> Bool {
        storage[key] = ledger
        return storage[key] == ledger
    }

    private func loadLedger(forKey key: String) -> LedgerLoadResult {
        if let ledger = storage[key] {
            return .loaded(ledger)
        }
        return userDefaults.object(forKey: key) == nil ? .missing : .corrupt
    }

    private func storageKey(accountID: String) -> String {
        Self.keyPrefix + fingerprint([accountID])
    }

    private func itemFingerprint(_ item: MessageForwardingItem) -> String {
        let identifier: String
        switch item.id.eventOrTransactionID {
        case .eventID(let eventID):
            identifier = "event:\(eventID)"
        case .transactionID(let transactionID):
            identifier = "transaction:\(transactionID)"
        case nil:
            identifier = "timeline:\(item.id.uniqueID.value)"
        }
        return fingerprint([item.roomID, identifier])
    }

    private func fingerprint(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let valueData = Data(value.utf8)
            data.append(Data("\(valueData.count):".utf8))
            data.append(valueData)
        }
        return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum LedgerLoadResult {
    case missing
    case loaded(Ledger)
    case corrupt
}

private struct Ledger: Codable, Equatable {
    var destinations = [String: [String: LedgerEntry]]()

    var entryCount: Int {
        destinations.values.reduce(0) { $0 + $1.count }
    }
}

private struct LedgerEntry: Codable, Equatable {
    var state: MessageForwardingLedgerState
    var owner: MessageForwardingLedgerOwner?
    var admissionStarted: Bool

    var isSafeReservation: Bool {
        state == .admitting && !admissionStarted
    }

    var visibleState: MessageForwardingLedgerState? {
        isSafeReservation ? nil : state
    }

    init(state: MessageForwardingLedgerState,
         owner: MessageForwardingLedgerOwner?,
         admissionStarted: Bool = true) {
        self.state = state
        self.owner = owner
        self.admissionStarted = admissionStarted
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let legacyState = try? container.decode(MessageForwardingLedgerState.self) {
            self.init(state: legacyState, owner: nil)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(state: container.decode(MessageForwardingLedgerState.self, forKey: .state),
                      owner: container.decodeIfPresent(MessageForwardingLedgerOwner.self, forKey: .owner),
                      admissionStarted: container.decodeIfPresent(Bool.self, forKey: .admissionStarted) ?? true)
    }
}
