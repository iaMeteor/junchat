//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class PrivacyModeMigrationStore: PrivacyModeMigrationStoreProtocol, @unchecked Sendable {
    private struct Claim {
        let ownerUserID: String
        var pendingRoomIDs: Set<String>
    }

    private static let lock = NSLock()
    private static let claimKey = "junchatPrivacyModeMigrationClaimV1"
    private static let legacyRoomIDsKey = "junchatPrivacyModeRoomIDs"
    private static let ownerUserIDKey = "ownerUserID"
    private static let pendingRoomIDsKey = "pendingRoomIDs"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func claimLegacyRoomIDs(for userID: String) async -> Set<String> {
        Self.lock.withLock {
            let claim: Claim
            if let existingClaim = loadClaim() {
                claim = existingClaim
            } else {
                claim = Claim(ownerUserID: userID, pendingRoomIDs: loadLegacyRoomIDs())
                saveClaim(claim)
                userDefaults.removeObject(forKey: Self.legacyRoomIDsKey)
            }
            return claim.ownerUserID == userID ? claim.pendingRoomIDs : []
        }
    }

    func consumeLegacyRoomID(_ roomID: String, for userID: String) async {
        Self.lock.withLock {
            guard var claim = loadClaim(), claim.ownerUserID == userID else {
                return
            }
            claim.pendingRoomIDs.remove(roomID)
            saveClaim(claim)
        }
    }

    private func loadClaim() -> Claim? {
        guard let value = userDefaults.dictionary(forKey: Self.claimKey),
              let ownerUserID = value[Self.ownerUserIDKey] as? String,
              let pendingRoomIDs = value[Self.pendingRoomIDsKey] as? [String] else {
            return nil
        }
        return Claim(ownerUserID: ownerUserID, pendingRoomIDs: Set(pendingRoomIDs))
    }

    private func saveClaim(_ claim: Claim) {
        userDefaults.set([Self.ownerUserIDKey: claim.ownerUserID,
                          Self.pendingRoomIDsKey: Array(claim.pendingRoomIDs)],
                         forKey: Self.claimKey)
    }

    private func loadLegacyRoomIDs() -> Set<String> {
        userDefaults.data(forKey: Self.legacyRoomIDsKey)
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }
}
