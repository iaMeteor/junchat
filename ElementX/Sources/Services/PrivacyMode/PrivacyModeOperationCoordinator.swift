//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

actor PrivacyModeOperationCoordinator {
    static let shared = PrivacyModeOperationCoordinator()

    typealias LoadResult = Result<Bool, PrivacyModeServiceError>

    private struct Key: Hashable {
        let userID: String
        let roomID: String
    }

    private struct LockWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct LoadWaiter {
        let continuation: CheckedContinuation<LoadResult?, Never>
        var isCancelled = false
    }

    private struct LoadOperation {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters = [UUID: LoadWaiter]()
        var isCancelling = false
    }

    private var lockedKeys = Set<Key>()
    private var lockWaiters = [Key: [LockWaiter]]()
    private var unlockWaiters = [Key: [CheckedContinuation<Void, Never>]]()
    private var loadOperations = [Key: LoadOperation]()
    private var cancellationBarrierCounts = [Key: Int]()

    func performLoad(userID: String,
                     roomID: String,
                     operation: @escaping @Sendable () async -> LoadResult) async -> LoadResult? {
        guard !Task.isCancelled else {
            return nil
        }

        let key = Key(userID: userID, roomID: roomID)
        guard cancellationBarrierCounts[key] == nil else {
            return nil
        }

        let operationID: UUID
        if let loadOperation = loadOperations[key] {
            guard !loadOperation.isCancelling else {
                return nil
            }
            operationID = loadOperation.id
        } else {
            operationID = UUID()
            loadOperations[key] = LoadOperation(id: operationID)
            loadOperations[key]?.task = Task {
                let result = await self.perform(key: key, operation: operation)
                self.finishLoad(result: Task.isCancelled ? nil : result,
                                operationID: operationID,
                                key: key)
            }
        }

        let result = await waitForLoad(operationID: operationID, key: key)
        return Task.isCancelled ? nil : result
    }

    func cancelLoadAndWait(userID: String, roomID: String) async {
        let key = Key(userID: userID, roomID: roomID)
        cancellationBarrierCounts[key, default: 0] += 1
        defer { endCancellationBarrier(key: key) }

        if var loadOperation = loadOperations[key] {
            loadOperation.isCancelling = true
            loadOperations[key] = loadOperation
            loadOperation.task?.cancel()
            await loadOperation.task?.value
        }

        await waitUntilUnlocked(key: key)
    }

    func perform<T: Sendable>(userID: String,
                              roomID: String,
                              operation: @Sendable () async -> T) async -> T? {
        let key = Key(userID: userID, roomID: roomID)
        return await perform(key: key, operation: operation)
    }

    private func perform<T: Sendable>(key: Key,
                                      operation: @Sendable () async -> T) async -> T? {
        guard await lock(key: key) else {
            return nil
        }
        defer { unlock(key: key) }

        guard !Task.isCancelled else {
            return nil
        }
        return await operation()
    }

    private func waitForLoad(operationID: UUID, key: Key) async -> LoadResult? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var loadOperation = loadOperations[key], loadOperation.id == operationID else {
                    continuation.resume(returning: nil)
                    return
                }
                loadOperation.waiters[waiterID] = LoadWaiter(continuation: continuation)
                loadOperations[key] = loadOperation
            }
        } onCancel: {
            Task { await self.cancelLoadWaiter(id: waiterID, operationID: operationID, key: key) }
        }
    }

    private func finishLoad(result: LoadResult?, operationID: UUID, key: Key) {
        guard let loadOperation = loadOperations[key], loadOperation.id == operationID else {
            return
        }
        loadOperations[key] = nil

        for waiter in loadOperation.waiters.values {
            waiter.continuation.resume(returning: waiter.isCancelled ? nil : result)
        }
    }

    private func cancelLoadWaiter(id: UUID, operationID: UUID, key: Key) {
        guard var loadOperation = loadOperations[key],
              loadOperation.id == operationID,
              var waiter = loadOperation.waiters[id] else {
            return
        }

        guard loadOperation.waiters.count == 1 else {
            loadOperation.waiters[id] = nil
            loadOperations[key] = loadOperation
            waiter.continuation.resume(returning: nil)
            return
        }

        waiter.isCancelled = true
        loadOperation.waiters[id] = waiter
        loadOperation.isCancelling = true
        loadOperations[key] = loadOperation
        loadOperation.task?.cancel()
    }

    private func waitUntilUnlocked(key: Key) async {
        guard lockedKeys.contains(key) else {
            return
        }
        await withCheckedContinuation { continuation in
            unlockWaiters[key, default: []].append(continuation)
        }
    }

    private func endCancellationBarrier(key: Key) {
        guard let count = cancellationBarrierCounts[key] else {
            return
        }
        cancellationBarrierCounts[key] = count == 1 ? nil : count - 1
    }

    private func lock(key: Key) async -> Bool {
        guard !Task.isCancelled, cancellationBarrierCounts[key] == nil else {
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
                lockWaiters[key, default: []].append(.init(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, key: key) }
        }
    }

    private func unlock(key: Key) {
        if cancellationBarrierCounts[key] != nil {
            lockedKeys.remove(key)
            let cancelledWaiters = lockWaiters.removeValue(forKey: key) ?? []
            cancelledWaiters.forEach { $0.continuation.resume(returning: false) }
            let completedWaiters = unlockWaiters.removeValue(forKey: key) ?? []
            completedWaiters.forEach { $0.resume() }
            return
        }

        guard var keyWaiters = lockWaiters[key], !keyWaiters.isEmpty else {
            lockedKeys.remove(key)
            lockWaiters[key] = nil
            return
        }

        let nextWaiter = keyWaiters.removeFirst()
        lockWaiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        nextWaiter.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID, key: Key) {
        guard var keyWaiters = lockWaiters[key],
              let waiterIndex = keyWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = keyWaiters.remove(at: waiterIndex)
        lockWaiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        waiter.continuation.resume(returning: false)
    }
}
