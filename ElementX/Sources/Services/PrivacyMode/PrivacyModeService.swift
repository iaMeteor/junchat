//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

actor PrivacyModeService: PrivacyModeServiceProtocol {
    private struct RoomWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let userID: String
    private let transport: PrivacyModeTransportProtocol
    private let migrationStore: PrivacyModeMigrationStoreProtocol
    private var claimedLegacyRoomIDs: Set<String>

    private var cachedValues = [String: Bool]()
    private var lockedRoomIDs = Set<String>()
    private var roomWaiters = [String: [RoomWaiter]]()

    init(userID: String, transport: PrivacyModeTransportProtocol, migrationStore: PrivacyModeMigrationStoreProtocol) async {
        self.userID = userID
        self.transport = transport
        self.migrationStore = migrationStore
        claimedLegacyRoomIDs = await migrationStore.claimLegacyRoomIDs(for: userID)
    }

    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard await lock(roomID: roomID) else {
            return .failure(.cancelled)
        }
        guard !Task.isCancelled else {
            unlock(roomID: roomID)
            return .failure(.cancelled)
        }
        let result = await loadWhileLocked(roomID: roomID)
        unlock(roomID: roomID)
        return result
    }

    func toggle(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        guard await lock(roomID: roomID) else {
            return .failure(.cancelled)
        }
        guard !Task.isCancelled else {
            unlock(roomID: roomID)
            return .failure(.cancelled)
        }

        let currentValueResult: Result<Bool, PrivacyModeServiceError>
        if let cachedValue = cachedValues[roomID] {
            currentValueResult = .success(cachedValue)
        } else {
            currentValueResult = await loadWhileLocked(roomID: roomID)
        }

        guard case .success(let currentValue) = currentValueResult else {
            unlock(roomID: roomID)
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
            result = .failure(.transport(error))
        }

        unlock(roomID: roomID)
        return result
    }

    func cachedValue(roomID: String) -> Bool? {
        cachedValues[roomID]
    }

    private func loadWhileLocked(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
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
                return .failure(.transport(error))
            }
        case .success(.absent):
            cachedValues[roomID] = false
            return .success(false)
        case .failure(let error):
            return .failure(.transport(error))
        }
    }

    private func consumeLegacyRoomID(_ roomID: String) async {
        claimedLegacyRoomIDs.remove(roomID)
        await migrationStore.consumeLegacyRoomID(roomID, for: userID)
    }

    private func lock(roomID: String) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard lockedRoomIDs.contains(roomID) else {
            lockedRoomIDs.insert(roomID)
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                roomWaiters[roomID, default: []].append(.init(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await cancelWaiter(id: waiterID, roomID: roomID) }
        }
    }

    private func unlock(roomID: String) {
        guard var waiters = roomWaiters[roomID], !waiters.isEmpty else {
            lockedRoomIDs.remove(roomID)
            roomWaiters[roomID] = nil
            return
        }

        let nextWaiter = waiters.removeFirst()
        roomWaiters[roomID] = waiters.isEmpty ? nil : waiters
        nextWaiter.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID, roomID: String) {
        guard var waiters = roomWaiters[roomID],
              let waiterIndex = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: waiterIndex)
        roomWaiters[roomID] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: false)
    }
}
