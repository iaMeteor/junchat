//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct VerificationPromptDecisionStoreTests {
    @Test
    func persistsPermanentHideAcrossStoreInstancesWithAStableNonPlaintextKey() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let userID = "@alice:example.org"

        let store = VerificationPromptDecisionStore(userDefaults: userDefaults)
        #expect(!store.isPermanentlyHidden(for: userID))

        store.hidePermanently(for: userID)

        #expect(VerificationPromptDecisionStore(userDefaults: userDefaults).isPermanentlyHidden(for: userID))
        let storedKeys = userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("junchat.verification-prompt.hidden.v1.") }
        #expect(storedKeys == [
            "junchat.verification-prompt.hidden.v1.7bb639364c5a6a8d4f730f8b204692062e11ad8ab3d4e924284ec52bffbd18e04488a9c69cdb9506d5fde32816576cccb7846fcd274f845304c7da1c898e0021"
        ])
        #expect(storedKeys.allSatisfy { !$0.contains(userID) })
    }

    @Test
    func isolatesDecisionsByMatrixAccount() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = VerificationPromptDecisionStore(userDefaults: userDefaults)

        store.hidePermanently(for: "@alice:example.org")

        #expect(store.isPermanentlyHidden(for: "@alice:example.org"))
        #expect(!store.isPermanentlyHidden(for: "@bob:example.org"))
        #expect(!store.isPermanentlyHidden(for: "@alice:elsewhere.org"))
    }

    @Test
    func logoutResetKeepsDecisionButDoesNotMigrateLegacyCompletion() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let userID = "@alice:example.org"
        userDefaults.set(true, forKey: "hasRunIdentityConfirmationOnboarding")

        #expect(!store.isPermanentlyHidden(for: userID))
        store.hidePermanently(for: userID)

        AppSettings.resetSessionSpecificSettings(userDefaults: userDefaults)

        #expect(userDefaults.object(forKey: "hasRunIdentityConfirmationOnboarding") == nil)
        #expect(store.isPermanentlyHidden(for: userID))
    }

    @Test
    func reinstallStoreResetRestoresTheDefaultDecision() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let userID = "@alice:example.org"
        let store = VerificationPromptDecisionStore(userDefaults: userDefaults)
        store.hidePermanently(for: userID)

        userDefaults.removePersistentDomain(forName: suiteName)

        #expect(!VerificationPromptDecisionStore(userDefaults: userDefaults).isPermanentlyHidden(for: userID))
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "io.element.elementx.verification-prompt-tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }
}
