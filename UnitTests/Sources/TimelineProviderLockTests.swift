//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

@MainActor
extension TimelineViewModelTests {
    @Test
    func sameProviderBuildStartingDuringExtractionInvalidatesForwardingLease() async throws {
        let itemProxy = makeTimelineItemProxy(eventID: "same-provider-edit", uniqueID: "same-provider-edit")
        let paginationState = TimelinePaginationState(backward: .idle, forward: .endReached)
        let updates = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([itemProxy], paginationState))
        let timeline = try makeTimelineProxy(kind: .live, updates: updates.eraseToAnyPublisher())
        let contentGate = ProviderForwardingContentGate()
        timeline.messageEventContentForClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = timeline
        let buildGate = TimelineItemBuildGate(blockedEventID: "same-provider-edit", occurrence: 2)
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: timeline,
                                                    initialFocussedEventID: nil,
                                                    timelineItemFactory: ProviderBuildRoomTimelineItemFactory(gate: buildGate),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)
        defer {
            contentGate.resume()
            buildGate.resume()
        }

        for _ in 0..<100 where timelineController.timelineItems.first?.id.eventID != "same-provider-edit" {
            try await Task.sleep(for: .milliseconds(5))
        }
        let item = try #require(timelineController.timelineItems.first)
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        updates.send(([itemProxy], paginationState))
        await buildGate.waitUntilStarted()
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(150)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        contentGate.resume()

        try await noForward.fulfill()
        #expect(viewModel.state.messageSelectionState.isActive)
    }

    @Test
    func sendingWhileInitialFocusLoadsRestoresLiveProviderOwnership() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        liveTimeline.sendMessageHtmlInReplyToEventIDIntentionalMentionsReturnValue = .success(())
        let focussedTimeline = try makeTimelineProxy(kind: .detached)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        let focusGate = TimelineOperationGate()
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsClosure = { _, _ in
            await focusGate.wait()
            return .success(focussedTimeline)
        }
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: liveTimeline,
                                                    initialFocussedEventID: "initial-focus",
                                                    timelineItemFactory: ProviderLockRoomTimelineItemFactoryStub(),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)
        defer { focusGate.resume() }
        let focusStarted = deferFulfillment(focusGate.started) { _ in true }
        try await focusStarted.fulfill()
        let viewModel = makeProviderLockViewModel(timelineController: timelineController,
                                                  focussedEventID: "initial-focus")
        let liveProviderConfigured = deferFulfillment(timelineController.callbacks, timeout: .milliseconds(250)) { callback in
            guard case .isLive(true) = callback else { return false }
            return true
        }

        viewModel.process(composerAction: .sendMessage(plain: "message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))

        try await liveProviderConfigured.fulfill()
        for _ in 0..<100 where viewModel.state.timelineState.focussedEvent != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(timelineController.activeProviderGeneration > 0)
        #expect(viewModel.state.timelineState.focussedEvent == nil)
    }

    @Test
    func queuedSameIDEditAfterExtractionCannotForwardStaleMultiSelection() async throws {
        let item = makeProviderLockItem(eventID: "queued-edit")
        let editedItem = makeProviderLockItem(id: item.id, body: "Edited")
        let contentGate = ProviderForwardingContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            let content = await contentGate.content(for: itemID)
            DispatchQueue.main.async {
                timelineController.timelineItems = [editedItem]
                timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [editedItem],
                                                                        isSwitchingTimelines: false,
                                                                        providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                        timelineItemsGeneration: timelineController.timelineItemsGeneration))
            }
            return content
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let editedItemPublished = deferFulfillment(viewModel.context.$viewState) { state in
            state.timelineState.itemViewStates.first?.type == RoomTimelineItemType(item: editedItem)
        }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(150)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        contentGate.resume()

        try await editedItemPublished.fulfill()
        try await noForward.fulfill()
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func forwardPaginationResumingDuringPreparationKeepsTheSelectedProvider() async throws {
        let items = [
            makeProviderLockItem(eventID: "pagination-race-1"),
            makeProviderLockItem(eventID: "pagination-race-2")
        ]
        let timelineController = ProviderRaceTimelineController(timelineItems: items)
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false
        viewModel.state.timelineState.paginationState = .init(backward: .idle, forward: .endReached)

        let paginationStarted = deferFulfillment(timelineController.paginationGate.started) { _ in true }
        viewModel.process(viewAction: .paginateForwards)
        try await paginationStarted.fulfill()

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        let contentStarted = deferFulfillment(timelineController.contentGate.started) { _ in true }
        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: items.map(\.id))
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentStarted.fulfill()

        let focusLiveAttempted = deferFulfillment(timelineController.focusLiveAttempts) { _ in true }
        timelineController.paginationGate.resume()
        try await focusLiveAttempted.fulfill()
        timelineController.contentGate.resume()
        try await forwarded.fulfill()

        #expect(timelineController.source == .exact)
        #expect(timelineController.contentSources == [.exact, .exact])
        #expect(!viewModel.state.timelineState.isLive)
    }

    @Test
    func sendCompletionResumingDuringPreparationKeepsTheSelectedProvider() async throws {
        let items = [
            makeProviderLockItem(eventID: "send-race-1"),
            makeProviderLockItem(eventID: "send-race-2")
        ]
        let timelineController = ProviderRaceTimelineController(timelineItems: items)
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false

        let sendStarted = deferFulfillment(timelineController.sendGate.started) { _ in true }
        viewModel.process(composerAction: .sendMessage(plain: "message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await sendStarted.fulfill()

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        let contentStarted = deferFulfillment(timelineController.contentGate.started) { _ in true }
        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: items.map(\.id))
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentStarted.fulfill()

        let focusLiveAttempted = deferFulfillment(timelineController.focusLiveAttempts) { _ in true }
        timelineController.sendGate.resume()
        try await focusLiveAttempted.fulfill()
        timelineController.contentGate.resume()
        try await forwarded.fulfill()

        #expect(timelineController.source == .exact)
        #expect(timelineController.contentSources == [.exact, .exact])
        #expect(!viewModel.state.timelineState.isLive)
    }

    @Test
    func directFocusResumingDuringPreparationKeepsTheSelectedProvider() async throws {
        let items = [
            makeProviderLockItem(eventID: "focus-race-1"),
            makeProviderLockItem(eventID: "focus-race-2")
        ]
        let timelineController = ProviderRaceTimelineController(timelineItems: items)
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false

        let focusStarted = deferFulfillment(timelineController.focusGate.started) { _ in true }
        let focusTask = Task { await viewModel.focusOnEvent(eventID: "coordinator-focus") }
        try await focusStarted.fulfill()

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        let contentStarted = deferFulfillment(timelineController.contentGate.started) { _ in true }
        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: items.map(\.id))
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentStarted.fulfill()

        let focusCompleted = deferFulfillment(timelineController.focusCompletions) { _ in true }
        timelineController.focusGate.resume()
        try await focusCompleted.fulfill()
        timelineController.contentGate.resume()
        try await forwarded.fulfill()
        await focusTask.value

        #expect(timelineController.source == .exact)
        #expect(timelineController.contentSources == [.exact, .exact])
    }

    @Test
    func olderForwardPaginationCompletionCannotOverrideNewerFocusWhileUnlocked() async throws {
        let item = makeProviderLockItem(eventID: "pagination-generation")
        let timelineController = ProviderRaceTimelineController(timelineItems: [item])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false
        viewModel.state.timelineState.paginationState = .init(backward: .idle, forward: .endReached)

        let paginationStarted = deferFulfillment(timelineController.paginationGate.started) { _ in true }
        viewModel.process(viewAction: .paginateForwards)
        try await paginationStarted.fulfill()

        let focusStarted = deferFulfillment(timelineController.focusGate.started) { _ in true }
        let focusTask = Task { await viewModel.focusOnEvent(eventID: "newer-focus") }
        try await focusStarted.fulfill()
        timelineController.focusGate.resume()
        await focusTask.value
        #expect(timelineController.source == .focussed)

        let focusLiveAttempted = deferFulfillment(timelineController.focusLiveAttempts) { _ in true }
        timelineController.paginationGate.resume()
        try await focusLiveAttempted.fulfill()

        #expect(timelineController.source == .focussed)
    }

    @Test
    func olderSendCompletionCannotOverrideNewerFocusWhileUnlocked() async throws {
        let item = makeProviderLockItem(eventID: "send-generation")
        let timelineController = ProviderRaceTimelineController(timelineItems: [item])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false

        let sendStarted = deferFulfillment(timelineController.sendGate.started) { _ in true }
        viewModel.process(composerAction: .sendMessage(plain: "message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await sendStarted.fulfill()

        let focusStarted = deferFulfillment(timelineController.focusGate.started) { _ in true }
        let focusTask = Task { await viewModel.focusOnEvent(eventID: "newer-focus") }
        try await focusStarted.fulfill()
        timelineController.focusGate.resume()
        await focusTask.value
        #expect(timelineController.source == .focussed)

        let focusLiveAttempted = deferFulfillment(timelineController.focusLiveAttempts) { _ in true }
        timelineController.sendGate.resume()
        try await focusLiveAttempted.fulfill()

        #expect(timelineController.source == .focussed)
    }

    @Test
    func directContextMenuForwardingHoldsTheSourceProviderUntilPreparationCompletes() async throws {
        let item = makeProviderLockItem(eventID: "direct-forward-lease")
        let contentGate = ProviderForwardingContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let forwarded = deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == [item.id]
        }

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .forward(itemID: item.id)))
        try await contentRequested.fulfill()
        await viewModel.focusOnEvent(eventID: "newer-focus")
        let focusOnEventCallCount = timelineController.focusOnEventCallCount
        contentGate.resume()
        try await forwarded.fulfill()

        #expect(focusOnEventCallCount == 0)
    }

    @Test
    func directContextMenuForwardingRejectsContentExtractedBeforeAnEdit() async throws {
        let item = makeProviderLockItem(eventID: "direct-forward-edit")
        let editedItem = makeProviderLockItem(id: item.id, body: "Edited after forwarding started")

        try await assertDirectContextMenuForwardingIsInvalidated(originalItem: item, replacementItem: editedItem)
    }

    @Test
    func directContextMenuForwardingRejectsContentExtractedBeforeRedaction() async throws {
        let item = makeProviderLockItem(eventID: "direct-forward-redaction")
        let redactedItem = RedactedRoomTimelineItem(id: item.id,
                                                    body: "Message deleted",
                                                    timestamp: item.timestamp,
                                                    isOutgoing: item.isOutgoing,
                                                    isEditable: false,
                                                    canBeRepliedTo: false,
                                                    sender: item.sender)

        try await assertDirectContextMenuForwardingIsInvalidated(originalItem: item, replacementItem: redactedItem)
    }

    @Test
    func newerDirectForwardingWaitsForCancelledExtractionToReleaseItsLease() async throws {
        let item = makeProviderLockItem(eventID: "direct-forward-replacement")
        let contentGate = ProviderForwardingContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        var forwardingActionCount = 0
        let cancellable = viewModel.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }

        let firstContentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .forward(itemID: item.id)))
        try await firstContentRequested.fulfill()

        let secondContentRequested = deferFulfillment(contentGate.requests, timeout: .milliseconds(250)) { $0 == item.id }
        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: [item.id])
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .forward(itemID: item.id)))
        await Task.yield()
        contentGate.resume()
        try await secondContentRequested.fulfill()

        contentGate.resume()
        try await forwarded.fulfill()

        #expect(forwardingActionCount == 1)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func deinitializingTimelineViewModelCancelsDirectForwardingPreparation() async throws {
        let item = makeProviderLockItem(eventID: "direct-forward-deinit")
        let contentGate = ProviderForwardingContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        var viewModel: TimelineViewModel? = makeProviderLockViewModel(timelineController: timelineController)
        weak let weakViewModel = viewModel
        var forwardingActionCount = 0
        let cancellable = viewModel?.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        viewModel?.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .forward(itemID: item.id)))
        try await contentRequested.fulfill()

        viewModel = nil
        await Task.yield()
        let providerMutationToken = timelineController.providerMutationToken()
        contentGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(weakViewModel == nil)
        #expect(providerMutationToken != nil)
        #expect(forwardingActionCount == 0)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func messageSelectionSupersedesSuspendedDirectForwarding() async throws {
        let item = makeProviderLockItem(eventID: "selection-supersedes-direct")
        let contentGate = ProviderForwardingContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        var forwardingActionCount = 0
        let cancellable = viewModel.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .forward(itemID: item.id)))
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))
        #expect(viewModel.state.messageSelectionState.isActive)
        #expect(viewModel.state.messageSelectionState.isSelected(.eventID("selection-supersedes-direct")))

        contentGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(forwardingActionCount == 0)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func coordinatorDirectFocusIsIgnoredDuringMessageSelection() async {
        let item = makeProviderLockItem(eventID: "direct-focus-lock")
        let timelineController = MockTimelineController(timelineItems: [item])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        await viewModel.focusOnEvent(eventID: "coordinator-focus")

        #expect(timelineController.focusOnEventCallCount == 0)
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func timelineControllerRejectsFocusSubscribedBeforeProviderLock() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        let focussedTimeline = try makeTimelineProxy(kind: .detached)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(focussedTimeline)
        let subscriptionGate = TimelineOperationGate()
        focussedTimeline.subscribeForUpdatesClosure = {
            await subscriptionGate.wait()
        }
        let timelineController = makeTimelineController(roomProxy: roomProxy, timelineProxy: liveTimeline)
        let providerMutationToken = try #require(timelineController.providerMutationToken())

        let subscriptionStarted = deferFulfillment(subscriptionGate.started) { _ in true }
        let focusTask = Task {
            await timelineController.focusOnEvent("target", timelineSize: 100, using: providerMutationToken)
        }
        try await subscriptionStarted.fulfill()
        timelineController.setProviderMutationLocked(true)
        subscriptionGate.resume()

        switch await focusTask.value {
        case .failure(.providerMutationInvalidated):
            break
        default:
            Issue.record("A focus resolved after provider locking should be invalidated.")
        }
        #expect(timelineController.timelineKind == .live)
    }

    @Test
    func timelineControllerRejectsStaleFocusLiveAfterProviderUnlocks() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        let focussedTimeline = try makeTimelineProxy(kind: .detached)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(focussedTimeline)
        let timelineController = makeTimelineController(roomProxy: roomProxy, timelineProxy: liveTimeline)
        let focusToken = try #require(timelineController.providerMutationToken())
        _ = await timelineController.focusOnEvent("target", timelineSize: 100, using: focusToken)
        #expect(timelineController.timelineKind == .detached)

        let staleToken = try #require(timelineController.providerMutationToken())
        timelineController.setProviderMutationLocked(true)
        timelineController.setProviderMutationLocked(false)

        #expect(!timelineController.focusLive(using: staleToken))
        #expect(timelineController.timelineKind == .detached)
        let currentToken = try #require(timelineController.providerMutationToken())
        #expect(timelineController.focusLive(using: currentToken))
        #expect(timelineController.timelineKind == .live)
    }

    @Test
    func olderFocusCompletionCannotOverrideNewerFocusWhileUnlocked() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        let olderTimeline = try makeTimelineProxy(kind: .detached)
        let newerTimeline = try makeTimelineProxy(kind: .pinned)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        let olderFocusGate = TimelineOperationGate()
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsClosure = { eventID, _ in
            if eventID == "older" {
                await olderFocusGate.wait()
                return .success(olderTimeline)
            }
            return .success(newerTimeline)
        }
        let timelineController = makeTimelineController(roomProxy: roomProxy, timelineProxy: liveTimeline)
        let olderToken = try #require(timelineController.providerMutationToken())

        let olderFocusStarted = deferFulfillment(olderFocusGate.started) { _ in true }
        let olderFocusTask = Task {
            await timelineController.focusOnEvent("older", timelineSize: 100, using: olderToken)
        }
        try await olderFocusStarted.fulfill()

        let newerToken = try #require(timelineController.providerMutationToken())
        guard case .success = await timelineController.focusOnEvent("newer", timelineSize: 100, using: newerToken) else {
            Issue.record("The newer focus should be accepted.")
            return
        }
        #expect(timelineController.timelineKind == .pinned)

        olderFocusGate.resume()
        guard case .failure(.providerMutationInvalidated) = await olderFocusTask.value else {
            Issue.record("The older focus should be invalidated by the newer accepted focus.")
            return
        }
        #expect(timelineController.timelineKind == .pinned)
    }

    @Test
    func olderFailedFocusCompletionIsInvalidatedByNewerMutation() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        let olderFocusGate = TimelineOperationGate()
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsClosure = { _, _ in
            await olderFocusGate.wait()
            return .failure(.eventNotFound)
        }
        let timelineController = makeTimelineController(roomProxy: roomProxy, timelineProxy: liveTimeline)
        let olderToken = try #require(timelineController.providerMutationToken())

        let olderFocusStarted = deferFulfillment(olderFocusGate.started) { _ in true }
        let olderFocusTask = Task {
            await timelineController.focusOnEvent("older", timelineSize: 100, using: olderToken)
        }
        try await olderFocusStarted.fulfill()

        let newerToken = try #require(timelineController.providerMutationToken())
        #expect(timelineController.focusLive(using: newerToken))
        olderFocusGate.resume()

        guard case .failure(.providerMutationInvalidated) = await olderFocusTask.value else {
            Issue.record("The older failed focus should be invalidated by the newer mutation.")
            return
        }
    }

    @Test
    func initialFailedFocusCompletionCannotReconfigureNewerProvider() async throws {
        let liveTimeline = try makeTimelineProxy(kind: .live)
        let newerTimeline = try makeTimelineProxy(kind: .pinned)
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        let olderFocusGate = TimelineOperationGate()
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsClosure = { eventID, _ in
            if eventID == "older" {
                await olderFocusGate.wait()
                return .failure(.eventNotFound)
            }
            return .success(newerTimeline)
        }
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: liveTimeline,
                                                    initialFocussedEventID: "older",
                                                    timelineItemFactory: ProviderLockRoomTimelineItemFactoryStub(),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)
        let olderFocusStarted = deferFulfillment(olderFocusGate.started) { _ in true }
        try await olderFocusStarted.fulfill()

        var configurationCount = 0
        let duplicateConfiguration = deferFailure(timelineController.callbacks, timeout: .milliseconds(150)) { callback in
            guard case .isLive = callback else { return false }
            configurationCount += 1
            return configurationCount > 1
        }
        let newerToken = try #require(timelineController.providerMutationToken())
        guard case .success = await timelineController.focusOnEvent("newer", timelineSize: 100, using: newerToken) else {
            Issue.record("The newer focus should be accepted.")
            return
        }

        olderFocusGate.resume()
        try await duplicateConfiguration.fulfill()
        #expect(timelineController.timelineKind == .pinned)
    }

    @Test
    func cancelledProviderBuildCannotPublishOverTheActiveProvider() async throws {
        let staleProxy = makeTimelineItemProxy(eventID: "stale-event", uniqueID: "provider-local-id")
        let activeProxy = makeTimelineItemProxy(eventID: "active-event", uniqueID: "provider-local-id")
        let paginationState = TimelinePaginationState(backward: .idle, forward: .endReached)
        let staleUpdates = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([staleProxy], paginationState))
        let activeUpdates = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([activeProxy], paginationState))
        let liveTimeline = try makeTimelineProxy(kind: .live, updates: staleUpdates.eraseToAnyPublisher())
        let focussedTimeline = try makeTimelineProxy(kind: .detached, updates: activeUpdates.eraseToAnyPublisher())
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(focussedTimeline)
        let buildGate = TimelineItemBuildGate(blockedEventID: "stale-event")
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: liveTimeline,
                                                    initialFocussedEventID: nil,
                                                    timelineItemFactory: ProviderBuildRoomTimelineItemFactory(gate: buildGate),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)

        await buildGate.waitUntilStarted()
        defer { buildGate.resume() }
        let activePublished = deferFulfillment(timelineController.callbacks) { callback in
            guard case .updatedTimelineItems(let items, _, _, _) = callback else { return false }
            return items.first?.id.eventID == "active-event"
        }
        let focusToken = try #require(timelineController.providerMutationToken())
        guard case .success = await timelineController.focusOnEvent("active-event", timelineSize: 100, using: focusToken) else {
            Issue.record("The active provider focus should be accepted.")
            return
        }
        try await activePublished.fulfill()

        let stalePublished = deferFailure(timelineController.callbacks, timeout: .milliseconds(150)) { callback in
            guard case .updatedTimelineItems(let items, _, _, _) = callback else { return false }
            return items.first?.id.eventID == "stale-event"
        }
        buildGate.resume()
        try await stalePublished.fulfill()

        #expect(timelineController.timelineItems.first?.id.eventID == "active-event")
    }

    @Test
    func providerReplacementBuildWindowDoesNotLeaseRetiredItems() async throws {
        let retiredID = TimelineItemIdentifier.event(uniqueID: .init("provider-local-id"),
                                                     eventOrTransactionID: .eventID("retired-event"))
        let retiredProxy = makeTimelineItemProxy(eventID: "retired-event", uniqueID: "provider-local-id")
        let replacementProxy = makeTimelineItemProxy(eventID: "replacement-event", uniqueID: "provider-local-id")
        let paginationState = TimelinePaginationState(backward: .idle, forward: .endReached)
        let liveUpdates = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([retiredProxy], paginationState))
        let focussedUpdates = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([replacementProxy], paginationState))
        let liveTimeline = try makeTimelineProxy(kind: .live, updates: liveUpdates.eraseToAnyPublisher())
        let focussedTimeline = try makeTimelineProxy(kind: .detached, updates: focussedUpdates.eraseToAnyPublisher())
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        roomProxy.timeline = liveTimeline
        roomProxy.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(focussedTimeline)
        let buildGate = TimelineItemBuildGate(blockedEventID: "replacement-event")
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: liveTimeline,
                                                    initialFocussedEventID: nil,
                                                    timelineItemFactory: ProviderBuildRoomTimelineItemFactory(gate: buildGate),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)

        for _ in 0..<100 where timelineController.timelineItems.first?.id.eventID != "retired-event" {
            try await Task.sleep(for: .milliseconds(5))
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactOthers = true
        let focusToken = try #require(timelineController.providerMutationToken())
        guard case .success = await timelineController.focusOnEvent("replacement-event", timelineSize: 100, using: focusToken) else {
            Issue.record("The replacement provider focus should be accepted.")
            return
        }

        await buildGate.waitUntilStarted()
        defer { buildGate.resume() }
        #expect(timelineController.timelineItems.first?.id.eventID == "retired-event")

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredID, action: .selectMessages))
        #expect(!viewModel.state.messageSelectionState.isActive)

        buildGate.resume()
        for _ in 0..<100 where timelineController.timelineItems.first?.id.eventID != "replacement-event" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(timelineController.timelineItems.first?.id.eventID == "replacement-event")
        #expect(!viewModel.state.messageSelectionState.isActive)
    }

    @Test
    func providerSwitchDoesNotTransferSelectionOrActionsAcrossLocalIdentifierCollision() async throws {
        let uniqueID = TimelineItemIdentifier.UniqueID("provider-local-id")
        let retiredItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("retired-event")))
        let replacementItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("replacement-event")))

        let forwardingController = MockTimelineController(timelineItems: [retiredItem])
        let forwardingViewModel = makeProviderLockViewModel(timelineController: forwardingController)
        forwardingViewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id, action: .selectMessages))
        forwardingController.activeProviderGeneration = 1
        forwardingController.timelineItemsProviderGeneration = 1
        forwardingController.timelineItems = [replacementItem]
        forwardingController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                  isSwitchingTimelines: true,
                                                                  providerGeneration: 1,
                                                                  timelineItemsGeneration: forwardingController.timelineItemsGeneration))
        for _ in 0..<100 where forwardingViewModel.state.timelineState.itemViewStates.first?.identifier != replacementItem.id {
            try await Task.sleep(for: .milliseconds(5))
        }

        let noForward = deferFailure(forwardingViewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        forwardingViewModel.process(viewAction: .forwardMessageSelection)
        try await noForward.fulfill()
        #expect(!forwardingViewModel.state.messageSelectionState.isActive)

        let redactionController = MockTimelineController(timelineItems: [retiredItem])
        let redactionViewModel = makeProviderLockViewModel(timelineController: redactionController)
        redactionViewModel.state.canCurrentUserRedactOthers = true
        redactionViewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id, action: .selectMessages))
        redactionController.activeProviderGeneration = 1
        redactionController.timelineItemsProviderGeneration = 1
        redactionController.timelineItems = [replacementItem]
        redactionController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                 isSwitchingTimelines: true,
                                                                 providerGeneration: 1,
                                                                 timelineItemsGeneration: redactionController.timelineItemsGeneration))
        for _ in 0..<100 where redactionViewModel.state.timelineState.itemViewStates.first?.identifier != replacementItem.id {
            try await Task.sleep(for: .milliseconds(5))
        }
        redactionViewModel.process(viewAction: .confirmMessageRedaction)
        for _ in 0..<100 where redactionController.redactedEventOrTransactionIDs.isEmpty {
            await Task.yield()
        }

        #expect(redactionController.redactedEventOrTransactionIDs.isEmpty)
        #expect(!redactionViewModel.state.messageSelectionState.isActive)
    }

    @Test
    func delayedRowSelectionCannotCrossAProviderGenerationCollision() async throws {
        let uniqueID = TimelineItemIdentifier.UniqueID("delayed-row-provider-local-id")
        let retiredItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("delayed-row-retired")))
        let replacementItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("delayed-row-replacement")))
        let timelineController = MockTimelineController(timelineItems: [retiredItem])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)

        let replacementPublished = deferFulfillment(viewModel.context.$viewState) { state in
            state.timelineState.itemViewStates.first?.identifier == replacementItem.id
        }
        timelineController.activeProviderGeneration = 1
        timelineController.timelineItemsProviderGeneration = 1
        timelineController.timelineItems = [replacementItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                isSwitchingTimelines: true,
                                                                providerGeneration: 1,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        try await replacementPublished.fulfill()

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id, action: .selectMessages))

        #expect(!viewModel.state.messageSelectionState.isActive)
        #expect(!viewModel.state.messageSelectionState.isSelected(.eventID("delayed-row-replacement")))
    }

    @Test
    func delayedMenuActionsCannotCrossAProviderGenerationCollision() async throws {
        let uniqueID = TimelineItemIdentifier.UniqueID("delayed-menu-provider-local-id")
        let retiredItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("delayed-menu-retired")))
        let replacementItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("delayed-menu-replacement")))
        let timelineController = MockTimelineController(timelineItems: [retiredItem])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactOthers = true

        let replacementPublished = deferFulfillment(viewModel.context.$viewState) { state in
            state.timelineState.itemViewStates.first?.identifier == replacementItem.id
        }
        timelineController.activeProviderGeneration = 1
        timelineController.timelineItemsProviderGeneration = 1
        timelineController.timelineItems = [replacementItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                isSwitchingTimelines: true,
                                                                providerGeneration: 1,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        try await replacementPublished.fulfill()

        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(150)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id,
                                                                    action: .forward(itemID: retiredItem.id)))
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id, action: .redact))
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(timelineController.redactedEventOrTransactionIDs.isEmpty)
        try await noForward.fulfill()
    }

    @Test
    func delayedRowAndMenuActionsCannotEnterAProviderReplacementBuildWindow() async throws {
        let retiredItem = makeProviderLockItem(eventID: "delayed-build-window-retired")
        let timelineController = MockTimelineController(timelineItems: [retiredItem])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactOthers = true

        timelineController.activeProviderGeneration = 1
        let noActionMenu = deferFailure(viewModel.context.$viewState, timeout: .milliseconds(150)) { state in
            state.bindings.actionMenuInfo != nil
        }

        viewModel.process(viewAction: .displayTimelineItemMenu(itemID: retiredItem.id))
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: retiredItem.id, action: .redact))

        try await noActionMenu.fulfill()
        #expect(timelineController.redactedEventOrTransactionIDs.isEmpty)
    }

    @Test
    func staleProviderCallbackCannotReplaceTheActiveProviderSelection() async throws {
        let uniqueID = TimelineItemIdentifier.UniqueID("provider-local-id")
        let staleItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("stale-event")))
        let activeItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("active-event")))
        let timelineController = MockTimelineController(timelineItems: [activeItem])
        timelineController.activeProviderGeneration = 1
        timelineController.timelineItemsProviderGeneration = 1
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: activeItem.id, action: .selectMessages))

        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [staleItem],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: 0,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        for _ in 0..<100 where viewModel.state.timelineState.itemViewStates.first?.identifier == activeItem.id {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(viewModel.state.timelineState.itemViewStates.first?.identifier == activeItem.id)
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("active-event")])
    }

    @Test
    func providerLocalIdentifierCollisionDoesNotResolveDifferentEvent() {
        let activeProxy = makeTimelineItemProxy(eventID: "active-event", uniqueID: "provider-local-id")
        let staleID = TimelineItemIdentifier.event(uniqueID: .init("provider-local-id"), eventOrTransactionID: .eventID("stale-event"))

        #expect([activeProxy].firstEventTimelineItemUsingStableID(staleID) == nil)
    }

    @Test
    func selectedLocalEchoReconcilesToRemoteIdentityAndCapabilities() async throws {
        let uniqueID = TimelineItemIdentifier.UniqueID("local-echo")
        let localItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .transactionID("transaction")),
                                             isOutgoing: true)
        let remoteItem = makeProviderLockItem(id: .event(uniqueID: uniqueID, eventOrTransactionID: .eventID("event")),
                                              isOutgoing: true)
        let timelineController = MockTimelineController(timelineItems: [localItem])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactSelf = true
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: localItem.id, action: .selectMessages))

        timelineController.timelineItems = [remoteItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [remoteItem],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        for _ in 0..<100 where viewModel.state.timelineState.itemViewStates.first?.identifier != remoteItem.id {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("event")])
        #expect(viewModel.state.messageSelectionState.isSelected(.eventID("event")))
        #expect(viewModel.state.messageSelectionState.canRedactSelectedMessages)
        #expect(viewModel.state.messageSelectionState.canForwardSelectedMessages)
        guard viewModel.state.messageSelectionState.selectedIDs == [.eventID("event")] else { return }

        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: [remoteItem.id])
        viewModel.process(viewAction: .forwardMessageSelection)
        try await forwarded.fulfill()

        let redactionController = MockTimelineController(timelineItems: [localItem])
        let redactionViewModel = makeProviderLockViewModel(timelineController: redactionController)
        redactionViewModel.state.canCurrentUserRedactSelf = true
        redactionViewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: localItem.id, action: .selectMessages))
        redactionController.timelineItems = [remoteItem]
        redactionController.callbacks.send(.updatedTimelineItems(timelineItems: [remoteItem],
                                                                 isSwitchingTimelines: false,
                                                                 providerGeneration: redactionController.timelineItemsProviderGeneration,
                                                                 timelineItemsGeneration: redactionController.timelineItemsGeneration))
        for _ in 0..<100 where redactionViewModel.state.timelineState.itemViewStates.first?.identifier != remoteItem.id {
            try await Task.sleep(for: .milliseconds(5))
        }
        redactionViewModel.process(viewAction: .confirmMessageRedaction)
        for _ in 0..<100 where redactionController.redactedEventOrTransactionIDs.isEmpty {
            await Task.yield()
        }

        #expect(redactionController.redactedEventOrTransactionIDs == [.eventID("event")])
    }

    @Test
    func sameIdentityUpdatesRefreshAndRemoveSelectionCapabilities() async throws {
        let item = makeProviderLockItem(eventID: "capability-update")
        let pollItem = PollRoomTimelineItem(id: item.id,
                                            poll: .disclosed(),
                                            body: "Poll",
                                            timestamp: item.timestamp,
                                            isOutgoing: item.isOutgoing,
                                            isEditable: false,
                                            canBeRepliedTo: true,
                                            sender: item.sender,
                                            properties: .init())
        let timelineController = MockTimelineController(timelineItems: [item])
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactOthers = true
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))
        #expect(viewModel.state.messageSelectionState.canForwardSelectedMessages)
        #expect(viewModel.state.messageSelectionState.canRedactSelectedMessages)

        viewModel.state.canCurrentUserRedactOthers = false
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [item],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        for _ in 0..<100 where viewModel.state.messageSelectionState.canRedactSelectedMessages {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(viewModel.state.messageSelectionState.isActive)
        #expect(viewModel.state.messageSelectionState.canForwardSelectedMessages)
        #expect(!viewModel.state.messageSelectionState.canRedactSelectedMessages)

        timelineController.timelineItems = [pollItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [pollItem],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        for _ in 0..<100 where viewModel.state.messageSelectionState.isActive {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(!viewModel.state.messageSelectionState.isActive)
        #expect(viewModel.state.messageSelectionState.selectedCount == 0)
        #expect(!viewModel.state.messageSelectionState.canForwardSelectedMessages)
        #expect(!viewModel.state.messageSelectionState.canRedactSelectedMessages)
    }

    @Test
    func messageSelectionRejectsA151stMessageWithoutTruncatingConstructedState() {
        var selectionState = TimelineMessageSelectionState()
        for index in 1...150 {
            selectionState.insert(.init(id: .eventID("selection-limit-\(index)"), canRedact: true, canForward: true))
        }

        #expect(selectionState.selectedCount == 150)
        #expect(selectionState.canForwardSelectedMessages)

        selectionState.insert(.init(id: .eventID("selection-limit-151"), canRedact: true, canForward: true))
        #expect(selectionState.selectedCount == 150)
        #expect(!selectionState.isSelected(.eventID("selection-limit-151")))

        let bypassIDs = Set((1...151).map { TimelineItemIdentifier.EventOrTransactionID.eventID("constructed-selection-\($0)") })
        let constructedState = TimelineMessageSelectionState(selectedIDs: bypassIDs)
        #expect(constructedState.selectedCount == 151)
        #expect(!constructedState.canForwardSelectedMessages)
    }

    @Test
    func paginationCannotExpandForwardingSelectionPast150Messages() async throws {
        let items = (1...151).map { makeProviderLockItem(eventID: "paginated-selection-\($0)") }
        let timelineController = MockTimelineController(timelineItems: Array(items.prefix(75)))
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        for item in items[1..<75] {
            viewModel.process(viewAction: .toggleMessageSelection(itemID: item.id))
        }

        let paginationPublished = deferFulfillment(viewModel.context.$viewState) { state in
            state.timelineState.itemsDictionary[items[150].id.uniqueID] != nil
        }
        timelineController.timelineItems = items
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: items,
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        try await paginationPublished.fulfill()

        for item in items[75...] {
            viewModel.process(viewAction: .toggleMessageSelection(itemID: item.id))
        }

        #expect(viewModel.state.messageSelectionState.selectedCount == 150)
        #expect(!viewModel.state.messageSelectionState.isSelected(.eventID("paginated-selection-151")))
        let forwarded = forwardingFulfillment(viewModel: viewModel, itemIDs: Array(items.prefix(150)).map(\.id))
        viewModel.process(viewAction: .forwardMessageSelection)
        try await forwarded.fulfill()
    }

    @Test
    func threadTimelineDoesNotOfferMessageSelection() throws {
        let item = makeProviderLockItem(eventID: "thread-message")
        let actions = try #require(TimelineItemMenuActionProvider(timelineItem: item,
                                                                  canCurrentUserSendMessage: true,
                                                                  canCurrentUserRedactSelf: true,
                                                                  canCurrentUserRedactOthers: true,
                                                                  canCurrentUserPin: false,
                                                                  pinnedEventIDs: [],
                                                                  isDM: false,
                                                                  isViewSourceEnabled: false,
                                                                  areThreadsEnabled: true,
                                                                  timelineKind: .thread(rootEventID: "root"),
                                                                  emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings))
                .makeActions())

        #expect(!actions.secondaryActions.contains(.selectMessages))
    }

    private func makeProviderLockViewModel(timelineController: TimelineControllerProtocol,
                                           focussedEventID: String? = nil) -> TimelineViewModel {
        TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "")),
                          focussedEventID: focussedEventID,
                          timelineController: timelineController,
                          userSession: UserSessionMock(.init()),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: userIndicatorControllerMock,
                          appMediator: AppMediatorMock.default,
                          appSettings: ServiceLocator.shared.settings,
                          analyticsService: ServiceLocator.shared.analytics,
                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }

    private func forwardingFulfillment(viewModel: TimelineViewModel,
                                       itemIDs: [TimelineItemIdentifier]) -> DeferredFulfillment<TimelineViewModelAction> {
        deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == itemIDs
        }
    }

    private func makeProviderLockItem(eventID: String) -> TextRoomTimelineItem {
        makeProviderLockItem(id: .event(uniqueID: .init(UUID().uuidString), eventOrTransactionID: .eventID(eventID)))
    }

    private func makeProviderLockItem(id: TimelineItemIdentifier,
                                      isOutgoing: Bool = false,
                                      body: String = "Hello, World!") -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: id,
                             timestamp: .mock,
                             isOutgoing: isOutgoing,
                             isEditable: false,
                             canBeRepliedTo: true,
                             sender: .init(id: "@alice:server.com", displayName: "alice"),
                             content: .init(body: body))
    }

    private func assertDirectContextMenuForwardingIsInvalidated(originalItem: TextRoomTimelineItem,
                                                                replacementItem: RoomTimelineItemProtocol) async throws {
        let contentGate = ProviderForwardingContentGate()
        defer { contentGate.resume() }
        let timelineController = MockTimelineController(timelineItems: [originalItem])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeProviderLockViewModel(timelineController: timelineController)
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == originalItem.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(150)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: originalItem.id,
                                                                    action: .forward(itemID: originalItem.id)))
        try await contentRequested.fulfill()

        let replacementType = RoomTimelineItemType(item: replacementItem)
        let replacementPublished = deferFulfillment(viewModel.context.$viewState) { state in
            state.timelineState.itemViewStates.first?.type == replacementType
        }
        timelineController.timelineItems = [replacementItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        try await replacementPublished.fulfill()

        contentGate.resume()
        try await noForward.fulfill()
    }

    private func makeTimelineProxy(kind: TimelineKind) throws -> TimelineProxyMock {
        try makeTimelineProxy(kind: kind, updates: Empty().eraseToAnyPublisher())
    }

    private func makeTimelineProxy(kind: TimelineKind,
                                   updates: AnyPublisher<([TimelineItemProxy], TimelinePaginationState), Never>) throws -> TimelineProxyMock {
        let timelineProxy = TimelineProxyMock(.init())
        let timelineItemProvider = try #require(timelineProxy.timelineItemProvider as? TimelineItemProviderMock)
        timelineItemProvider.kind = kind
        timelineItemProvider.underlyingUpdatePublisher = updates
        return timelineProxy
    }

    private func makeTimelineItemProxy(eventID: String, uniqueID: String) -> TimelineItemProxy {
        .event(EventTimelineItemProxy(item: .mockMessage(configuration: .init(eventID: eventID)),
                                      uniqueID: .init(uniqueID)))
    }

    private func makeTimelineController(roomProxy: JoinedRoomProxyProtocol,
                                        timelineProxy: TimelineProxyProtocol) -> TimelineController {
        TimelineController(roomProxy: roomProxy,
                           timelineProxy: timelineProxy,
                           initialFocussedEventID: nil,
                           timelineItemFactory: ProviderLockRoomTimelineItemFactoryStub(),
                           mediaProvider: MediaProviderMock(),
                           appSettings: ServiceLocator.shared.settings)
    }
}

private struct ProviderLockRoomTimelineItemFactoryStub: RoomTimelineItemFactoryProtocol {
    func buildTimelineItem(for eventItemProxy: EventTimelineItemProxy, isDM: Bool) -> RoomTimelineItemProtocol? {
        nil
    }

    func buildTimelineItemReply(_ details: InReplyToDetails) -> TimelineItemReply {
        fatalError("Not used by provider lock tests.")
    }
}

private struct ProviderBuildRoomTimelineItemFactory: RoomTimelineItemFactoryProtocol {
    let gate: TimelineItemBuildGate

    func buildTimelineItem(for eventItemProxy: EventTimelineItemProxy, isDM: Bool) -> RoomTimelineItemProtocol? {
        gate.blockIfNeeded(eventID: eventItemProxy.id.eventID)
        return TextRoomTimelineItem(id: eventItemProxy.id,
                                    timestamp: .mock,
                                    isOutgoing: false,
                                    isEditable: false,
                                    canBeRepliedTo: true,
                                    sender: .init(id: "@alice:example.org"),
                                    content: .init(body: eventItemProxy.id.eventID ?? ""))
    }

    func buildTimelineItemReply(_ details: InReplyToDetails) -> TimelineItemReply {
        fatalError("Not used by provider build tests.")
    }
}

private final class TimelineItemBuildGate: @unchecked Sendable {
    private let blockedEventID: String
    private let occurrence: Int
    private let lock = NSLock()
    private var matchingBuildCount = 0
    private let started = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)

    init(blockedEventID: String, occurrence: Int = 1) {
        self.blockedEventID = blockedEventID
        self.occurrence = occurrence
    }

    func blockIfNeeded(eventID: String?) {
        guard eventID == blockedEventID else { return }
        let shouldBlock = lock.withLock {
            matchingBuildCount += 1
            return matchingBuildCount == occurrence
        }
        guard shouldBlock else { return }
        started.signal()
        resumed.wait()
    }

    func waitUntilStarted() async {
        await Task.detached { [self] in
            waitForStart()
        }.value
    }

    func resume() {
        resumed.signal()
    }

    private func waitForStart() {
        started.wait()
    }
}

@MainActor
private final class TimelineOperationGate {
    let started = PassthroughSubject<Void, Never>()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.send()
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class ProviderForwardingContentGate {
    let requests = PassthroughSubject<TimelineItemIdentifier, Never>()
    private var continuation: CheckedContinuation<RoomMessageEventContentWithoutRelation?, Never>?

    func content(for itemID: TimelineItemIdentifier) async -> RoomMessageEventContentWithoutRelation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requests.send(itemID)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: .init(noHandle: .init()))
    }
}

@MainActor
private final class ProviderRaceTimelineController: MockTimelineController {
    enum Source: Equatable {
        case exact
        case live
        case focussed
    }

    let paginationGate = TimelineOperationGate()
    let sendGate = TimelineOperationGate()
    let focusGate = TimelineOperationGate()
    let contentGate = TimelineOperationGate()
    let focusLiveAttempts = PassthroughSubject<Void, Never>()
    let focusCompletions = PassthroughSubject<Void, Never>()

    private(set) var source = Source.exact
    private(set) var contentSources = [Source]()

    init(timelineItems: [RoomTimelineItemProtocol]) {
        super.init(timelineKind: .detached, timelineItems: timelineItems)
    }

    override func paginateForwards(requestSize: UInt16) async -> Result<Void, TimelineControllerError> {
        await paginationGate.wait()
        return .success(())
    }

    override func sendMessage(_ message: String,
                              html: String?,
                              inReplyToEventID: String?,
                              intentionalMentions: IntentionalMentions) async {
        await sendGate.wait()
    }

    override func focusOnEvent(_ eventID: String,
                               timelineSize: UInt16,
                               using providerMutationToken: TimelineProviderMutationToken) async -> Result<Void, TimelineControllerError> {
        await focusGate.wait()
        let result = await super.focusOnEvent(eventID,
                                              timelineSize: timelineSize,
                                              using: providerMutationToken)
        if case .success = result {
            source = .focussed
        }
        focusCompletions.send()
        return result
    }

    override func focusLive(using providerMutationToken: TimelineProviderMutationToken) -> Bool {
        let didFocusLive = super.focusLive(using: providerMutationToken)
        if didFocusLive {
            source = .live
        }
        focusLiveAttempts.send()
        return didFocusLive
    }

    override func messageEventContent(for itemID: TimelineItemIdentifier) async -> RoomMessageEventContentWithoutRelation? {
        contentSources.append(source)
        if contentSources.count == 1 {
            await contentGate.wait()
        }
        return .init(noHandle: .init())
    }
}
