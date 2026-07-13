//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum PrivacyModeRemoteState: Equatable {
    case absent
    case present(enabled: Bool)
}

enum PrivacyModeTransportError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
    case network
    case responseTooLarge
}

protocol PrivacyModeTransportProtocol: Sendable {
    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError>
    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError>
}

protocol PrivacyModeMigrationStoreProtocol: Sendable {
    func claimLegacyRoomIDs(for userID: String) async -> Set<String>
    func consumeLegacyRoomID(_ roomID: String, for userID: String) async
}

enum PrivacyModeServiceError: Error, Equatable {
    case cancelled
    case transport(PrivacyModeTransportError)
}

protocol PrivacyModeServiceProtocol: Sendable {
    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError>
    func toggle(roomID: String) async -> Result<Bool, PrivacyModeServiceError>
    func cachedValue(roomID: String) async -> Bool?
}
