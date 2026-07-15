//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias MessageForwardingScreenViewModelType = StateStoreViewModel<MessageForwardingScreenViewState, MessageForwardingScreenViewAction>

class MessageForwardingScreenViewModel: MessageForwardingScreenViewModelType, MessageForwardingScreenViewModelProtocol {
    private let forwardingBatch: MessageForwardingBatch
    private let clientProxy: ClientProxyProtocol
    private let roomSummaryProvider: RoomSummaryProviderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let ledgerStore: MessageForwardingLedgerStoreProtocol
    private let ledgerOwner: MessageForwardingLedgerOwner
    private var forwardingOperations: [MessageForwardingOperation]
    private var forwardTask: Task<Void, Never>?
    private var isCancellationRequested = false
    private var shouldDismissAfterCancellation = false
    private var shouldReleaseOwnerAfterCancellation = false
    private var forwardingGeneration = 0

    private var actionsSubject: PassthroughSubject<MessageForwardingScreenViewModelAction, Never> = .init()

    var actions: AnyPublisher<MessageForwardingScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(forwardingBatch: MessageForwardingBatch,
         userSession: UserSessionProtocol,
         roomSummaryProvider: RoomSummaryProviderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         ledgerStore: MessageForwardingLedgerStoreProtocol = MessageForwardingLedgerStore(userDefaults: AppSettings.sharedUserDefaults),
         ledgerOwner: MessageForwardingLedgerOwner = .init(),
         notificationCenter: NotificationCenter = .default) {
        self.forwardingBatch = forwardingBatch
        forwardingOperations = forwardingBatch.items.map { MessageForwardingOperation(item: $0) }
        clientProxy = userSession.clientProxy
        self.roomSummaryProvider = roomSummaryProvider
        self.userIndicatorController = userIndicatorController
        self.ledgerStore = ledgerStore
        self.ledgerOwner = ledgerOwner

        super.init(initialViewState: MessageForwardingScreenViewState(), mediaProvider: userSession.mediaProvider)

        roomSummaryProvider.roomListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)

        context.$viewState
            .map(\.bindings.searchQuery)
            .removeDuplicates()
            .sink { [weak self] searchQuery in
                if searchQuery.isEmpty {
                    self?.roomSummaryProvider.setFilter(.all(filters: []))
                } else {
                    self?.roomSummaryProvider.setFilter(.search(query: searchQuery))
                }
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cancelForwarding(dismissWhenComplete: false, releaseOwnerWhenComplete: false)
            }
            .store(in: &cancellables)

        updateRooms()
    }

    override func process(viewAction: MessageForwardingScreenViewAction) {
        switch viewAction {
        case .cancel:
            cancelForwarding(dismissWhenComplete: true, releaseOwnerWhenComplete: true)
        case .cancelUnknownOutcomeResolution:
            state.bindings.isUnknownOutcomeResolutionPresented = false
        case .continueWithoutResending:
            continueWithoutResendingUnknownOperations()
        case .send:
            startForwarding()
        case .sendUnknownAgain:
            resendUnknownOperations()
        case .selectRoom(let roomID):
            selectRoom(roomID)
        case .reachedTop:
            updateVisibleRange(edge: .top)
        case .reachedBottom:
            updateVisibleRange(edge: .bottom)
        }
    }

    func stop() {
        cancelForwarding(dismissWhenComplete: false, releaseOwnerWhenComplete: true)
        // This is a shared provider so we should reset the filtering when we are done with the view
        roomSummaryProvider.setFilter(.all(filters: []))
    }

    func confirmForwardingCompleted() {
        guard let roomID = state.selectedRoomID else { return }
        if !ledgerStore.removeStates(owner: ledgerOwner,
                                     accountID: clientProxy.userID,
                                     destinationRoomID: roomID,
                                     items: forwardingBatch.items,
                                     includingPreviousLaunches: false) {
            MXLog.error("Failed clearing the message forwarding admission ledger.")
        }
    }

    // MARK: - Private

    private func updateRooms() {
        var rooms = [MessageForwardingRoom]()
        let sourceRoomIDs = Set(forwardingBatch.items.map(\.roomID))

        for summary in roomSummaryProvider.roomListPublisher.value {
            if sourceRoomIDs.contains(summary.id) {
                continue
            }

            rooms.append(.init(id: summary.id,
                               title: summary.name,
                               description: summary.roomListDescription,
                               avatar: summary.avatar))
        }

        state.rooms = rooms
    }

    /// The actual range values don't matter as long as they contain the lower
    /// or upper bounds. updateVisibleRange is a hybrid API that powers both
    /// sliding sync visible range update and list paginations
    /// For lists other than the home screen one we don't care about visible ranges,
    /// we just need the respective bounds to be there to trigger a next page load or
    /// a reset to just one page
    private func updateVisibleRange(edge: UIRectEdge) {
        switch edge {
        case .top:
            roomSummaryProvider.updateVisibleRange(0..<0)
        case .bottom:
            let roomCount = roomSummaryProvider.roomListPublisher.value.count
            roomSummaryProvider.updateVisibleRange(roomCount..<roomCount)
        default:
            break
        }
    }

    private func selectRoom(_ roomID: String) {
        guard !state.isDestinationLocked, state.forwardingProgress?.isBusy != true else {
            return
        }

        if state.selectedRoomID != roomID {
            resetFailedOperations()
        }
        state.selectedRoomID = roomID
        restorePersistedOperations(for: roomID)
    }

    private func startForwarding() {
        guard forwardTask == nil, state.canSend, let roomID = state.selectedRoomID else {
            return
        }

        guard !forwardingOperations.contains(where: \.status.isUnknownOutcome) else {
            state.bindings.isUnknownOutcomeResolutionPresented = true
            return
        }

        beginForwarding(to: roomID)
    }

    private func beginForwarding(to roomID: String) {
        guard forwardTask == nil else { return }

        forwardingGeneration &+= 1
        let generation = forwardingGeneration
        isCancellationRequested = false
        shouldDismissAfterCancellation = false
        shouldReleaseOwnerAfterCancellation = false
        updateProgress(isQueueing: true, isCancelling: false)
        forwardTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await forward(to: roomID, generation: generation)
            forwardTask = nil
            handleForwardingOutcome(outcome)
        }
    }

    private func forward(to roomID: String, generation: Int) async -> MessageForwardingOutcome {
        if shouldCancelForwarding(generation: generation) {
            return await cancelQueuedOperations()
        }

        guard case let .joined(targetRoomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            if shouldCancelForwarding(generation: generation) {
                return await cancelQueuedOperations()
            }

            MXLog.error("Failed retrieving the destination room for message forwarding.")
            markUnqueuedOperationsAsFailed()
            return finishForwardingAttempt(roomID: roomID)
        }

        if shouldCancelForwarding(generation: generation) {
            return await cancelQueuedOperations()
        }

        let reservableIndices = forwardingOperations.indices.filter { forwardingOperations[$0].status.shouldQueue }
        let reservableItems = reservableIndices.map { forwardingOperations[$0].item }
        switch ledgerStore.reserveAdmissions(owner: ledgerOwner,
                                             accountID: clientProxy.userID,
                                             destinationRoomID: roomID,
                                             items: reservableItems) {
        case .stored:
            for index in reservableIndices {
                forwardingOperations[index].status = .reserved
            }
        case .capacityExceeded:
            markUnqueuedOperationsAsFailed()
            MXLog.error("Message forwarding queue admission capacity was exceeded.")
            updateProgress(isQueueing: false, isCancelling: false)
            return .capacityExceeded
        case .persistenceFailed:
            markUnqueuedOperationsAsFailed()
            MXLog.error("Failed reserving message forwarding queue admissions.")
            updateProgress(isQueueing: false, isCancelling: false)
            return .queueingFailed
        case .alreadyReserved:
            restorePersistedOperations(for: roomID)
            updateProgress(isQueueing: false, isCancelling: false)
            return .alreadyReserved
        case .notOwner:
            markUnqueuedOperationsAsFailed()
            MXLog.error("Failed reserving message forwarding queue admissions due to an ownership mismatch.")
            updateProgress(isQueueing: false, isCancelling: false)
            return .queueingFailed
        }

        for index in forwardingOperations.indices where forwardingOperations[index].status.isReserved {
            if shouldCancelForwarding(generation: generation) {
                return await cancelQueuedOperations()
            }

            forwardingOperations[index].status = .queueing
            updateProgress(isQueueing: true, isCancelling: false)

            let result = await targetRoomProxy.timeline.queueMessageEventContent(forwardingOperations[index].item.content)
            let shouldContinueQueueing = applyQueueingResult(result, at: index)

            if shouldCancelForwarding(generation: generation) {
                updateProgress(isQueueing: false, isCancelling: true)
                return await cancelQueuedOperations()
            }

            updateProgress(isQueueing: true, isCancelling: false)
            if !shouldContinueQueueing {
                break
            }
        }

        guard persistQueueingResults(roomID: roomID) else {
            markQueueingResultsAsUnknown()
            updateProgress(isQueueing: false, isCancelling: false)
            return .queueingFailed
        }
        return finishForwardingAttempt(roomID: roomID)
    }

    private func applyQueueingResult(_ result: Result<SendHandle, TimelineProxyError>, at index: Int) -> Bool {
        switch result {
        case .success(let sendHandle):
            forwardingOperations[index].status = .queued(sendHandle)
            return true
        case .failure(let error):
            forwardingOperations[index].status = .queueingFailed
            for remainingIndex in forwardingOperations.indices where remainingIndex > index && forwardingOperations[remainingIndex].status.isReserved {
                forwardingOperations[remainingIndex].status = .queueingFailed
            }
            MXLog.error("Failed adding a forwarded message to the send queue: \(type(of: error))")
            return false
        }
    }

    private func shouldCancelForwarding(generation: Int) -> Bool {
        Task.isCancelled || isCancellationRequested || generation != forwardingGeneration
    }

    private func finishForwardingAttempt(roomID: String) -> MessageForwardingOutcome {
        updateProgress(isQueueing: false, isCancelling: false)
        guard !forwardingOperations.contains(where: \.status.isQueueingFailure) else {
            return .queueingFailed
        }

        for index in forwardingOperations.indices where forwardingOperations[index].status.isQueued {
            forwardingOperations[index].status = .acceptedByQueue
        }
        updateProgress(isQueueing: false, isCancelling: false)
        return .queued(roomID: roomID)
    }

    private func updateProgress(isQueueing: Bool, isCancelling: Bool) {
        state.forwardingProgress = MessageForwardingProgress(totalCount: forwardingOperations.count,
                                                             queuedCount: forwardingOperations.count { $0.status.isAcceptedByQueue },
                                                             failedCount: forwardingOperations.count { $0.status.isQueueingFailure },
                                                             unknownCount: forwardingOperations.count { $0.status.isUnknownOutcome },
                                                             isQueueing: isQueueing,
                                                             isCancelling: isCancelling)
    }

    private func markUnqueuedOperationsAsFailed() {
        for index in forwardingOperations.indices where forwardingOperations[index].status.shouldQueue {
            forwardingOperations[index].status = .queueingFailed
        }
    }

    private func resetFailedOperations() {
        guard !state.isDestinationLocked else { return }

        for index in forwardingOperations.indices where forwardingOperations[index].status.isQueueingFailure {
            forwardingOperations[index].status = .pending
        }
        state.forwardingProgress = nil
    }

    private func restorePersistedOperations(for roomID: String) {
        let restorableIndices = forwardingOperations.indices.filter { forwardingOperations[$0].status.shouldQueue }
        let restorableItems = restorableIndices.map { forwardingOperations[$0].item }
        let persistedStates = ledgerStore.states(accountID: clientProxy.userID,
                                                 destinationRoomID: roomID,
                                                 items: restorableItems)
        for (index, persistedState) in zip(restorableIndices, persistedStates) where persistedState != nil {
            forwardingOperations[index].status = .restoredUnknown
        }

        if forwardingOperations.contains(where: \.status.isUnknownOutcome) {
            updateProgress(isQueueing: false, isCancelling: false)
        }
    }

    private func persistQueueingResults(roomID: String) -> Bool {
        let updates = forwardingOperations.compactMap { operation -> MessageForwardingLedgerUpdate? in
            switch operation.status {
            case .queued:
                .set(.admitted, item: operation.item)
            case .queueingFailed:
                .remove(item: operation.item)
            default:
                nil
            }
        }
        guard ledgerStore.apply(updates,
                                owner: ledgerOwner,
                                accountID: clientProxy.userID,
                                destinationRoomID: roomID) == .stored else {
            MXLog.error("Failed atomically updating the message forwarding admission ledger.")
            return false
        }
        return true
    }

    private func markQueueingResultsAsUnknown() {
        for index in forwardingOperations.indices {
            switch forwardingOperations[index].status {
            case .queued(let sendHandle):
                forwardingOperations[index].status = .queuedWithUnknownLedgerState(sendHandle)
            case .queueingFailed:
                forwardingOperations[index].status = .cancellationUnknown
            default:
                break
            }
        }
    }

    private func resolveUnknownAdmissions(_ items: [MessageForwardingItem], roomID: String) -> Bool {
        if ledgerStore.removeStates(owner: ledgerOwner,
                                    accountID: clientProxy.userID,
                                    destinationRoomID: roomID,
                                    items: items,
                                    includingPreviousLaunches: true) {
            return true
        }
        guard ledgerStore.discardCorruptLedger(accountID: clientProxy.userID) else {
            MXLog.error("Failed resolving message forwarding admissions owned by another active scene.")
            return false
        }
        MXLog.error("Discarded a corrupt message forwarding admission ledger after explicit user confirmation.")
        return true
    }

    private func continueWithoutResendingUnknownOperations() {
        guard let roomID = state.selectedRoomID else { return }
        let unknownItems = forwardingOperations.compactMap { operation in
            operation.status.isUnknownOutcome ? operation.item : nil
        }
        guard resolveUnknownAdmissions(unknownItems, roomID: roomID) else { return }
        state.bindings.isUnknownOutcomeResolutionPresented = false
        for index in forwardingOperations.indices where forwardingOperations[index].status.isUnknownOutcome {
            forwardingOperations[index].status = .acceptedByQueue
        }
        beginForwarding(to: roomID)
    }

    private func resendUnknownOperations() {
        guard let roomID = state.selectedRoomID else { return }
        let unknownItems = forwardingOperations.compactMap { operation in
            operation.status.isUnknownOutcome ? operation.item : nil
        }
        guard resolveUnknownAdmissions(unknownItems, roomID: roomID) else { return }
        for index in forwardingOperations.indices where forwardingOperations[index].status.isUnknownOutcome {
            forwardingOperations[index].status = .pending
        }
        state.bindings.isUnknownOutcomeResolutionPresented = false
        beginForwarding(to: roomID)
    }

    private func cancelForwarding(dismissWhenComplete: Bool, releaseOwnerWhenComplete: Bool) {
        isCancellationRequested = true
        forwardingGeneration &+= 1
        forwardTask?.cancel()
        shouldDismissAfterCancellation = shouldDismissAfterCancellation || dismissWhenComplete
        shouldReleaseOwnerAfterCancellation = shouldReleaseOwnerAfterCancellation || releaseOwnerWhenComplete

        if forwardTask != nil {
            updateProgress(isQueueing: false, isCancelling: true)
            return
        }

        guard forwardingOperations.contains(where: \.status.isQueued) else {
            let shouldDismiss = shouldDismissAfterCancellation
            if forwardingOperations.contains(where: \.status.isOwnedUnknownOutcome),
               !persistCancellationResults() {
                markCancellationResultsAsUnknown()
                updateProgress(isQueueing: false, isCancelling: false)
                resetCancellationState()
                userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingQueueFailed))
                return
            }
            if shouldReleaseOwnerAfterCancellation, !releaseOwnedUnknownAdmissions() {
                resetCancellationState()
                userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingQueueFailed))
                return
            }
            resetCancellationState()
            if shouldDismiss {
                actionsSubject.send(.dismiss)
            }
            return
        }

        updateProgress(isQueueing: false, isCancelling: true)
        forwardTask = Task { [self] in
            let outcome = await cancelQueuedOperations()
            forwardTask = nil
            handleForwardingOutcome(outcome)
        }
    }

    private func cancelQueuedOperations() async -> MessageForwardingOutcome {
        var unretractableCount = 0

        let reservedIndices = forwardingOperations.indices.filter { forwardingOperations[$0].status.isReserved }
        for index in reservedIndices {
            forwardingOperations[index].status = .cancelled
        }

        for index in forwardingOperations.indices {
            let sendHandle: SendHandle
            switch forwardingOperations[index].status {
            case .queued(let handle), .queuedWithUnknownLedgerState(let handle):
                sendHandle = handle
            default:
                continue
            }

            do {
                if try await sendHandle.abort() {
                    forwardingOperations[index].status = .cancelled
                } else {
                    forwardingOperations[index].status = .cancellationUnknown
                    unretractableCount += 1
                }
            } catch {
                forwardingOperations[index].status = .cancellationUnknown
                unretractableCount += 1
                MXLog.error("Failed cancelling a queued forwarded message: \(type(of: error))")
            }
        }

        guard persistCancellationResults() else {
            markCancellationResultsAsUnknown()
            updateProgress(isQueueing: false, isCancelling: false)
            return .queueingFailed
        }
        updateProgress(isQueueing: false, isCancelling: false)
        return .cancelled(unretractableCount: unretractableCount,
                          shouldDismiss: shouldDismissAfterCancellation)
    }

    private func persistCancellationResults() -> Bool {
        guard let roomID = state.selectedRoomID else {
            MXLog.error("Failed updating cancelled message forwarding admissions without a destination.")
            return false
        }
        let updates = forwardingOperations.compactMap { operation -> MessageForwardingLedgerUpdate? in
            switch operation.status {
            case .cancelled, .queueingFailed:
                .remove(item: operation.item)
            case .cancellationUnknown:
                .set(.unknown, item: operation.item)
            default:
                nil
            }
        }
        guard ledgerStore.apply(updates,
                                owner: ledgerOwner,
                                accountID: clientProxy.userID,
                                destinationRoomID: roomID) == .stored else {
            MXLog.error("Failed atomically updating cancelled message forwarding admissions.")
            return false
        }
        return true
    }

    private func markCancellationResultsAsUnknown() {
        for index in forwardingOperations.indices {
            switch forwardingOperations[index].status {
            case .cancelled, .queueingFailed:
                forwardingOperations[index].status = .cancellationUnknown
            default:
                break
            }
        }
    }

    private func handleForwardingOutcome(_ outcome: MessageForwardingOutcome) {
        let shouldReleaseOwner = shouldReleaseOwnerAfterCancellation
        resetCancellationState()

        switch outcome {
        case .queued(let roomID):
            actionsSubject.send(.queued(roomID: roomID))
        case .queueingFailed:
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingQueueFailed))
        case .capacityExceeded:
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingCapacityExceeded))
        case .alreadyReserved:
            break
        case .cancelled(let unretractableCount, let shouldDismiss):
            if shouldReleaseOwner, !releaseOwnedUnknownAdmissions() {
                userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingQueueFailed))
                return
            }
            if unretractableCount > 0 {
                userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMessageForwardingCancelledPartial(unretractableCount)))
            }
            if shouldDismiss {
                actionsSubject.send(.dismiss)
            } else {
                resetCancelledOperationsAfterSuspension()
            }
        }
    }

    private func releaseOwnedUnknownAdmissions() -> Bool {
        let ownedUnknownIndices = forwardingOperations.indices.filter { forwardingOperations[$0].status.isOwnedUnknownOutcome }
        guard !ownedUnknownIndices.isEmpty else { return true }
        guard let roomID = state.selectedRoomID else { return false }
        let ownedUnknownItems = ownedUnknownIndices.map { forwardingOperations[$0].item }
        guard ledgerStore.releaseUnknownAdmissions(owner: ledgerOwner,
                                                   accountID: clientProxy.userID,
                                                   destinationRoomID: roomID,
                                                   items: ownedUnknownItems) else {
            MXLog.error("Failed releasing uncertain message forwarding admissions from a dismissed scene.")
            return false
        }
        for index in ownedUnknownIndices {
            forwardingOperations[index].status = .restoredUnknown
        }
        return true
    }

    private func resetCancelledOperationsAfterSuspension() {
        for index in forwardingOperations.indices where forwardingOperations[index].status.isCancelled {
            forwardingOperations[index].status = .pending
        }

        if forwardingOperations.contains(where: \.status.isUnknownOutcome) {
            updateProgress(isQueueing: false, isCancelling: false)
        } else {
            state.forwardingProgress = nil
        }
    }

    private func resetCancellationState() {
        isCancellationRequested = false
        shouldDismissAfterCancellation = false
        shouldReleaseOwnerAfterCancellation = false
    }
}

private struct MessageForwardingOperation {
    let item: MessageForwardingItem
    var status = MessageForwardingOperationStatus.pending
}

private enum MessageForwardingOperationStatus {
    case pending
    case reserved
    case queueing
    case queued(SendHandle)
    case queuedWithUnknownLedgerState(SendHandle)
    case acceptedByQueue
    case queueingFailed
    case cancelled
    case cancellationUnknown
    case restoredUnknown

    var shouldQueue: Bool {
        switch self {
        case .pending, .queueingFailed:
            true
        default:
            false
        }
    }

    var isReserved: Bool {
        if case .reserved = self {
            true
        } else {
            false
        }
    }

    var isQueued: Bool {
        switch self {
        case .queued, .queuedWithUnknownLedgerState:
            true
        default:
            false
        }
    }

    var isAcceptedByQueue: Bool {
        switch self {
        case .queued, .acceptedByQueue:
            true
        default:
            false
        }
    }

    var isQueueingFailure: Bool {
        if case .queueingFailed = self {
            true
        } else {
            false
        }
    }

    var isUnknownOutcome: Bool {
        switch self {
        case .queuedWithUnknownLedgerState, .cancellationUnknown, .restoredUnknown:
            true
        default:
            false
        }
    }

    var isOwnedUnknownOutcome: Bool {
        switch self {
        case .queuedWithUnknownLedgerState, .cancellationUnknown:
            true
        default:
            false
        }
    }

    var isCancelled: Bool {
        if case .cancelled = self {
            true
        } else {
            false
        }
    }
}

private enum MessageForwardingOutcome {
    case queued(roomID: String)
    case queueingFailed
    case capacityExceeded
    case alreadyReserved
    case cancelled(unretractableCount: Int, shouldDismiss: Bool)
}
