//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing
import UIKit

@MainActor
struct MessageForwardingScreenViewModelTests {
    let forwardingItem = MessageForwardingItem(id: .event(uniqueID: .init("t1"), eventOrTransactionID: .eventID("t1")),
                                               roomID: "1",
                                               content: .init(noHandle: .init()))
    var viewModel: MessageForwardingScreenViewModelProtocol!
    var context: MessageForwardingScreenViewModelType.Context!

    init() {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.roomForIdentifierClosure = { .joined(JoinedRoomProxyMock(.init(id: $0))) }

        viewModel = MessageForwardingScreenViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                                     userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                     roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))),
                                                     userIndicatorController: UserIndicatorControllerMock(),
                                                     ledgerStore: InMemoryMessageForwardingLedgerStore())
        context = viewModel.context
    }

    @Test
    func initialState() {
        #expect(context.viewState.rooms.first { $0.id == forwardingItem.roomID } == nil, "The source room ID shouldn't be shown")
    }

    @Test
    func queueingPresentationTakesPrecedenceOverEarlierFailures() {
        let progress = MessageForwardingProgress(totalCount: 3,
                                                 queuedCount: 1,
                                                 failedCount: 1,
                                                 isQueueing: true)

        #expect(progress.statusTitle == "正在加入发送队列")
        #expect(progress.sendButtonTitle == "加入中")
        #expect(!progress.showsFailure)
    }

    @Test
    func completedAttemptPresentsFailureAndRetry() {
        let progress = MessageForwardingProgress(totalCount: 3,
                                                 queuedCount: 2,
                                                 failedCount: 1,
                                                 isQueueing: false)

        #expect(progress.statusTitle == "部分消息未能加入发送队列")
        #expect(progress.sendButtonTitle == L10n.actionRetry)
        #expect(progress.showsFailure)
    }

    @Test
    func completedAttemptDescribesQueueAcceptanceInsteadOfDelivery() {
        let progress = MessageForwardingProgress(totalCount: 3,
                                                 queuedCount: 3,
                                                 failedCount: 0,
                                                 isQueueing: false)

        #expect(progress.statusTitle == "已加入发送队列")
    }

    @Test
    mutating func roomSelection() {
        context.send(viewAction: .selectRoom(roomID: "2"))
        #expect(context.viewState.selectedRoomID == "2")
    }

    @Test
    mutating func searching() async throws {
        let deferred = deferFulfillment(context.$viewState) { state in
            state.rooms.count == 1
        }

        context.searchQuery = "Second"

        try await deferred.fulfill()
    }

    @Test
    mutating func forwarding() async throws {
        context.send(viewAction: .selectRoom(roomID: "2"))
        #expect(context.viewState.selectedRoomID == "2")

        let deferred = deferFulfillment(viewModel.actions) { action in
            switch action {
            case .queued(let roomID):
                return roomID == "2"
            default:
                return false
            }
        }

        context.send(viewAction: .send)

        try await deferred.fulfill()
    }

    @Test
    func forwardingMultipleItems() async throws {
        let secondForwardingItem = MessageForwardingItem(id: .event(uniqueID: .init("t2"), eventOrTransactionID: .eventID("t2")),
                                                         roomID: "1",
                                                         content: .init(noHandle: .init()))
        let targetTimeline = TimelineProxyMock(.init())
        let targetRoom = JoinedRoomProxyMock(.init(id: "2"))
        targetRoom.timeline = targetTimeline

        let clientProxy = ClientProxyMock(.init())
        clientProxy.roomForIdentifierClosure = { _ in .joined(targetRoom) }
        let forwardingBatch = try #require(MessageForwardingBatch(firstItem: forwardingItem,
                                                                  remainingItems: [secondForwardingItem]))
        let viewModel = MessageForwardingScreenViewModel(forwardingBatch: forwardingBatch,
                                                         userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                         roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))),
                                                         userIndicatorController: UserIndicatorControllerMock(),
                                                         ledgerStore: InMemoryMessageForwardingLedgerStore())
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))

        let deferred = deferFulfillment(viewModel.actions) { action in
            switch action {
            case .queued(let roomID):
                return roomID == "2"
            default:
                return false
            }
        }

        context.send(viewAction: .send)
        try await deferred.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 2)
    }

    @Test
    func partialFailureRetriesOnlyFailedItemsAndLocksTheDestination() async throws {
        let forwardingBatch = makeForwardingBatch(count: 3)
        let targetTimeline = TimelineProxyMock(.init())
        let results = ForwardingResultSequence([
            .success(SendHandleSDKMock()),
            .failure(.failedRedacting),
            .success(SendHandleSDKMock()),
            .success(SendHandleSDKMock())
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in results.next() }
        let viewModel = makeViewModel(forwardingBatch: forwardingBatch, targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))

        let firstAttempt = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }
        context.send(viewAction: .send)
        try await firstAttempt.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 3)
        #expect(context.viewState.forwardingProgress?.queuedCount == 2)
        #expect(context.viewState.isDestinationLocked)

        context.send(viewAction: .selectRoom(roomID: "3"))
        #expect(context.viewState.selectedRoomID == "2")

        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }
        context.send(viewAction: .send)
        try await queued.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 4)
        #expect(context.viewState.forwardingProgress?.queuedCount == 3)
        #expect(context.viewState.forwardingProgress?.failedCount == 0)
    }

    @Test
    func allFailuresAllowChangingDestinationAndRetryingTheWholeBatch() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let results = ForwardingResultSequence([
            .failure(.failedRedacting),
            .failure(.failedRedacting),
            .success(SendHandleSDKMock()),
            .success(SendHandleSDKMock())
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in results.next() }
        let viewModel = makeViewModel(forwardingBatch: makeForwardingBatch(count: 2), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))

        let firstAttempt = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 2
        }
        context.send(viewAction: .send)
        try await firstAttempt.fulfill()

        #expect(!context.viewState.isDestinationLocked)
        context.send(viewAction: .selectRoom(roomID: "3"))
        #expect(context.viewState.selectedRoomID == "3")

        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "3") = action else { return false }
            return true
        }
        context.send(viewAction: .send)
        try await queued.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 4)
    }

    @Test
    func repeatedSendWhileInFlightStartsOneOperation() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let sendGate = ForwardingSendGate()
        targetTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .success(SendHandleSDKMock())
        }
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        context.send(viewAction: .send)
        try await waitForSendCount(1, timeline: targetTimeline)

        #expect(context.viewState.forwardingProgress?.isQueueing == true)
        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)

        sendGate.open()
        try await queued.fulfill()
        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)
    }

    @Test
    func delayedQueueFailureIsRetryableAndNeverPresentedAsQueued() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let sendGate = ForwardingSendGate()
        targetTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .failure(.failedRedacting)
        }
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))

        context.send(viewAction: .send)
        try await waitForSendCount(1, timeline: targetTimeline)
        #expect(context.viewState.forwardingProgress?.statusTitle == "正在加入发送队列")

        let failed = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }
        sendGate.open()
        try await failed.fulfill()

        #expect(context.viewState.forwardingProgress?.queuedCount == 0)
        #expect(context.viewState.forwardingProgress?.statusTitle == "部分消息未能加入发送队列")
        #expect(context.viewState.forwardingProgress?.sendButtonTitle == L10n.actionRetry)
    }

    @Test
    func cancellingAfterAPartialQueueFailureAbortsTheRetainedHandle() async throws {
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = true
        let targetTimeline = TimelineProxyMock(.init())
        let results = ForwardingResultSequence([
            .success(sendHandle),
            .failure(.failedRedacting)
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in results.next() }
        let viewModel = makeViewModel(forwardingBatch: makeForwardingBatch(count: 2), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))

        let partiallyQueued = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }
        context.send(viewAction: .send)
        try await partiallyQueued.fulfill()

        let dismissed = deferFulfillment(viewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }
        context.send(viewAction: .cancel)
        try await dismissed.fulfill()

        #expect(sendHandle.abortCallsCount == 1)
    }

    @Test
    func stoppingAfterAPartialQueueFailureRetainsCancellationUntilAbortCompletes() async throws {
        let abortGate = ForwardingSendGate()
        defer { abortGate.open() }
        let cancellationLifecycle = ForwardingCancellationLifecycle()
        var sendHandle: SendHandleSDKMock? = SendHandleSDKMock()
        sendHandle?.abortClosure = {
            cancellationLifecycle.markAbortStarted()
            await abortGate.wait()
            cancellationLifecycle.markAbortCompleted()
            return true
        }
        weak var weakSendHandle = sendHandle
        let targetTimeline = TimelineProxyMock(.init())
        let results = try ForwardingResultSequence([
            .success(#require(sendHandle)),
            .failure(.failedRedacting)
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in results.next() }
        var viewModel: MessageForwardingScreenViewModel? = makeViewModel(forwardingBatch: makeForwardingBatch(count: 2),
                                                                         targetTimeline: targetTimeline)
        weak var weakViewModel = viewModel
        let context = try #require(viewModel?.context)
        context.send(viewAction: .selectRoom(roomID: "2"))

        let partiallyQueued = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }
        context.send(viewAction: .send)
        try await partiallyQueued.fulfill()

        sendHandle = nil
        viewModel?.stop()
        viewModel = nil

        try await waitForCondition { cancellationLifecycle.didStartAbort }
        #expect(weakViewModel != nil)
        #expect(weakSendHandle != nil)
        #expect(!cancellationLifecycle.didCompleteAbort)

        abortGate.open()
        try await waitForCondition { cancellationLifecycle.didCompleteAbort }
        try await waitForCondition { weakViewModel == nil && weakSendHandle == nil }
    }

    @Test
    func cancellingAnInFlightForwardDoesNotNavigateAfterDismissal() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let sendGate = ForwardingSendGate()
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = true
        targetTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .success(sendHandle)
        }
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let dismissed = deferFulfillment(viewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }
        let noQueued = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .queued = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await waitForSendCount(1, timeline: targetTimeline)
        context.send(viewAction: .cancel)
        sendGate.open()
        try await dismissed.fulfill()
        try await noQueued.fulfill()
        #expect(sendHandle.abortCallsCount == 1)
    }

    @Test
    func cancellationWaitsForTheInFlightHandleToBeAbortedBeforeDismissing() async throws {
        let sendGate = ForwardingSendGate()
        let abortGate = ForwardingSendGate()
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortClosure = {
            await abortGate.wait()
            return true
        }
        let sdkTimeline = TimelineSDKMock()
        sdkTimeline.sendMsgClosure = { _ in
            await sendGate.wait()
            return sendHandle
        }
        let targetTimeline = TimelineProxy(timeline: sdkTimeline, kind: .live)
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem), targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let dismissed = deferFulfillment(viewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }
        let noEarlyDismiss = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .dismiss = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await waitForSDKSendCount(1, timeline: sdkTimeline)
        context.send(viewAction: .cancel)
        sendGate.open()
        try await waitForAbortCount(1, handle: sendHandle)
        try await noEarlyDismiss.fulfill()
        #expect(context.viewState.forwardingProgress?.statusTitle == "正在取消转发")

        abortGate.open()
        try await dismissed.fulfill()
        #expect(sendHandle.abortCallsCount == 1)
    }

    @Test
    func cancellationWarnsWhenAQueuedMessageCanNoLongerBeAborted() async throws {
        let sendGate = ForwardingSendGate()
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = false
        let sdkTimeline = TimelineSDKMock()
        sdkTimeline.sendMsgClosure = { _ in
            await sendGate.wait()
            return sendHandle
        }
        let targetTimeline = TimelineProxy(timeline: sdkTimeline, kind: .live)
        let userIndicatorController = UserIndicatorControllerMock()
        let viewModel = makeViewModel(forwardingBatch: makeForwardingBatch(count: 2),
                                      targetTimeline: targetTimeline,
                                      userIndicatorController: userIndicatorController)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let dismissed = deferFulfillment(viewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await waitForSDKSendCount(1, timeline: sdkTimeline)
        context.send(viewAction: .cancel)
        sendGate.open()
        try await dismissed.fulfill()

        #expect(sendHandle.abortCallsCount == 1)
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 1)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title ==
            "转发已停止。1 条消息已发送或无法取消。")
        #expect(sdkTimeline.sendMsgCallsCount == 1)
    }

    @Test
    func forwardsALargeFlatBatch() async throws {
        let forwardingBatch = makeForwardingBatch(count: 150)
        var queuedContents = [RoomMessageEventContentWithoutRelation]()
        let targetTimeline = TimelineProxyMock(.init())
        targetTimeline.queueMessageEventContentClosure = { content in
            queuedContents.append(content)
            return .success(SendHandle(noHandle: .init()))
        }
        let viewModel = makeViewModel(forwardingBatch: forwardingBatch, targetTimeline: targetTimeline)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await queued.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 150)
        #expect(queuedContents.elementsEqual(forwardingBatch.items.map(\.content)) { $0 === $1 })
    }

    @Test
    func rejects151MessagesAtTheBatchConstructionBoundary() {
        let items = (1...151).map { index in
            MessageForwardingItem(id: .event(uniqueID: .init("oversized-\(index)"),
                                             eventOrTransactionID: .eventID("oversized-\(index)")),
                                  roomID: "1",
                                  content: .init(noHandle: .init()))
        }

        let batch = MessageForwardingBatch(firstItem: items[0], remainingItems: Array(items.dropFirst()))

        #expect(batch == nil)
    }

    @Test
    func persistsAdmissionBeforeCallingTheSDK() async throws {
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        let targetTimeline = TimelineProxyMock(.init())
        targetTimeline.queueMessageEventContentClosure = { _ in
            #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                      destinationRoomID: "2",
                                      item: forwardingItem) == .admitting)
            return .failure(.failedRedacting)
        }
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let failed = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }

        context.send(viewAction: .send)
        try await failed.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == nil)
    }

    @Test
    func capacityRefusalDoesNotCallTheSDKAndExplainsTheSafeOutcome() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let userIndicatorController = UserIndicatorControllerMock()
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                      targetTimeline: targetTimeline,
                                      userIndicatorController: userIndicatorController,
                                      ledgerStore: CapacityExceededMessageForwardingLedgerStore())
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let refused = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }

        context.send(viewAction: .send)
        try await refused.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 0)
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 1)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title ==
            "无法继续安全转发，因为已保存的未确认转发过多。请先检查之前的目标聊天室并处理结果未知的转发。")
    }

    @Test
    func batchCapacityIsReservedBeforeAnyItemIsQueued() async throws {
        let targetTimeline = TimelineProxyMock(.init())
        let viewModel = makeViewModel(forwardingBatch: makeForwardingBatch(count: 2),
                                      targetTimeline: targetTimeline,
                                      ledgerStore: PartialCapacityMessageForwardingLedgerStore())
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let refused = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && (state.forwardingProgress?.failedCount ?? 0) > 0
        }

        context.send(viewAction: .send)
        try await refused.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 0)
    }

    @Test
    func twoScenesCannotQueueOrCleanUpTheSameAdmission() async throws {
        let suiteName = "MessageForwardingScreenViewModelTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let firstStore = MessageForwardingLedgerStore(userDefaults: userDefaults)
        let secondStore = MessageForwardingLedgerStore(userDefaults: userDefaults)
        let targetTimeline = TimelineProxyMock(.init())
        let sendGate = ForwardingSendGate()
        targetTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .success(SendHandleSDKMock())
        }
        let firstViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                           targetTimeline: targetTimeline,
                                           ledgerStore: firstStore)
        let secondViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                            targetTimeline: targetTimeline,
                                            ledgerStore: secondStore)
        let firstContext = firstViewModel.context
        let secondContext = secondViewModel.context
        firstContext.send(viewAction: .selectRoom(roomID: "2"))
        secondContext.send(viewAction: .selectRoom(roomID: "2"))
        let firstQueued = deferFulfillment(firstViewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }

        firstContext.send(viewAction: .send)
        try await waitForSendCount(1, timeline: targetTimeline)
        secondViewModel.confirmForwardingCompleted()
        #expect(firstStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                 destinationRoomID: "2",
                                 item: forwardingItem) == .admitting)

        secondContext.send(viewAction: .send)
        for _ in 0..<100 {
            if targetTimeline.queueMessageEventContentCallsCount > 1 ||
                secondContext.viewState.forwardingProgress?.unknownCount == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)
        #expect(secondContext.viewState.forwardingProgress?.unknownCount == 1)
        secondContext.send(viewAction: .send)
        #expect(secondContext.viewState.bindings.isUnknownOutcomeResolutionPresented)
        secondContext.send(viewAction: .sendUnknownAgain)
        #expect(secondContext.viewState.bindings.isUnknownOutcomeResolutionPresented)
        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)
        #expect(firstStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                 destinationRoomID: "2",
                                 item: forwardingItem) == .admitting)
        sendGate.open()
        try await firstQueued.fulfill()
        try await waitForCondition { secondContext.viewState.forwardingProgress?.isBusy != true }
    }

    @Test
    func reconstructedAdmissionRequiresExplicitResolutionAndIsNotResent() async throws {
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        persistAdmission(.admitted, item: forwardingItem, in: ledgerStore)
        let targetTimeline = TimelineProxyMock(.init())
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore)
        let context = viewModel.context

        context.send(viewAction: .selectRoom(roomID: "2"))
        #expect(context.viewState.forwardingProgress?.unknownCount == 1)
        #expect(context.viewState.isDestinationLocked)

        context.send(viewAction: .send)
        #expect(context.viewState.bindings.isUnknownOutcomeResolutionPresented)
        #expect(targetTimeline.queueMessageEventContentCallsCount == 0)

        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }
        context.send(viewAction: .continueWithoutResending)
        try await queued.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 0)
    }

    @Test
    func explicitSendAgainRequeuesAnUnknownAdmission() async throws {
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        persistAdmission(.admitted, item: forwardingItem, in: ledgerStore)
        let targetTimeline = TimelineProxyMock(.init())
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        context.send(viewAction: .send)
        #expect(context.viewState.bindings.isUnknownOutcomeResolutionPresented)
        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }

        context.send(viewAction: .sendUnknownAgain)
        try await queued.fulfill()

        #expect(targetTimeline.queueMessageEventContentCallsCount == 1)
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == .admitted)
    }

    @Test
    func appSuspensionAbortsAnAdmittedHandleAndLeavesItSafeToRetry() async throws {
        let notificationCenter = NotificationCenter()
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        let sendGate = ForwardingSendGate()
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = true
        let targetTimeline = TimelineProxyMock(.init())
        let results = ForwardingResultSequence([
            .success(sendHandle),
            .failure(.failedRedacting)
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in
            if targetTimeline.queueMessageEventContentCallsCount == 2 {
                await sendGate.wait()
            }
            return results.next()
        }
        let forwardingBatch = makeForwardingBatch(count: 2)
        let viewModel = makeViewModel(forwardingBatch: forwardingBatch,
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore,
                                      notificationCenter: notificationCenter)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let cancelling = deferFulfillment(context.$viewState) { $0.forwardingProgress?.isCancelling == true }
        let noQueued = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .queued = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await waitForSendCount(2, timeline: targetTimeline)
        notificationCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await cancelling.fulfill()
        sendGate.open()
        try await waitForAbortCount(1, handle: sendHandle)
        try await waitForCondition { context.viewState.forwardingProgress == nil }
        try await noQueued.fulfill()

        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingBatch.items[0]) == nil)
    }

    @Test
    func unabortableAdmissionRemainsAnUnknownOutcome() async throws {
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = false
        let targetTimeline = TimelineProxyMock(.init())
        let results = ForwardingResultSequence([
            .success(sendHandle),
            .failure(.failedRedacting)
        ])
        targetTimeline.queueMessageEventContentClosure = { _ in results.next() }
        let forwardingBatch = makeForwardingBatch(count: 2)
        let viewModel = makeViewModel(forwardingBatch: forwardingBatch,
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let partiallyQueued = deferFulfillment(context.$viewState) { state in
            state.forwardingProgress?.isQueueing == false && state.forwardingProgress?.failedCount == 1
        }
        context.send(viewAction: .send)
        try await partiallyQueued.fulfill()
        let dismissed = deferFulfillment(viewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }

        context.send(viewAction: .cancel)
        try await dismissed.fulfill()

        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingBatch.items[0]) == .unknown)
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingBatch.items[1]) == nil)
    }

    @Test
    func dismissedUnknownAdmissionCanBeExplicitlyResentByAReconstructedSameLaunchScreen() async throws {
        let suiteName = "MessageForwardingScreenViewModelTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let ledgerStore = MessageForwardingLedgerStore(userDefaults: userDefaults, maximumEntryCount: 1)
        let sendGate = ForwardingSendGate()
        defer { sendGate.open() }
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = false
        let firstTimeline = TimelineProxyMock(.init())
        firstTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .success(sendHandle)
        }
        let firstViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                           targetTimeline: firstTimeline,
                                           ledgerStore: ledgerStore)
        let firstContext = firstViewModel.context
        firstContext.send(viewAction: .selectRoom(roomID: "2"))
        let dismissed = deferFulfillment(firstViewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }

        firstContext.send(viewAction: .send)
        try await waitForSendCount(1, timeline: firstTimeline)
        firstContext.send(viewAction: .cancel)
        sendGate.open()
        try await dismissed.fulfill()
        #expect(sendHandle.abortCallsCount == 1)
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == .unknown)

        let reconstructedTimeline = TimelineProxyMock(.init())
        let reconstructedViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                                   targetTimeline: reconstructedTimeline,
                                                   ledgerStore: ledgerStore)
        let reconstructedContext = reconstructedViewModel.context
        reconstructedContext.send(viewAction: .selectRoom(roomID: "2"))
        #expect(reconstructedContext.viewState.forwardingProgress?.unknownCount == 1)
        #expect(reconstructedTimeline.queueMessageEventContentCallsCount == 0)

        reconstructedContext.send(viewAction: .send)
        #expect(reconstructedContext.viewState.bindings.isUnknownOutcomeResolutionPresented)
        #expect(reconstructedTimeline.queueMessageEventContentCallsCount == 0)
        let queued = deferFulfillment(reconstructedViewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }
        reconstructedContext.send(viewAction: .sendUnknownAgain)
        try await queued.fulfill()

        #expect(reconstructedTimeline.queueMessageEventContentCallsCount == 1)
    }

    @Test
    func explicitlyDiscardingAReconstructedSameLaunchUnknownAdmissionFreesCapacity() async throws {
        let suiteName = "MessageForwardingScreenViewModelTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let ledgerStore = MessageForwardingLedgerStore(userDefaults: userDefaults, maximumEntryCount: 1)
        let sendGate = ForwardingSendGate()
        defer { sendGate.open() }
        let sendHandle = SendHandleSDKMock()
        sendHandle.abortReturnValue = false
        let firstTimeline = TimelineProxyMock(.init())
        firstTimeline.queueMessageEventContentClosure = { _ in
            await sendGate.wait()
            return .success(sendHandle)
        }
        let firstViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                           targetTimeline: firstTimeline,
                                           ledgerStore: ledgerStore)
        let firstContext = firstViewModel.context
        firstContext.send(viewAction: .selectRoom(roomID: "2"))
        let dismissed = deferFulfillment(firstViewModel.actions) { action in
            guard case .dismiss = action else { return false }
            return true
        }

        firstContext.send(viewAction: .send)
        try await waitForSendCount(1, timeline: firstTimeline)
        firstContext.send(viewAction: .cancel)
        sendGate.open()
        try await dismissed.fulfill()

        let reconstructedTimeline = TimelineProxyMock(.init())
        let reconstructedViewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                                   targetTimeline: reconstructedTimeline,
                                                   ledgerStore: ledgerStore)
        let reconstructedContext = reconstructedViewModel.context
        reconstructedContext.send(viewAction: .selectRoom(roomID: "2"))
        reconstructedContext.send(viewAction: .send)
        #expect(reconstructedContext.viewState.bindings.isUnknownOutcomeResolutionPresented)
        let queued = deferFulfillment(reconstructedViewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }
        reconstructedContext.send(viewAction: .continueWithoutResending)
        try await queued.fulfill()

        #expect(reconstructedTimeline.queueMessageEventContentCallsCount == 0)
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == nil)
        let replacementItem = MessageForwardingItem(id: .event(uniqueID: .init("capacity-replacement"),
                                                               eventOrTransactionID: .eventID("capacity-replacement")),
                                                    roomID: "1",
                                                    content: .init(noHandle: .init()))
        #expect(ledgerStore.reserveAdmissions(owner: .init(),
                                              accountID: RoomMemberProxyMock.mockMe.userID,
                                              destinationRoomID: "2",
                                              items: [replacementItem]) == .stored)
    }

    @Test
    func completedRoutingCleansPersistedAdmissions() async throws {
        let ledgerStore = InMemoryMessageForwardingLedgerStore()
        let targetTimeline = TimelineProxyMock(.init())
        let viewModel = makeViewModel(forwardingBatch: .init(firstItem: forwardingItem),
                                      targetTimeline: targetTimeline,
                                      ledgerStore: ledgerStore)
        let context = viewModel.context
        context.send(viewAction: .selectRoom(roomID: "2"))
        let queued = deferFulfillment(viewModel.actions) { action in
            guard case .queued(roomID: "2") = action else { return false }
            return true
        }

        context.send(viewAction: .send)
        try await queued.fulfill()

        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == .admitted)
        viewModel.confirmForwardingCompleted()
        #expect(ledgerStore.state(accountID: RoomMemberProxyMock.mockMe.userID,
                                  destinationRoomID: "2",
                                  item: forwardingItem) == nil)
    }

    @Test
    func timelineProxyPropagatesForwardingSendFailures() async {
        let timeline = TimelineSDKMock()
        timeline.sendMsgThrowableError = ForwardingTestError.sendFailed
        let timelineProxy = TimelineProxy(timeline: timeline, kind: .live)

        guard case .failure = await timelineProxy.queueMessageEventContent(.init(noHandle: .init())) else {
            Issue.record("Expected the SDK send failure to be propagated.")
            return
        }
    }

    private func makeForwardingBatch(count: Int) -> MessageForwardingBatch {
        let items = (1...count).map { index in
            MessageForwardingItem(id: .event(uniqueID: .init("t\(index)"), eventOrTransactionID: .eventID("t\(index)")),
                                  roomID: "1",
                                  content: .init(noHandle: .init()))
        }
        guard let batch = MessageForwardingBatch(firstItem: items[0], remainingItems: Array(items.dropFirst())) else {
            preconditionFailure("Test batches must respect the production forwarding limit.")
        }
        return batch
    }

    private func persistAdmission(_ state: MessageForwardingLedgerState,
                                  item: MessageForwardingItem,
                                  in ledgerStore: MessageForwardingLedgerStoreProtocol) {
        let owner = MessageForwardingLedgerOwner(launchID: "previous-launch", reservationID: UUID().uuidString)
        #expect(ledgerStore.reserveAdmissions(owner: owner,
                                              accountID: RoomMemberProxyMock.mockMe.userID,
                                              destinationRoomID: "2",
                                              items: [item]) == .stored)
        #expect(ledgerStore.setState(state,
                                     owner: owner,
                                     accountID: RoomMemberProxyMock.mockMe.userID,
                                     destinationRoomID: "2",
                                     item: item) == .stored)
    }

    private func makeViewModel(forwardingBatch: MessageForwardingBatch,
                               targetTimeline: TimelineProxyProtocol,
                               userIndicatorController: UserIndicatorControllerProtocol? = nil,
                               ledgerStore: MessageForwardingLedgerStoreProtocol = InMemoryMessageForwardingLedgerStore(),
                               notificationCenter: NotificationCenter = .default) -> MessageForwardingScreenViewModel {
        let targetRoom = JoinedRoomProxyMock(.init(id: "2"))
        targetRoom.timeline = targetTimeline
        let clientProxy = ClientProxyMock(.init())
        clientProxy.roomForIdentifierClosure = { _ in .joined(targetRoom) }
        return MessageForwardingScreenViewModel(forwardingBatch: forwardingBatch,
                                                userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))),
                                                userIndicatorController: userIndicatorController ?? UserIndicatorControllerMock(),
                                                ledgerStore: ledgerStore,
                                                notificationCenter: notificationCenter)
    }

    private func waitForSendCount(_ count: Int, timeline: TimelineProxyMock) async throws {
        for _ in 0..<100 where timeline.queueMessageEventContentCallsCount < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(timeline.queueMessageEventContentCallsCount == count)
    }

    private func waitForSDKSendCount(_ count: Int, timeline: TimelineSDKMock) async throws {
        for _ in 0..<100 where timeline.sendMsgCallsCount < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(timeline.sendMsgCallsCount == count)
    }

    private func waitForAbortCount(_ count: Int, handle: SendHandleSDKMock) async throws {
        for _ in 0..<100 where handle.abortCallsCount < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(handle.abortCallsCount == count)
    }

    private func waitForCondition(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ForwardingTestError.timedOut
    }
}

private final class InMemoryMessageForwardingLedgerStore: MessageForwardingLedgerStoreProtocol {
    private struct Key: Hashable {
        let accountID: String
        let destinationRoomID: String
        let item: MessageForwardingItem
    }

    private struct Entry {
        var state: MessageForwardingLedgerState
        var owner: MessageForwardingLedgerOwner?
    }

    private var entries = [Key: Entry]()

    func state(accountID: String,
               destinationRoomID: String,
               item: MessageForwardingItem) -> MessageForwardingLedgerState? {
        entries[Key(accountID: accountID, destinationRoomID: destinationRoomID, item: item)]?.state
    }

    func reserveAdmissions(owner: MessageForwardingLedgerOwner,
                           accountID: String,
                           destinationRoomID: String,
                           items: [MessageForwardingItem]) -> MessageForwardingLedgerMutationResult {
        let keys = items.map { Key(accountID: accountID, destinationRoomID: destinationRoomID, item: $0) }
        guard keys.allSatisfy({ entries[$0] == nil }) else { return .alreadyReserved }
        for item in items {
            entries[Key(accountID: accountID, destinationRoomID: destinationRoomID, item: item)] = .init(state: .admitting,
                                                                                                         owner: owner)
        }
        return .stored
    }

    func setState(_ state: MessageForwardingLedgerState,
                  owner: MessageForwardingLedgerOwner,
                  accountID: String,
                  destinationRoomID: String,
                  item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult {
        let key = Key(accountID: accountID, destinationRoomID: destinationRoomID, item: item)
        guard var entry = entries[key], entry.owner == owner else { return .notOwner }
        entry.state = state
        entries[key] = entry
        return .stored
    }

    func releaseUnknownAdmissions(owner: MessageForwardingLedgerOwner,
                                  accountID: String,
                                  destinationRoomID: String,
                                  items: [MessageForwardingItem]) -> Bool {
        let keys = items.map { Key(accountID: accountID, destinationRoomID: destinationRoomID, item: $0) }
        for key in keys {
            guard let entry = entries[key], entry.owner == owner, entry.state == .unknown else { return false }
        }
        for key in keys {
            entries[key]?.owner = nil
        }
        return true
    }

    func removeStates(owner: MessageForwardingLedgerOwner,
                      accountID: String,
                      destinationRoomID: String,
                      items: [MessageForwardingItem],
                      includingPreviousLaunches: Bool) -> Bool {
        let keys = items.map { Key(accountID: accountID, destinationRoomID: destinationRoomID, item: $0) }
        for key in keys {
            guard let entry = entries[key], entry.owner != owner else { continue }
            let isFromPreviousLaunch = entry.owner == nil || entry.owner?.launchID != owner.launchID
            guard includingPreviousLaunches, isFromPreviousLaunch else { return false }
        }
        for item in items {
            entries.removeValue(forKey: Key(accountID: accountID, destinationRoomID: destinationRoomID, item: item))
        }
        return true
    }
}

private final class CapacityExceededMessageForwardingLedgerStore: MessageForwardingLedgerStoreProtocol {
    func state(accountID: String,
               destinationRoomID: String,
               item: MessageForwardingItem) -> MessageForwardingLedgerState? {
        nil
    }

    func reserveAdmissions(owner: MessageForwardingLedgerOwner,
                           accountID: String,
                           destinationRoomID: String,
                           items: [MessageForwardingItem]) -> MessageForwardingLedgerMutationResult {
        .capacityExceeded
    }

    func setState(_ state: MessageForwardingLedgerState,
                  owner: MessageForwardingLedgerOwner,
                  accountID: String,
                  destinationRoomID: String,
                  item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult {
        .capacityExceeded
    }

    func releaseUnknownAdmissions(owner: MessageForwardingLedgerOwner,
                                  accountID: String,
                                  destinationRoomID: String,
                                  items: [MessageForwardingItem]) -> Bool {
        true
    }

    func removeStates(owner: MessageForwardingLedgerOwner,
                      accountID: String,
                      destinationRoomID: String,
                      items: [MessageForwardingItem],
                      includingPreviousLaunches: Bool) -> Bool {
        true
    }
}

private final class PartialCapacityMessageForwardingLedgerStore: MessageForwardingLedgerStoreProtocol {
    private var admissionCount = 0

    func state(accountID: String,
               destinationRoomID: String,
               item: MessageForwardingItem) -> MessageForwardingLedgerState? {
        nil
    }

    func reserveAdmissions(owner: MessageForwardingLedgerOwner,
                           accountID: String,
                           destinationRoomID: String,
                           items: [MessageForwardingItem]) -> MessageForwardingLedgerMutationResult {
        .capacityExceeded
    }

    func setState(_ state: MessageForwardingLedgerState,
                  owner: MessageForwardingLedgerOwner,
                  accountID: String,
                  destinationRoomID: String,
                  item: MessageForwardingItem) -> MessageForwardingLedgerMutationResult {
        guard state != .admitting || admissionCount == 0 else { return .capacityExceeded }
        if state == .admitting {
            admissionCount += 1
        }
        return .stored
    }

    func releaseUnknownAdmissions(owner: MessageForwardingLedgerOwner,
                                  accountID: String,
                                  destinationRoomID: String,
                                  items: [MessageForwardingItem]) -> Bool {
        true
    }

    func removeStates(owner: MessageForwardingLedgerOwner,
                      accountID: String,
                      destinationRoomID: String,
                      items: [MessageForwardingItem],
                      includingPreviousLaunches: Bool) -> Bool {
        true
    }
}

private enum ForwardingTestError: Error {
    case sendFailed
    case timedOut
}

private final class ForwardingResultSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<SendHandle, TimelineProxyError>]

    init(_ results: [Result<SendHandle, TimelineProxyError>]) {
        self.results = results
    }

    func next() -> Result<SendHandle, TimelineProxyError> {
        lock.lock()
        defer { lock.unlock() }
        return results.removeFirst()
    }
}

private final class ForwardingSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuations = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuations = continuations
        self.continuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }
}

private final class ForwardingCancellationLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var abortStarted = false
    private var abortCompleted = false

    var didStartAbort: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abortStarted
    }

    var didCompleteAbort: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abortCompleted
    }

    func markAbortStarted() {
        lock.lock()
        abortStarted = true
        lock.unlock()
    }

    func markAbortCompleted() {
        lock.lock()
        abortCompleted = true
        lock.unlock()
    }
}
