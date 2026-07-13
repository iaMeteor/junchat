//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

actor PrivacyModeOperationCoordinator {
    static let shared = PrivacyModeOperationCoordinator()

    private struct Key: Hashable {
        let userID: String
        let roomID: String
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var lockedKeys = Set<Key>()
    private var waiters = [Key: [Waiter]]()

    func perform<T: Sendable>(userID: String,
                              roomID: String,
                              operation: @Sendable () async -> T) async -> T? {
        let key = Key(userID: userID, roomID: roomID)
        guard await lock(key: key) else {
            return nil
        }
        defer { unlock(key: key) }

        guard !Task.isCancelled else {
            return nil
        }
        return await operation()
    }

    private func lock(key: Key) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard lockedKeys.contains(key) else {
            lockedKeys.insert(key)
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[key, default: []].append(.init(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, key: key) }
        }
    }

    private func unlock(key: Key) {
        guard var keyWaiters = waiters[key], !keyWaiters.isEmpty else {
            lockedKeys.remove(key)
            waiters[key] = nil
            return
        }

        let nextWaiter = keyWaiters.removeFirst()
        waiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        nextWaiter.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID, key: Key) {
        guard var keyWaiters = waiters[key],
              let waiterIndex = keyWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = keyWaiters.remove(at: waiterIndex)
        waiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        waiter.continuation.resume(returning: false)
    }
}
