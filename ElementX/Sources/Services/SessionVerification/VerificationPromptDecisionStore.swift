//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

protocol VerificationPromptDecisionStoreProtocol {
    func isPermanentlyHidden(for userID: String) -> Bool
    func hidePermanently(for userID: String)
}

struct VerificationPromptDecisionStore: VerificationPromptDecisionStoreProtocol {
    private static let keyPrefix = "junchat.verification-prompt.hidden.v1."

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func isPermanentlyHidden(for userID: String) -> Bool {
        userDefaults.bool(forKey: key(for: userID))
    }

    func hidePermanently(for userID: String) {
        userDefaults.set(true, forKey: key(for: userID))
    }

    private func key(for userID: String) -> String {
        let digest = SHA512.hash(data: Data(userID.utf8))
        return Self.keyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}
