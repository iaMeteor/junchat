//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

actor PrivacyModeService: PrivacyModeServiceProtocol {
    private let userID: String
    private let transport: PrivacyModeTransportProtocol
    private let migrationStore: PrivacyModeMigrationStoreProtocol
    private let operationCoordinator: PrivacyModeOperationCoordinator
    private var claimedLegacyRoomIDs: Set<String>

    private var cachedValues = [String: Bool]()

    init(userID: String,
         transport: PrivacyModeTransportProtocol,
         migrationStore: PrivacyModeMigrationStoreProtocol,
         operationCoordinator: PrivacyModeOperationCoordinator = .shared) async {
        self.userID = userID
        self.transport = transport
        self.migrationStore = migrationStore
        self.operationCoordinator = operationCoordinator
        claimedLegacyRoomIDs = await migrationStore.claimLegacyRoomIDs(for: userID)
    }

    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard let result = await operationCoordinator.performLoad(userID: userID, roomID: roomID, operation: { [self] in
            await loadCoordinated(roomID: roomID)
        }) else {
            return .failure(.cancelled)
        }
        if case .success(let enabled) = result {
            cachedValues[roomID] = enabled
        }
        return result
    }

    func cancelLoadAndWait(roomID: String) async {
        await operationCoordinator.cancelLoadAndWait(userID: userID, roomID: roomID)
    }

    func toggle(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard let result = await operationCoordinator.perform(userID: userID, roomID: roomID, operation: { [self] in
            await toggleCoordinated(roomID: roomID)
        }) else {
            return .failure(.cancelled)
        }
        return result
    }

    func cachedValue(roomID: String) -> Bool? {
        cachedValues[roomID]
    }

    private func loadCoordinated(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        claimedLegacyRoomIDs = await migrationStore.claimLegacyRoomIDs(for: userID)
        return await loadWhileCoordinated(roomID: roomID)
    }

    private func toggleCoordinated(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        claimedLegacyRoomIDs = await migrationStore.claimLegacyRoomIDs(for: userID)

        let currentValueResult: Result<Bool, PrivacyModeServiceError>
        if let cachedValue = cachedValues[roomID] {
            currentValueResult = .success(cachedValue)
        } else {
            currentValueResult = await loadWhileCoordinated(roomID: roomID)
        }

        guard case .success(let currentValue) = currentValueResult else {
            return currentValueResult
        }

        let newValue = !currentValue
        let result: Result<Bool, PrivacyModeServiceError>
        switch await transport.setEnabled(newValue, roomID: roomID) {
        case .success:
            cachedValues[roomID] = newValue
            await consumeLegacyRoomID(roomID)
            result = .success(newValue)
        case .failure(let error):
            result = failure(for: error)
        }
        return result
    }

    private func loadWhileCoordinated(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        switch await transport.load(roomID: roomID) {
        case .success(.present(let enabled)):
            cachedValues[roomID] = enabled
            if claimedLegacyRoomIDs.contains(roomID) {
                await consumeLegacyRoomID(roomID)
            }
            return .success(enabled)
        case .success(.absent) where claimedLegacyRoomIDs.contains(roomID):
            switch await transport.setEnabled(true, roomID: roomID) {
            case .success:
                cachedValues[roomID] = true
                await consumeLegacyRoomID(roomID)
                return .success(true)
            case .failure(let error):
                return failure(for: error)
            }
        case .success(.absent):
            cachedValues[roomID] = false
            return .success(false)
        case .failure(let error):
            return failure(for: error)
        }
    }

    private func consumeLegacyRoomID(_ roomID: String) async {
        claimedLegacyRoomIDs.remove(roomID)
        await migrationStore.consumeLegacyRoomID(roomID, for: userID)
    }

    private func failure(for error: PrivacyModeTransportError) -> Result<Bool, PrivacyModeServiceError> {
        error == .cancelled ? .failure(.cancelled) : .failure(.transport(error))
    }
}
