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
import Testing

@MainActor
final class TimelineViewModelTests {
    var userIndicatorControllerMock: UserIndicatorControllerMock!
    var cancellables = Set<AnyCancellable>()

    init() async throws {
        AppSettings.resetAllSettings()
        cancellables.removeAll()
        userIndicatorControllerMock = UserIndicatorControllerMock.default
    }

    deinit {
        userIndicatorControllerMock = nil
    }

    // MARK: - Message Grouping

    @Test
    func messageGrouping() {
        // Given 3 messages from Bob.
        let items = [
            TextRoomTimelineItem(text: "Message 1",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 2",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 3",
                                 sender: "bob")
        ]

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        // Then the messages should be grouped together.
        #expect(viewModel.state.timelineState.itemViewStates[0].groupStyle == .first, "Nothing should prevent the first message from being grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[1].groupStyle == .middle, "Nothing should prevent the middle message from being grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[2].groupStyle == .last, "Nothing should prevent the last message from being grouped.")
    }

    @Test
    func messageGroupingMultipleSenders() {
        // Given some interleaved messages from Bob and Alice.
        let items = [
            TextRoomTimelineItem(text: "Message 1",
                                 sender: "alice"),
            TextRoomTimelineItem(text: "Message 2",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 3",
                                 sender: "alice"),
            TextRoomTimelineItem(text: "Message 4",
                                 sender: "alice"),
            TextRoomTimelineItem(text: "Message 5",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 6",
                                 sender: "bob")
        ]

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        // Then the messages should be grouped by sender.
        #expect(viewModel.state.timelineState.itemViewStates[0].groupStyle == .single, "A message should not be grouped when the sender changes.")
        #expect(viewModel.state.timelineState.itemViewStates[1].groupStyle == .single, "A message should not be grouped when the sender changes.")
        #expect(viewModel.state.timelineState.itemViewStates[2].groupStyle == .first, "A group should start with a new sender if there are more messages from that sender.")
        #expect(viewModel.state.timelineState.itemViewStates[3].groupStyle == .last, "A group should be ended when the sender changes in the next message.")
        #expect(viewModel.state.timelineState.itemViewStates[4].groupStyle == .first, "A group should start with a new sender if there are more messages from that sender.")
        #expect(viewModel.state.timelineState.itemViewStates[5].groupStyle == .last, "A group should be ended when the sender changes in the next message.")
    }

    @Test
    func messageGroupingWithLeadingReactions() {
        // Given 3 messages from Bob where the first message has a reaction.
        let items = [
            TextRoomTimelineItem(text: "Message 1",
                                 sender: "bob",
                                 addReactions: true),
            TextRoomTimelineItem(text: "Message 2",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 3",
                                 sender: "bob")
        ]

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        // Then the first message should not be grouped but the other two should.
        #expect(viewModel.state.timelineState.itemViewStates[0].groupStyle == .single, "When the first message has reactions it should not be grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[1].groupStyle == .first, "A new group should be made when the preceding message has reactions.")
        #expect(viewModel.state.timelineState.itemViewStates[2].groupStyle == .last, "Nothing should prevent the last message from being grouped.")
    }

    @Test
    func messageGroupingWithInnerReactions() {
        // Given 3 messages from Bob where the middle message has a reaction.
        let items = [
            TextRoomTimelineItem(text: "Message 1",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 2",
                                 sender: "bob",
                                 addReactions: true),
            TextRoomTimelineItem(text: "Message 3",
                                 sender: "bob")
        ]

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        // Then the first and second messages should be grouped and the last one should not.
        #expect(viewModel.state.timelineState.itemViewStates[0].groupStyle == .first, "Nothing should prevent the first message from being grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[1].groupStyle == .last, "When the message has reactions, the group should end here.")
        #expect(viewModel.state.timelineState.itemViewStates[2].groupStyle == .single, "The last message should not be grouped when the preceding message has reactions.")
    }

    @Test
    func messageGroupingWithTrailingReactions() {
        // Given 3 messages from Bob where the last message has a reaction.
        let items = [
            TextRoomTimelineItem(text: "Message 1",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 2",
                                 sender: "bob"),
            TextRoomTimelineItem(text: "Message 3",
                                 sender: "bob",
                                 addReactions: true)
        ]

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        // Then the messages should be grouped together.
        #expect(viewModel.state.timelineState.itemViewStates[0].groupStyle == .first, "Nothing should prevent the first message from being grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[1].groupStyle == .middle, "Nothing should prevent the second message from being grouped.")
        #expect(viewModel.state.timelineState.itemViewStates[2].groupStyle == .last, "Reactions on the last message should not prevent it from being grouped.")
    }

    // MARK: - Focussing

    @Test
    func focusItem() async throws {
        // Given a room with 3 items loaded in a live timeline.
        let items = [TextRoomTimelineItem(eventID: "t1"),
                     TextRoomTimelineItem(eventID: "t2"),
                     TextRoomTimelineItem(eventID: "t3")]
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items

        let viewModel = makeViewModel(timelineController: timelineController)
        #expect(timelineController.focusOnEventCallCount == 0)
        #expect(viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == nil)

        // When focussing on an item that isn't loaded.
        let deferred = deferFulfillment(viewModel.context.$viewState) { !$0.timelineState.isLive }
        await viewModel.focusOnEvent(eventID: "t4")
        try await deferred.fulfill()

        // Then a new timeline should be loaded and the room focussed on that event.
        #expect(timelineController.focusOnEventCallCount == 1)
        #expect(!viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == .init(eventID: "t4", appearance: .immediate))
    }

    @Test
    func focusLoadedItem() async throws {
        // Given a room with 3 items loaded in a live timeline.
        let items = [TextRoomTimelineItem(eventID: "t1"),
                     TextRoomTimelineItem(eventID: "t2"),
                     TextRoomTimelineItem(eventID: "t3")]
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items

        let viewModel = makeViewModel(timelineController: timelineController)
        #expect(timelineController.focusOnEventCallCount == 0)
        #expect(viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == nil)

        // When focussing on a loaded item.
        let deferred = deferFailure(viewModel.context.$viewState, timeout: .seconds(1)) { !$0.timelineState.isLive }
        await viewModel.focusOnEvent(eventID: "t1")
        try await deferred.fulfill()

        // Then the timeline should remain live and the item should be focussed.
        #expect(timelineController.focusOnEventCallCount == 0)
        #expect(viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == .init(eventID: "t1", appearance: .animated))
    }

    @Test
    func focusLive() async throws {
        // Given a room with a non-live timeline focussed on a particular event.
        let items = [TextRoomTimelineItem(eventID: "t1"),
                     TextRoomTimelineItem(eventID: "t2"),
                     TextRoomTimelineItem(eventID: "t3")]
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items

        let viewModel = makeViewModel(timelineController: timelineController)

        var deferred = deferFulfillment(viewModel.context.$viewState) { !$0.timelineState.isLive }
        await viewModel.focusOnEvent(eventID: "t4")
        try await deferred.fulfill()

        #expect(timelineController.focusLiveCallCount == 0)
        #expect(!viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == .init(eventID: "t4", appearance: .immediate))

        // When switching back to a live timeline.
        deferred = deferFulfillment(viewModel.context.$viewState) { $0.timelineState.isLive }
        viewModel.context.send(viewAction: .focusLive)
        try await deferred.fulfill()

        // Then the timeline should switch back to being live and the event focus should be removed.
        #expect(timelineController.focusLiveCallCount == 1)
        #expect(viewModel.context.viewState.timelineState.isLive)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == nil)
    }

    @Test
    func initialFocusViewState() {
        let timelineController = MockTimelineController()

        let viewModel = makeViewModel(focussedEventID: "t10", timelineController: timelineController)
        #expect(viewModel.context.viewState.timelineState.focussedEvent == .init(eventID: "t10", appearance: .immediate))
    }

    // MARK: - Read Receipts

    @Test
    func visibleReadReceiptSelectorSkipsVirtualAndLocalOnlyItems() {
        let remoteItemID = TimelineItemIdentifier.event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event"))
        let visibleItemIDs: [TimelineItemIdentifier] = [
            .virtual(uniqueID: .init("virtual")),
            .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("transaction")),
            remoteItemID
        ]

        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: visibleItemIDs,
                                                                      isTimelineVisible: true,
                                                                      isTimelineContentVisible: true,
                                                                      isFocussedScrollPending: false) == remoteItemID)
    }

    @Test
    func visibleReadReceiptSelectorReturnsNilWithoutRemoteEvents() {
        let visibleItemIDs: [TimelineItemIdentifier] = [
            .virtual(uniqueID: .init("virtual")),
            .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("transaction"))
        ]

        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: visibleItemIDs,
                                                                      isTimelineVisible: true,
                                                                      isTimelineContentVisible: true,
                                                                      isFocussedScrollPending: false) == nil)
    }

    @Test
    func visibleReadReceiptSelectorReturnsNilWhenTimelineIsHidden() {
        let remoteItemID = TimelineItemIdentifier.event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event"))

        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: [remoteItemID],
                                                                      isTimelineVisible: false,
                                                                      isTimelineContentVisible: true,
                                                                      isFocussedScrollPending: false) == nil)
    }

    @Test
    func visibleReadReceiptSelectorReturnsNilWhenTimelineContentIsHidden() {
        let remoteItemID = TimelineItemIdentifier.event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event"))

        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: [remoteItemID],
                                                                      isTimelineVisible: true,
                                                                      isTimelineContentVisible: false,
                                                                      isFocussedScrollPending: false) == nil)
    }

    @Test
    func visibleReadReceiptSelectorReturnsNilWhileFocussedScrollIsPending() {
        let remoteItemID = TimelineItemIdentifier.event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event"))

        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: [remoteItemID],
                                                                      isTimelineVisible: true,
                                                                      isTimelineContentVisible: true,
                                                                      isFocussedScrollPending: true) == nil)
    }

    @Test
    func focussedScrollRequestDoesNotCompleteForWrongVisibleTarget() {
        var state = TimelineTableViewController.FocussedScrollRequestState()
        let generation = state.begin(eventID: "target", animated: true)
        let didStart = state.markStarted(requestGeneration: generation)
        let didComplete = state.complete(requestGeneration: generation, visibleEventIDs: ["other"])

        #expect(didStart)
        #expect(!didComplete)
        #expect(state.isPending)
    }

    @Test
    func focussedScrollRequestCompletesForMatchingVisibleTarget() {
        var state = TimelineTableViewController.FocussedScrollRequestState()
        let generation = state.begin(eventID: "target", animated: true)
        _ = state.markStarted(requestGeneration: generation)
        let didComplete = state.complete(requestGeneration: generation, visibleEventIDs: ["target"])

        #expect(didComplete)
        #expect(!state.isPending)
    }

    @Test
    func staleFocussedScrollGenerationDoesNotCompleteReplacementRequest() {
        var state = TimelineTableViewController.FocussedScrollRequestState()
        let staleGeneration = state.begin(eventID: "old", animated: true)
        _ = state.markStarted(requestGeneration: staleGeneration)
        let replacementGeneration = state.begin(eventID: "replacement", animated: true)
        _ = state.markStarted(requestGeneration: replacementGeneration)
        let staleDidComplete = state.complete(requestGeneration: staleGeneration, visibleEventIDs: ["replacement"])

        #expect(!staleDidComplete)
        #expect(state.isPending)
        let replacementDidComplete = state.complete(requestGeneration: replacementGeneration, visibleEventIDs: ["replacement"])
        #expect(replacementDidComplete)
    }

    @Test
    func cancellingFocussedScrollRequestUnblocksVisibleReceiptSelection() {
        let remoteItemID = TimelineItemIdentifier.event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event"))
        var state = TimelineTableViewController.FocussedScrollRequestState()
        let generation = state.begin(eventID: "target", animated: true)
        _ = state.markStarted(requestGeneration: generation)

        state.cancel()

        #expect(!state.isPending)
        #expect(TimelineTableViewController.readReceiptItemIdentifier(in: [remoteItemID],
                                                                      isTimelineVisible: true,
                                                                      isTimelineContentVisible: true,
                                                                      isFocussedScrollPending: state.isPending) == remoteItemID)
    }

    @Test
    func sendReadReceipt() async throws {
        // Given a room with only text items in the timeline
        let items = [TextRoomTimelineItem(eventID: "t1"),
                     TextRoomTimelineItem(eventID: "t2"),
                     TextRoomTimelineItem(eventID: "t3")]
        let (viewModel, _, timelineProxy, _) = readReceiptsConfiguration(with: items)

        // When sending a read receipt for the last item.
        try viewModel.context.send(viewAction: .sendReadReceiptIfNeeded(#require(items.last?.id)))
        try await Task.sleep(for: .milliseconds(100))

        // Then the receipt should be sent.
        #expect(timelineProxy.sendReadReceiptForTypeCalled == true)
        let arguments = timelineProxy.sendReadReceiptForTypeReceivedArguments
        #expect(arguments?.eventID == "t3")
        #expect(arguments?.type == .read)
    }

    @Test
    func sendPublicReadReceiptWhenSharingPresence() async throws {
        try await assertReadReceiptType(sharePresence: true, expectedReceiptType: .read)
    }

    @Test
    func sendPrivateReadReceiptWhenNotSharingPresence() async throws {
        try await assertReadReceiptType(sharePresence: false, expectedReceiptType: .readPrivate)
    }

    @Test
    func sendReadReceiptWithoutEvents() async throws {
        // Given a room with only virtual items.
        let items = [SeparatorRoomTimelineItem(uniqueID: .init("v1")),
                     SeparatorRoomTimelineItem(uniqueID: .init("v2")),
                     SeparatorRoomTimelineItem(uniqueID: .init("v3"))]
        let (viewModel, _, timelineProxy, _) = readReceiptsConfiguration(with: items)

        // When sending a read receipt for the last item.
        try viewModel.context.send(viewAction: .sendReadReceiptIfNeeded(#require(items.last?.id)))
        try await Task.sleep(for: .milliseconds(100))

        // Then nothing should be sent.
        #expect(timelineProxy.sendReadReceiptForTypeCalled == false)
    }

    @Test
    func sendReadReceiptVirtualLast() async throws {
        // Given a room where the last event is a virtual item.
        let items: [RoomTimelineItemProtocol] = [TextRoomTimelineItem(eventID: "t1"),
                                                 TextRoomTimelineItem(eventID: "t2"),
                                                 SeparatorRoomTimelineItem(uniqueID: .init("v3"))]
        let (viewModel, _, timelineProxy, _) = readReceiptsConfiguration(with: items)

        // When sending a read receipt for the last item.
        try viewModel.context.send(viewAction: .sendReadReceiptIfNeeded(#require(items.last?.id)))
        try await Task.sleep(for: .milliseconds(100))

        // Then nothing should be sent.
        #expect(timelineProxy.sendReadReceiptForTypeCalled == false)
    }

    // swiftlint:disable:next large_tuple
    private func readReceiptsConfiguration(with items: [RoomTimelineItemProtocol]) -> (TimelineViewModel,
                                                                                       JoinedRoomProxyMock,
                                                                                       TimelineProxyMock,
                                                                                       MockTimelineController) {
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))

        let timelineProxy = TimelineProxyMock()

        roomProxy.timeline = timelineProxy
        let timelineController = MockTimelineController()

        timelineProxy.sendReadReceiptForTypeReturnValue = .success(())

        timelineController.timelineItems = items
        timelineController.roomProxy = roomProxy

        let viewModel = TimelineViewModel(roomProxy: roomProxy,
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
        return (viewModel, roomProxy, timelineProxy, timelineController)
    }

    private func assertReadReceiptType(sharePresence: Bool, expectedReceiptType: ReceiptType) async throws {
        ServiceLocator.shared.settings.sharePresence = sharePresence
        let roomProxy = JoinedRoomProxyMock(.init(name: ""))
        let timelineProxy = TimelineProxyMock(.init())
        let recorder = ReadReceiptRecorder()
        timelineProxy.sendReadReceiptForTypeClosure = { await recorder.send(eventID: $0, type: $1) }
        let timelineItemProvider = try #require(timelineProxy.timelineItemProvider as? TimelineItemProviderMock)
        timelineItemProvider.kind = .live
        timelineItemProvider.underlyingUpdatePublisher = Empty().eraseToAnyPublisher()
        roomProxy.timeline = timelineProxy
        let timelineController = TimelineController(roomProxy: roomProxy,
                                                    timelineProxy: timelineProxy,
                                                    initialFocussedEventID: nil,
                                                    timelineItemFactory: RoomTimelineItemFactoryStub(),
                                                    mediaProvider: MediaProviderMock(),
                                                    appSettings: ServiceLocator.shared.settings)

        await timelineController.sendReadReceipt(for: .event(uniqueID: .init("remote"), eventOrTransactionID: .eventID("event")))

        #expect(await recorder.eventIDs == ["event", "event"])
        #expect(await recorder.types == [expectedReceiptType, .fullyRead])
    }

    @Test
    func showReadReceipts() async throws {
        let receipts: [ReadReceipt] = [.init(userID: "@alice:matrix.org", formattedTimestamp: "12:00"),
                                       .init(userID: "@charlie:matrix.org", formattedTimestamp: "11:00")]
        // Given 3 messages from Bob where the middle message has a reaction.
        let message = TextRoomTimelineItem(text: "Test",
                                           sender: "bob",
                                           addReadReceipts: receipts)
        let id = message.id

        // When showing them in a timeline.
        let timelineController = MockTimelineController()
        timelineController.timelineItems = [message]
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "", members: [RoomMemberProxyMock.mockAlice, RoomMemberProxyMock.mockCharlie])),
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

        let deferred = deferFulfillment(viewModel.context.$viewState) { value in
            value.bindings.readReceiptsSummaryInfo?.orderedReceipts == receipts
        }

        viewModel.context.send(viewAction: .displayReadReceipts(itemID: id))
        try await deferred.fulfill()
    }

    @Test
    func showManageUserAsAdmin() async throws {
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "",
                                                                               members: [RoomMemberProxyMock.mockAdmin,
                                                                                         RoomMemberProxyMock.mockAlice],
                                                                               ownUserID: RoomMemberProxyMock.mockAdmin.userID)),
                                          timelineController: MockTimelineController(),
                                          userSession: UserSessionMock(.init()),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: userIndicatorControllerMock,
                                          appMediator: AppMediatorMock.default,
                                          appSettings: ServiceLocator.shared.settings,
                                          analyticsService: ServiceLocator.shared.analytics,
                                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))

        var deferred = deferFulfillment(viewModel.context.$viewState) { value in
            value.canCurrentUserKick && value.canCurrentUserBan
        }

        try await deferred.fulfill()

        deferred = deferFulfillment(viewModel.context.$viewState) { value in
            value.bindings.manageMemberViewModel != nil
        }

        viewModel.context.send(viewAction: .tappedOnSenderDetails(sender: .init(with: RoomMemberProxyMock.mockAlice)))
        try await deferred.fulfill()

        #expect(viewModel.context.manageMemberViewModel?.id == RoomMemberProxyMock.mockAlice.userID)
        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canBan == true)
        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canKick == true)
        #expect(viewModel.context.manageMemberViewModel?.state.isKickDisabled == false)
        #expect(viewModel.context.manageMemberViewModel?.state.isBanUnbanDisabled == false)
    }

    @Test
    func showDetailsForAnAdmin() async throws {
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "",
                                                                               members: [RoomMemberProxyMock.mockAdmin,
                                                                                         RoomMemberProxyMock.mockAlice],
                                                                               ownUserID: RoomMemberProxyMock.mockAlice.userID)),
                                          timelineController: MockTimelineController(),
                                          userSession: UserSessionMock(.init()),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: userIndicatorControllerMock,
                                          appMediator: AppMediatorMock.default,
                                          appSettings: ServiceLocator.shared.settings,
                                          analyticsService: ServiceLocator.shared.analytics,
                                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))

        var deferredState = deferFulfillment(viewModel.context.$viewState) { value in
            !value.canCurrentUserKick && !value.canCurrentUserBan
        }

        try await deferredState.fulfill()

        deferredState = deferFulfillment(viewModel.context.$viewState) { value in
            value.bindings.manageMemberViewModel != nil
        }

        viewModel.context.send(viewAction: .tappedOnSenderDetails(sender: .init(with: RoomMemberProxyMock.mockAdmin)))
        try await deferredState.fulfill()

        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canBan == false)
        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canKick == false)
        #expect(viewModel.context.manageMemberViewModel?.state.isKickDisabled == true)
        #expect(viewModel.context.manageMemberViewModel?.state.isBanUnbanDisabled == true)
        #expect(viewModel.context.manageMemberViewModel?.id == RoomMemberProxyMock.mockAdmin.userID)
    }

    @Test
    func showDetailsForABannedUser() async throws {
        let viewModel = TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "",
                                                                               members: [RoomMemberProxyMock.mockAdmin,
                                                                                         RoomMemberProxyMock.mockBanned[0]],
                                                                               ownUserID: RoomMemberProxyMock.mockAdmin.userID)),
                                          timelineController: MockTimelineController(),
                                          userSession: UserSessionMock(.init()),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: userIndicatorControllerMock,
                                          appMediator: AppMediatorMock.default,
                                          appSettings: ServiceLocator.shared.settings,
                                          analyticsService: ServiceLocator.shared.analytics,
                                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))

        var deferredState = deferFulfillment(viewModel.context.$viewState) { value in
            value.canCurrentUserKick && value.canCurrentUserBan
        }

        try await deferredState.fulfill()

        deferredState = deferFulfillment(viewModel.context.$viewState) { value in
            value.bindings.manageMemberViewModel != nil
        }

        viewModel.context.send(viewAction: .tappedOnSenderDetails(sender: .init(with: RoomMemberProxyMock.mockBanned[0])))
        try await deferredState.fulfill()

        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canBan == true)
        #expect(viewModel.context.manageMemberViewModel?.state.permissions.canKick == true)
        #expect(viewModel.context.manageMemberViewModel?.state.isKickDisabled == true)
        #expect(viewModel.context.manageMemberViewModel?.state.isBanUnbanDisabled == false)
        #expect(viewModel.context.manageMemberViewModel?.state.isMemberBanned == true)
        #expect(viewModel.context.manageMemberViewModel?.id == RoomMemberProxyMock.mockBanned[0].userID)
    }

    // MARK: - Pins

    @Test
    func pinnedEvents() async throws {
        var configuration = JoinedRoomProxyMockConfiguration(name: "",
                                                             pinnedEventIDs: .init(["test1"]))
        let roomProxyMock = JoinedRoomProxyMock(configuration)
        let infoSubject = CurrentValueSubject<RoomInfoProxyProtocol, Never>(RoomInfoProxyMock(configuration))
        roomProxyMock.underlyingInfoPublisher = infoSubject.asCurrentValuePublisher()

        let viewModel = TimelineViewModel(roomProxy: roomProxyMock,
                                          timelineController: MockTimelineController(),
                                          userSession: UserSessionMock(.init()),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: userIndicatorControllerMock,
                                          appMediator: AppMediatorMock.default,
                                          appSettings: ServiceLocator.shared.settings,
                                          analyticsService: ServiceLocator.shared.analytics,
                                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        #expect(configuration.pinnedEventIDs == viewModel.context.viewState.pinnedEventIDs)

        configuration.pinnedEventIDs = ["test1", "test2"]
        let deferred = deferFulfillment(viewModel.context.$viewState) { value in
            value.pinnedEventIDs == ["test1", "test2"]
        }
        infoSubject.send(RoomInfoProxyMock(configuration))
        try await deferred.fulfill()
    }

    @Test
    func canUserPinEvents() async throws {
        let configuration = JoinedRoomProxyMockConfiguration(name: "",
                                                             powerLevelsConfiguration: .init(canUserPin: true))
        let roomProxyMock = JoinedRoomProxyMock(configuration)
        let infoSubject = CurrentValueSubject<RoomInfoProxyProtocol, Never>(RoomInfoProxyMock(configuration))
        roomProxyMock.underlyingInfoPublisher = infoSubject.asCurrentValuePublisher()

        let viewModel = TimelineViewModel(roomProxy: roomProxyMock,
                                          timelineController: MockTimelineController(),
                                          userSession: UserSessionMock(.init()),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: userIndicatorControllerMock,
                                          appMediator: AppMediatorMock.default,
                                          appSettings: ServiceLocator.shared.settings,
                                          analyticsService: ServiceLocator.shared.analytics,
                                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))

        var deferred = deferFulfillment(viewModel.context.$viewState) { value in
            value.canCurrentUserPin
        }
        try await deferred.fulfill()

        let powerLevelsProxyMock = RoomPowerLevelsProxyMock(configuration: .init())
        powerLevelsProxyMock.canUserPinOrUnpinUserIDReturnValue = .success(false)
        powerLevelsProxyMock.canOwnUserPinOrUnpinReturnValue = false
        roomProxyMock.powerLevelsReturnValue = .success(powerLevelsProxyMock)

        let roomInfoProxyMock = RoomInfoProxyMock(configuration)
        roomInfoProxyMock.powerLevels = powerLevelsProxyMock

        deferred = deferFulfillment(viewModel.context.$viewState) { value in
            !value.canCurrentUserPin
        }
        infoSubject.send(roomInfoProxyMock)
        try await deferred.fulfill()
    }

    // MARK: - Tap Actions

    @Test
    func tapSendInfoEncryptionAuthentictyDisplaysAlert() {
        // Given a room with an event whose authenticity could not be verified
        let items = [TextRoomTimelineItem(eventID: "t1", encryptionAuthenticity: .verificationViolation(color: .red))]
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        #expect(viewModel.state.bindings.alertInfo == nil)

        viewModel.process(viewAction: .itemSendInfoTapped(itemID: items[0].id))

        #expect(viewModel.state.bindings.alertInfo?.title == L10n.cryptoEventAuthenticityPreviouslyVerified)
    }

    @Test
    func tapSendInfoEncryptionForwarderDisplaysAlert() {
        // Given a room with an event whose key was forwarded
        let items = [TextRoomTimelineItem(eventID: "t1", keyForwarder: .test)]
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items
        let viewModel = makeViewModel(timelineController: timelineController)

        #expect(viewModel.state.bindings.alertInfo == nil)

        viewModel.process(viewAction: .itemSendInfoTapped(itemID: items[0].id))

        #expect(viewModel.state.bindings.alertInfo?.title == L10n.cryptoEventKeyForwardedKnownProfileDialogContent("alice", "@alice:matrix.org"))
    }

    @Test
    func privacyEvidenceComesFromTimelineItemPropertiesRatherThanMessageBody() {
        let items = [
            TextRoomTimelineItem(eventID: "unmarked", text: "same body", sender: "bob"),
            TextRoomTimelineItem(eventID: "marked", text: "same body", sender: "bob", isPrivacyControlled: true)
        ]
        let viewModel = makeViewModel(timelineController: MockTimelineController(timelineItems: items))

        let evidence = viewModel.state.timelineState.itemViewStates.compactMap { viewState -> Bool? in
            guard case .text(let item) = viewState.type else { return nil }
            return item.properties.isPrivacyControlled
        }

        #expect(evidence == [false, true])
    }

    @Test
    func privacyEvidenceSurvivesFreshViewModelReconstruction() throws {
        for eventID in ["initial", "restored"] {
            let item = TextRoomTimelineItem(eventID: eventID, isPrivacyControlled: true)
            let viewModel = makeViewModel(timelineController: MockTimelineController(timelineItems: [item]))
            let viewState = try #require(viewModel.state.timelineState.itemViewStates.first)
            guard case .text(let restoredItem) = viewState.type else {
                Issue.record("Expected a text timeline item.")
                return
            }

            #expect(restoredItem.properties.isPrivacyControlled)
        }
    }

    @Test
    func timelineUsesServiceAuthorityInsteadOfStaleLegacyState() async throws {
        let appSettings = AppSettings()
        appSettings.junchatPrivacyModeRoomIDs = ["MockRoomIdentifier"]
        let privacyModeService = PrivacyModeServiceMock(loadResults: [.success(false)])
        let timelineController = MockTimelineController(timelineItems: [])
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: appSettings)

        viewModel.process(composerAction: .sendMessage(plain: "secret",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))

        try await Task.sleep(for: .milliseconds(50))

        #expect(await privacyModeService.loadRoomIDReceivedInvocations == ["MockRoomIdentifier"])
        _ = viewModel
    }

    @Test
    func privacyAuthorityResolvesBeforeSendingMessagesAndReplies() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PrivacyModeSendOrderService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings())

        viewModel.process(composerAction: .sendMessage(plain: "message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(2)

        viewModel.process(composerAction: .sendMessage(plain: "reply",
                                                       html: nil,
                                                       mode: .reply(eventID: "event-id",
                                                                    replyDetails: .notLoaded(eventID: "event-id"),
                                                                    isThread: false),
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(4)

        #expect(await recorder.events == ["privacy-load", "send", "privacy-load", "reply"])
        _ = viewModel
    }

    @Test
    func privacyAuthorityFailureDoesNotPreventOfflineSendQueueing() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PrivacyModeSendOrderService(recorder: recorder,
                                                             loadResult: .failure(.transport(.network)))
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings())

        viewModel.process(composerAction: .sendMessage(plain: "offline message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(2)

        #expect(await recorder.events == ["privacy-load", "send"])
        #expect(timelineController.timelineItems.count == 1)
        _ = viewModel
    }

    @Test
    func cachedPrivacyAuthoritySendsWithoutLoading() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PrivacyModeSendOrderService(recorder: recorder, cachedValue: true)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings(),
                                      privacyModeAuthorityTimeout: .milliseconds(10))

        viewModel.process(composerAction: .sendMessage(plain: "cached message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(1)

        #expect(await recorder.events == ["send"])
        #expect(await privacyModeService.loadCallCount == 0)
        _ = viewModel
    }

    @Test
    func privacyAuthorityTimeoutCancelsAndWaitsForLoadBeforeSending() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PendingCancellablePrivacyModeService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings(),
                                      privacyModeAuthorityTimeout: .milliseconds(10))
        let start = ContinuousClock.now

        viewModel.process(composerAction: .sendMessage(plain: "bounded message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(3)

        #expect(start.duration(to: .now) < .milliseconds(250))
        #expect(await recorder.events == ["load-start", "load-cancelled", "send"])
        #expect(await privacyModeService.loadWasCancelled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.events == ["load-start", "load-cancelled", "send"])
        _ = viewModel
    }

    @Test
    func privacyAuthorityTimeoutCancelsBeforeQueueingReply() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PendingCancellablePrivacyModeService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings(),
                                      privacyModeAuthorityTimeout: .milliseconds(10))

        viewModel.process(composerAction: .sendMessage(plain: "bounded reply",
                                                       html: nil,
                                                       mode: .reply(eventID: "event-id",
                                                                    replyDetails: .notLoaded(eventID: "event-id"),
                                                                    isThread: false),
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(3)

        #expect(await recorder.events == ["load-start", "load-cancelled", "reply"])
        #expect(await privacyModeService.loadWasCancelled)
        _ = viewModel
    }

    @Test
    func sharedRoomScreenPrivacyLoadMigratesBeforeSending() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let transport = HeldLegacyMigrationTransport(recorder: recorder)
        let migrationStore = TimelinePrivacyModeMigrationStore(roomID: "MockRoomIdentifier")
        let coordinator = PrivacyModeOperationCoordinator()
        let roomScreenService = await PrivacyModeService(userID: "@alice:example.org",
                                                         transport: transport,
                                                         migrationStore: migrationStore,
                                                         operationCoordinator: coordinator)
        let timelineService = await PrivacyModeService(userID: "@alice:example.org",
                                                       transport: transport,
                                                       migrationStore: migrationStore,
                                                       operationCoordinator: coordinator)
        let roomScreenViewModel = makeRoomScreenViewModel(privacyModeService: roomScreenService)
        try await transport.waitUntilLoadStarts()

        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let timelineViewModel = makeViewModel(timelineController: timelineController,
                                              privacyModeService: timelineService,
                                              appSettings: AppSettings())
        timelineViewModel.process(composerAction: .sendMessage(plain: "shared authority",
                                                               html: nil,
                                                               mode: .default,
                                                               intentionalMentions: .init(userIDs: [], atRoom: false)))

        try await Task.sleep(for: .milliseconds(20))
        await transport.completeHeldLoad()
        try await recorder.waitForEvent("send")

        let events = await recorder.events
        let loadCount = await transport.loadCount
        #expect(events == ["load-start", "migration-put", "send"])
        #expect(loadCount == 1)
        #expect(await transport.setCount == 1)
        _ = roomScreenViewModel
    }

    @Test
    func roomScreenPrivacyLoadIsCancelledAndJoinedOnPreSendTimeout() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let transport = HeldLegacyMigrationTransport(recorder: recorder)
        let migrationStore = TimelinePrivacyModeMigrationStore(roomID: "MockRoomIdentifier")
        let coordinator = PrivacyModeOperationCoordinator()
        let roomScreenService = await PrivacyModeService(userID: "@alice:example.org",
                                                         transport: transport,
                                                         migrationStore: migrationStore,
                                                         operationCoordinator: coordinator)
        let timelineService = await PrivacyModeService(userID: "@alice:example.org",
                                                       transport: transport,
                                                       migrationStore: migrationStore,
                                                       operationCoordinator: coordinator)
        let roomScreenViewModel = makeRoomScreenViewModel(privacyModeService: roomScreenService)
        try await transport.waitUntilLoadStarts()

        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let timelineViewModel = makeViewModel(timelineController: timelineController,
                                              privacyModeService: timelineService,
                                              appSettings: AppSettings(),
                                              privacyModeAuthorityTimeout: .milliseconds(10))
        timelineViewModel.process(composerAction: .sendMessage(plain: "bounded shared authority",
                                                               html: nil,
                                                               mode: .default,
                                                               intentionalMentions: .init(userIDs: [], atRoom: false)))

        try await recorder.waitForEvent("send")
        await transport.completeHeldLoad()
        try await Task.sleep(for: .milliseconds(50))

        let events = await recorder.events
        let loadCount = await transport.loadCount
        #expect(events == ["load-start", "load-cancelled", "send"])
        #expect(loadCount == 1)
        #expect(await transport.setCount == 0)
        _ = roomScreenViewModel
    }

    @Test
    func viewModelTeardownBeforePrivacyAuthorityCompletesDoesNotSendMessage() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = LifecyclePrivacyModeService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        var viewModel: TimelineViewModel? = makeViewModel(timelineController: timelineController,
                                                          privacyModeService: privacyModeService,
                                                          appSettings: AppSettings())
        weak var weakViewModel: TimelineViewModel?
        weakViewModel = viewModel

        viewModel?.process(composerAction: .sendMessage(plain: "cancelled message",
                                                        html: nil,
                                                        mode: .default,
                                                        intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await privacyModeService.waitUntilLoadCount(1)

        viewModel = nil
        try await Task.sleep(for: .milliseconds(20))
        let wasReleasedBeforeAuthorityCompletion = weakViewModel == nil
        await privacyModeService.completeLoads()
        try await Task.sleep(for: .milliseconds(50))

        #expect(wasReleasedBeforeAuthorityCompletion)
        #expect(weakViewModel == nil)
        #expect(await recorder.events == ["load-start", "load-cancelled"])
        #expect(timelineController.timelineItems.isEmpty)
    }

    @Test
    func viewModelTeardownBeforePrivacyAuthorityCompletesDoesNotSendReply() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = LifecyclePrivacyModeService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        var viewModel: TimelineViewModel? = makeViewModel(timelineController: timelineController,
                                                          privacyModeService: privacyModeService,
                                                          appSettings: AppSettings())
        weak var weakViewModel: TimelineViewModel?
        weakViewModel = viewModel

        viewModel?.process(composerAction: .sendMessage(plain: "cancelled reply",
                                                        html: nil,
                                                        mode: .reply(eventID: "event-id",
                                                                     replyDetails: .notLoaded(eventID: "event-id"),
                                                                     isThread: false),
                                                        intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await privacyModeService.waitUntilLoadCount(1)

        viewModel = nil
        try await Task.sleep(for: .milliseconds(20))
        let wasReleasedBeforeAuthorityCompletion = weakViewModel == nil
        await privacyModeService.completeLoads()
        try await Task.sleep(for: .milliseconds(50))

        #expect(wasReleasedBeforeAuthorityCompletion)
        #expect(weakViewModel == nil)
        #expect(await recorder.events == ["load-start", "load-cancelled"])
        #expect(timelineController.timelineItems.isEmpty)
    }

    @Test
    func repeatedSendsKeepIndependentPrivacyAuthorityTasks() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = LifecyclePrivacyModeService(recorder: recorder)
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: AppSettings())

        viewModel.process(composerAction: .sendMessage(plain: "first message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        viewModel.process(composerAction: .sendMessage(plain: "second message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await privacyModeService.waitUntilLoadCount(2)

        await privacyModeService.completeLoads()
        try await recorder.waitForEventCount(6)

        let events = await recorder.events
        #expect(events.filter { $0 == "load-cancelled" }.isEmpty)
        #expect(events.filter { $0 == "send" }.count == 2)
        #expect(timelineController.timelineItems.count == 2)
        _ = viewModel
    }

    @Test
    func emergencyOverrideStillPerformsPreSendAuthorityMigration() async throws {
        let recorder = PrivacyModeSendOrderRecorder()
        let privacyModeService = PrivacyModeSendOrderService(recorder: recorder,
                                                             loadResult: .success(false))
        let timelineController = PrivacyModeSendOrderTimelineController(recorder: recorder)
        let appSettings = AppSettings()
        appSettings.junchatEmergencyPrivacyModeEnabled = true
        let viewModel = makeViewModel(timelineController: timelineController,
                                      privacyModeService: privacyModeService,
                                      appSettings: appSettings)

        viewModel.process(composerAction: .sendMessage(plain: "emergency message",
                                                       html: nil,
                                                       mode: .default,
                                                       intentionalMentions: .init(userIDs: [], atRoom: false)))
        try await recorder.waitForEventCount(2)

        #expect(await recorder.events == ["privacy-load", "send"])
        _ = viewModel
    }

    @Test
    func messageSelectionRedactsSelectedMessages() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "bulk-1", sender: "bob"),
            TextRoomTimelineItem(eventID: "bulk-2", sender: "bob")
        ]
        let timelineController = MockTimelineController(timelineItems: items)
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactSelf = true

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("bulk-1")])

        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("bulk-1"), .eventID("bulk-2")])

        viewModel.process(viewAction: .confirmMessageRedaction)
        try await Task.sleep(for: .milliseconds(50))

        #expect(Set(timelineController.redactedEventOrTransactionIDs) == [.eventID("bulk-1"), .eventID("bulk-2")])
        #expect(!viewModel.state.messageSelectionState.isActive)
        _ = viewModel
    }

    @Test
    func messageSelectionForwardsSelectedMessages() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "forward-1", sender: "alice"),
            TextRoomTimelineItem(eventID: "forward-2", sender: "alice")
        ]
        let timelineController = MockTimelineController(timelineItems: items)
        let viewModel = makeViewModel(timelineController: timelineController)

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("forward-1")])
        #expect(viewModel.state.messageSelectionState.canForwardSelectedMessages)
        #expect(!viewModel.state.messageSelectionState.canRedactSelectedMessages)

        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("forward-1"), .eventID("forward-2")])

        let deferred = deferFulfillment(viewModel.actions) { action in
            switch action {
            case .displayMessageForwarding(let forwardingBatch):
                return forwardingBatch.items.map(\.id) == items.map(\.id)
            default:
                return false
            }
        }

        viewModel.process(viewAction: .forwardMessageSelection)
        try await deferred.fulfill()

        #expect(!viewModel.state.messageSelectionState.isActive)
        _ = viewModel
    }

    @Test
    func mixedMessageSelectionDoesNotForwardAnIneligibleSubset() async throws {
        let textItem = TextRoomTimelineItem(eventID: "forwardable", sender: "alice")
        let pollItem = PollRoomTimelineItem(id: .event(uniqueID: .init("poll"), eventOrTransactionID: .eventID("poll")),
                                            poll: .disclosed(),
                                            body: "poll",
                                            timestamp: .mock,
                                            isOutgoing: true,
                                            isEditable: false,
                                            canBeRepliedTo: true,
                                            sender: .init(id: "alice"),
                                            properties: .init())
        let timelineController = MockTimelineController(timelineItems: [textItem, pollItem])
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactSelf = true

        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: textItem.id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: pollItem.id))

        #expect(viewModel.state.messageSelectionState.selectedCount == 2)
        #expect(!viewModel.state.messageSelectionState.canForwardSelectedMessages)
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await noForward.fulfill()
        #expect(viewModel.state.messageSelectionState.selectedCount == 2)
    }

    // MARK: - Helpers

    private func makeViewModel(roomProxy: JoinedRoomProxyProtocol? = nil,
                               focussedEventID: String? = nil,
                               timelineController: TimelineControllerProtocol,
                               privacyModeService: PrivacyModeServiceProtocol = PrivacyModeServiceMock(),
                               appSettings: AppSettings = ServiceLocator.shared.settings,
                               privacyModeAuthorityTimeout: Duration = .seconds(1)) -> TimelineViewModel {
        TimelineViewModel(roomProxy: roomProxy ?? JoinedRoomProxyMock(.init(name: "")),
                          focussedEventID: focussedEventID,
                          timelineController: timelineController,
                          userSession: UserSessionMock(.init(privacyModeService: privacyModeService)),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: userIndicatorControllerMock,
                          appMediator: AppMediatorMock.default,
                          appSettings: appSettings,
                          analyticsService: ServiceLocator.shared.analytics,
                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                          privacyModeAuthorityTimeout: privacyModeAuthorityTimeout)
    }

    private func makeRoomScreenViewModel(privacyModeService: PrivacyModeServiceProtocol) -> RoomScreenViewModel {
        RoomScreenViewModel(userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init()),
                                                               privacyModeService: privacyModeService)),
                            roomProxy: JoinedRoomProxyMock(.init(id: "MockRoomIdentifier", hasOngoingCall: false)),
                            initialSelectedPinnedEventID: nil,
                            ongoingCallRoomIDPublisher: .init(.init(nil)),
                            appSettings: AppSettings(),
                            appHooks: AppHooks(),
                            analyticsService: ServiceLocator.shared.analytics,
                            userIndicatorController: userIndicatorControllerMock)
    }
}

extension TimelineViewModelTests {
    @Test
    func messageActionsAreHiddenDuringMessageSelection() {
        #expect(TimelineItemAccessibilityPolicy.showsMessageActions(isMessageSelectionActive: false))
        #expect(!TimelineItemAccessibilityPolicy.showsMessageActions(isMessageSelectionActive: true))
    }

    @Test
    func scrollToBottomButtonIsHiddenAndInertDuringMessageSelection() {
        let available = TimelineScrollToBottomButtonState(isAtBottomAndLive: false, isInteractionLocked: false)
        #expect(!available.isVisuallyHidden)
        #expect(available.allowsHitTesting)
        #expect(!available.isAccessibilityHidden)

        let locked = TimelineScrollToBottomButtonState(isAtBottomAndLive: false, isInteractionLocked: true)
        #expect(locked.isVisuallyHidden)
        #expect(!locked.allowsHitTesting)
        #expect(locked.isAccessibilityHidden)
    }

    @Test
    func scrollToBottomCannotLeaveFocusedTimelineDuringMessageSelection() {
        let item = TextRoomTimelineItem(eventID: "scroll-lock", sender: "alice")
        let timelineController = MockTimelineController(timelineItems: [item])
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        viewModel.process(viewAction: .scrollToBottom)

        #expect(timelineController.focusLiveCallCount == 0)
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func automaticForwardPaginationCannotLeaveFocusedTimelineDuringMessageSelection() async throws {
        let item = TextRoomTimelineItem(eventID: "pagination-lock", sender: "alice")
        let timelineController = MockTimelineController(timelineItems: [item])
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false
        viewModel.state.timelineState.paginationState = .init(backward: .idle, forward: .endReached)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        viewModel.process(viewAction: .paginateForwards)
        try await Task.sleep(for: .milliseconds(50))

        #expect(timelineController.paginateForwardsCallCount == 0)
        #expect(timelineController.focusLiveCallCount == 0)
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func scrollToBottomCancelsSuspendedPreparationWithoutForwardingFromOldProvider() async throws {
        let item = TextRoomTimelineItem(eventID: "stale-provider", sender: "alice")
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.timelineState.isLive = false
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .scrollToBottom)
        contentGate.resume(itemID: item.id)

        try await contentCompleted.fulfill()
        try await noForward.fulfill()
        #expect(timelineController.focusLiveCallCount == 0)
        #expect(contentGate.cancelledIDs == [item.id])
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func sameIDEditCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "edited", text: "Original", sender: "alice")
        let replacement = TextRoomTimelineItem(eventID: "edited", text: "Edited", sender: "alice")

        try await assertTimelineReplacementCancelsForwardingPreparation(item: item, replacement: replacement)
    }

    @Test
    func sameIDRedactionCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "redacted", sender: "alice")
        let replacement = RedactedRoomTimelineItem(id: item.id,
                                                   body: "Removed",
                                                   timestamp: item.timestamp,
                                                   isOutgoing: item.isOutgoing,
                                                   isEditable: false,
                                                   canBeRepliedTo: false,
                                                   sender: item.sender)

        try await assertTimelineReplacementCancelsForwardingPreparation(item: item, replacement: replacement, selectionRemains: false)
    }

    @Test
    func sameIDForwardabilityChangeCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "non-forwardable", sender: "alice")
        let replacement = PollRoomTimelineItem(id: item.id,
                                               poll: .disclosed(),
                                               body: "Poll",
                                               timestamp: item.timestamp,
                                               isOutgoing: item.isOutgoing,
                                               isEditable: false,
                                               canBeRepliedTo: true,
                                               sender: item.sender,
                                               properties: .init())

        try await assertTimelineReplacementCancelsForwardingPreparation(item: item, replacement: replacement, selectionRemains: false)
    }

    @Test
    func threadNavigationCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "thread-navigation", sender: "alice")
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        let noOutboundAction = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            switch action {
            case .displayThread, .displayMessageForwarding:
                true
            default:
                false
            }
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .displayThread(itemID: item.id))
        contentGate.resume(itemID: item.id)

        try await contentCompleted.fulfill()
        try await noOutboundAction.fulfill()
        #expect(contentGate.cancelledIDs == [item.id])
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func senderDetailsCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "sender-details", sender: "alice")
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .tappedOnSenderDetails(sender: item.sender))
        #expect(viewModel.state.bindings.manageMemberViewModel == nil)
        contentGate.resume(itemID: item.id)

        try await contentCompleted.fulfill()
        try await noForward.fulfill()
        #expect(contentGate.cancelledIDs == [item.id])
        #expect(viewModel.state.messageSelectionState.selectedIDs == [item.id.eventOrTransactionID])
    }

    @Test
    func messageSelectionRemainsUntilCompleteForwardingBatchIsPrepared() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "forward-1", sender: "alice"),
            TextRoomTimelineItem(eventID: "forward-2", sender: "alice")
        ]
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: items)
        timelineController.messageEventContentClosure = { itemID in
            guard itemID == items[1].id else {
                return .init(noHandle: .init())
            }
            return await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == items[1].id }
        let forwarded = deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == items.map(\.id)
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        #expect(viewModel.state.messageSelectionState.selectedIDs == Set(items.compactMap(\.id.eventOrTransactionID)))

        contentGate.resume(itemID: items[1].id)
        try await forwarded.fulfill()
        #expect(!viewModel.state.messageSelectionState.isActive)
    }

    @Test
    func deselectingAMessageCancelsSuspendedForwardingPreparation() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "keep-selected", sender: "alice"),
            TextRoomTimelineItem(eventID: "deselect", sender: "alice")
        ]
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: items)
        timelineController.messageEventContentClosure = { itemID in
            guard itemID == items[0].id else {
                return .init(noHandle: .init())
            }
            return await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == items[0].id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == items[0].id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))
        #expect(viewModel.state.messageSelectionState.selectedIDs == [.eventID("keep-selected")])

        contentGate.resume(itemID: items[0].id)
        try await contentCompleted.fulfill()
        try await noForward.fulfill()
        #expect(contentGate.cancelledIDs == [items[0].id])
    }

    @Test
    func redactingMessagesCancelsSuspendedForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "redact", sender: "bob")
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.state.canCurrentUserRedactSelf = true
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))
        #expect(viewModel.state.messageSelectionState.canRedactSelectedMessages)

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel.process(viewAction: .confirmMessageRedaction)
        #expect(!viewModel.state.messageSelectionState.isActive)

        contentGate.resume(itemID: item.id)
        try await contentCompleted.fulfill()
        try await noForward.fulfill()
        #expect(contentGate.cancelledIDs == [item.id])
    }

    @Test
    func newerForwardingRequestCancelsAndSupersedesStalePreparation() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "stale", sender: "alice"),
            TextRoomTimelineItem(eventID: "current", sender: "alice")
        ]
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: items)
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        var forwardedItemIDs = [[TimelineItemIdentifier]]()
        viewModel.actions.sink { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return }
            forwardedItemIDs.append(forwardingBatch.items.map(\.id))
        }
        .store(in: &cancellables)

        let staleContentRequested = deferFulfillment(contentGate.requests) { $0 == items[0].id }
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .forwardMessageSelection)
        try await staleContentRequested.fulfill()

        let currentContentRequested = deferFulfillment(contentGate.requests) { $0 == items[1].id }
        viewModel.state.messageSelectionState = .init(selectedIDs: [.eventID("current")])
        viewModel.process(viewAction: .forwardMessageSelection)
        try await currentContentRequested.fulfill()

        let currentForwarded = deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == [items[1].id]
        }
        contentGate.resume(itemID: items[1].id)
        try await currentForwarded.fulfill()

        let staleContentCompleted = deferFulfillment(contentGate.completions) { $0 == items[0].id }
        contentGate.resume(itemID: items[0].id)
        try await staleContentCompleted.fulfill()

        #expect(contentGate.cancelledIDs == [items[0].id])
        #expect(forwardedItemIDs == [[items[1].id]])
        #expect(!viewModel.state.messageSelectionState.isActive)
    }

    @Test
    func deinitializingTimelineViewModelCancelsForwardingPreparation() async throws {
        let item = TextRoomTimelineItem(eventID: "deinit", sender: "alice")
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        var viewModel: TimelineViewModel? = makeViewModel(timelineController: timelineController)
        weak let weakViewModel = viewModel

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        viewModel?.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))
        viewModel?.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        viewModel = nil
        await Task.yield()
        let wasDeinitializedWhileContentWasSuspended = weakViewModel == nil

        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        contentGate.resume(itemID: item.id)
        try await contentCompleted.fulfill()

        #expect(wasDeinitializedWhileContentWasSuspended)
        #expect(contentGate.cancelledIDs == [item.id])
    }

    @Test
    func disappearingSelectedMessageRetainsSelectionAndShowsAnError() async throws {
        let items = [
            TextRoomTimelineItem(eventID: "visible", sender: "alice"),
            TextRoomTimelineItem(eventID: "disappears", sender: "alice")
        ]
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: items)
        timelineController.messageEventContentClosure = { itemID in
            guard itemID == items[0].id else {
                return .init(noHandle: .init())
            }
            return await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: items[0].id, action: .selectMessages))
        viewModel.process(viewAction: .toggleMessageSelection(itemID: items[1].id))

        var forwardingActionCount = 0
        viewModel.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }
        .store(in: &cancellables)
        let indicators = PassthroughSubject<UserIndicator, Never>()
        var displayedError: UserIndicator?
        userIndicatorControllerMock.submitIndicatorDelayClosure = { indicator, _ in
            displayedError = indicator
            indicators.send(indicator)
        }
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == items[0].id }
        let errorDisplayed = deferFulfillment(indicators) { $0.id == "RoomScreenToastError" }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        #expect(viewModel.state.messageSelectionState.selectedIDs == Set(items.compactMap(\.id.eventOrTransactionID)))

        timelineController.timelineItems.removeLast()
        contentGate.resume(itemID: items[0].id)
        try await errorDisplayed.fulfill()

        #expect(forwardingActionCount == 0)
        #expect(displayedError?.title == UntranslatedL10n.screenRoomMessageSelectionChangedError)
        #expect(displayedError?.title != L10n.errorUnknown)
        #expect(viewModel.state.messageSelectionState.selectedIDs == Set(items.compactMap(\.id.eventOrTransactionID)))
    }

    private func assertTimelineReplacementCancelsForwardingPreparation(item: TextRoomTimelineItem,
                                                                       replacement: RoomTimelineItemProtocol,
                                                                       selectionRemains: Bool = true) async throws {
        let contentGate = MessageEventContentGate()
        let timelineController = MockTimelineController(timelineItems: [item])
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let viewModel = makeViewModel(timelineController: timelineController)
        viewModel.process(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .selectMessages))

        let contentRequested = deferFulfillment(contentGate.requests) { $0 == item.id }
        let contentCompleted = deferFulfillment(contentGate.completions) { $0 == item.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(100)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        viewModel.process(viewAction: .forwardMessageSelection)
        try await contentRequested.fulfill()

        timelineController.timelineItems = [replacement]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [replacement],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))

        contentGate.resume(itemID: item.id)
        try await contentCompleted.fulfill()
        try await noForward.fulfill()

        #expect(contentGate.cancelledIDs == [item.id])
        let selectionID = try #require(item.id.eventOrTransactionID)
        let expectedSelectedIDs: Set<TimelineItemIdentifier.EventOrTransactionID> = selectionRemains ? [selectionID] : []
        #expect(viewModel.state.messageSelectionState.selectedIDs == expectedSelectedIDs)
        #expect(viewModel.state.messageSelectionState.isSelected(selectionID) == selectionRemains)
        #expect(viewModel.state.messageSelectionState.isActive == selectionRemains)
    }
}

@MainActor
private final class MessageEventContentGate {
    let requests = PassthroughSubject<TimelineItemIdentifier, Never>()
    let completions = PassthroughSubject<TimelineItemIdentifier, Never>()
    private(set) var cancelledIDs = Set<TimelineItemIdentifier>()

    private var continuations = [TimelineItemIdentifier: CheckedContinuation<RoomMessageEventContentWithoutRelation?, Never>]()

    func content(for itemID: TimelineItemIdentifier) async -> RoomMessageEventContentWithoutRelation? {
        let content = await withCheckedContinuation { continuation in
            continuations[itemID] = continuation
            requests.send(itemID)
        }

        if Task.isCancelled {
            cancelledIDs.insert(itemID)
        }
        completions.send(itemID)
        return content
    }

    func resume(itemID: TimelineItemIdentifier) {
        continuations.removeValue(forKey: itemID)?.resume(returning: .init(noHandle: .init()))
    }
}

private actor PrivacyModeSendOrderRecorder {
    private(set) var events = [String]()

    func record(_ event: String) {
        events.append(event)
    }

    func waitForEventCount(_ count: Int) async throws {
        for _ in 0..<100 where events.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(events.count == count)
    }

    func waitForEvent(_ event: String) async throws {
        for _ in 0..<100 where !events.contains(event) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(events.contains(event))
    }
}

private actor TimelinePrivacyModeMigrationStore: PrivacyModeMigrationStoreProtocol {
    private let roomID: String
    private var ownerUserID: String?
    private var isPending = true

    init(roomID: String) {
        self.roomID = roomID
    }

    func claimLegacyRoomIDs(for userID: String) -> Set<String> {
        if ownerUserID == nil {
            ownerUserID = userID
        }
        return ownerUserID == userID && isPending ? [roomID] : []
    }

    func consumeLegacyRoomID(_ roomID: String, for userID: String) {
        guard ownerUserID == userID, self.roomID == roomID else {
            return
        }
        isPending = false
    }
}

private actor HeldLegacyMigrationTransport: PrivacyModeTransportProtocol {
    private let recorder: PrivacyModeSendOrderRecorder
    private var heldLoadContinuation: CheckedContinuation<Result<PrivacyModeRemoteState, PrivacyModeTransportError>, Never>?
    private var enabled: Bool?
    private(set) var loadCount = 0
    private(set) var setCount = 0

    init(recorder: PrivacyModeSendOrderRecorder) {
        self.recorder = recorder
    }

    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        loadCount += 1
        await recorder.record("load-start")
        if loadCount > 1 {
            return enabled.map { .success(.present(enabled: $0)) } ?? .success(.absent)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                heldLoadContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelHeldLoad() }
        }
    }

    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError> {
        self.enabled = enabled
        setCount += 1
        await recorder.record("migration-put")
        return .success(())
    }

    func waitUntilLoadStarts() async throws {
        for _ in 0..<100 where heldLoadContinuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(heldLoadContinuation != nil)
    }

    func completeHeldLoad() {
        let continuation = heldLoadContinuation
        heldLoadContinuation = nil
        continuation?.resume(returning: .success(.absent))
    }

    private func cancelHeldLoad() async {
        guard let continuation = heldLoadContinuation else {
            return
        }
        heldLoadContinuation = nil
        await recorder.record("load-cancelled")
        continuation.resume(returning: .failure(.cancelled))
    }
}

private actor PrivacyModeSendOrderService: PrivacyModeServiceProtocol {
    private let recorder: PrivacyModeSendOrderRecorder
    private let loadResult: Result<Bool, PrivacyModeServiceError>
    private let storedCachedValue: Bool?
    private(set) var loadCallCount = 0

    init(recorder: PrivacyModeSendOrderRecorder,
         loadResult: Result<Bool, PrivacyModeServiceError> = .success(true),
         cachedValue: Bool? = nil) {
        self.recorder = recorder
        self.loadResult = loadResult
        storedCachedValue = cachedValue
    }

    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        loadCallCount += 1
        await recorder.record("privacy-load")
        return loadResult
    }

    func cancelLoadAndWait(roomID: String) { }

    func toggle(roomID: String) -> Result<Bool, PrivacyModeServiceError> {
        .success(false)
    }

    func cachedValue(roomID: String) -> Bool? {
        storedCachedValue
    }
}

private actor LifecyclePrivacyModeService: PrivacyModeServiceProtocol {
    private let recorder: PrivacyModeSendOrderRecorder
    private var loadContinuations = [UUID: CheckedContinuation<Result<Bool, PrivacyModeServiceError>, Never>]()
    private var loadCount = 0

    init(recorder: PrivacyModeSendOrderRecorder) {
        self.recorder = recorder
    }

    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        let loadID = UUID()
        loadCount += 1
        await recorder.record("load-start")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loadContinuations[loadID] = continuation
            }
        } onCancel: {
            Task { await self.cancelLoad(id: loadID) }
        }
    }

    func cancelLoadAndWait(roomID: String) { }

    func toggle(roomID: String) -> Result<Bool, PrivacyModeServiceError> {
        .success(false)
    }

    func cachedValue(roomID: String) -> Bool? {
        nil
    }

    func waitUntilLoadCount(_ expectedCount: Int) async throws {
        for _ in 0..<100 where loadCount < expectedCount {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(loadCount == expectedCount)
    }

    func completeLoads() async {
        let continuations = loadContinuations.values
        loadContinuations.removeAll()
        for continuation in continuations {
            await recorder.record("load-completed")
            continuation.resume(returning: .success(true))
        }
    }

    private func cancelLoad(id: UUID) async {
        guard let continuation = loadContinuations.removeValue(forKey: id) else {
            return
        }
        await recorder.record("load-cancelled")
        continuation.resume(returning: .failure(.cancelled))
    }
}

private actor PendingCancellablePrivacyModeService: PrivacyModeServiceProtocol {
    private let recorder: PrivacyModeSendOrderRecorder
    private(set) var loadWasCancelled = false

    init(recorder: PrivacyModeSendOrderRecorder) {
        self.recorder = recorder
    }

    func load(roomID: String) async -> Result<Bool, PrivacyModeServiceError> {
        await recorder.record("load-start")
        do {
            try await Task.sleep(for: .milliseconds(200))
            await recorder.record("late-migration-put")
            return .success(true)
        } catch {
            loadWasCancelled = true
            await recorder.record("load-cancelled")
            return .failure(.cancelled)
        }
    }

    func cancelLoadAndWait(roomID: String) { }

    func toggle(roomID: String) -> Result<Bool, PrivacyModeServiceError> {
        .success(false)
    }

    func cachedValue(roomID: String) -> Bool? {
        nil
    }
}

private final class PrivacyModeSendOrderTimelineController: MockTimelineController {
    private let recorder: PrivacyModeSendOrderRecorder

    init(recorder: PrivacyModeSendOrderRecorder) {
        self.recorder = recorder
        super.init(timelineItems: [])
    }

    override func sendMessage(_ message: String,
                              html: String?,
                              inReplyToEventID: String?,
                              intentionalMentions: IntentionalMentions) async {
        await recorder.record(inReplyToEventID == nil ? "send" : "reply")
        await super.sendMessage(message,
                                html: html,
                                inReplyToEventID: inReplyToEventID,
                                intentionalMentions: intentionalMentions)
    }
}

private struct RoomTimelineItemFactoryStub: RoomTimelineItemFactoryProtocol {
    func buildTimelineItem(for eventItemProxy: EventTimelineItemProxy, isDM: Bool) -> RoomTimelineItemProtocol? {
        nil
    }

    func buildTimelineItemReply(_ details: InReplyToDetails) -> TimelineItemReply {
        fatalError("Not used by read receipt tests.")
    }
}

private extension TextRoomTimelineItem {
    init(text: String, sender: String, addReactions: Bool = false, addReadReceipts: [ReadReceipt] = []) {
        let reactions = addReactions ? [AggregatedReaction(accountOwnerID: "bob", key: "🦄", senders: [ReactionSender(id: sender, timestamp: Date())])] : []
        self.init(id: .randomEvent,
                  timestamp: .mock,
                  isOutgoing: sender == "bob",
                  isEditable: sender == "bob",
                  canBeRepliedTo: true,
                  sender: .init(id: "@\(sender):server.com", displayName: sender),
                  content: .init(body: text),
                  properties: RoomTimelineItemProperties(reactions: reactions, orderedReadReceipts: addReadReceipts))
    }
}

private extension SeparatorRoomTimelineItem {
    init(uniqueID: TimelineItemIdentifier.UniqueID) {
        self.init(id: .virtual(uniqueID: uniqueID), timestamp: .mock)
    }
}

private extension TextRoomTimelineItem {
    init(eventID: String, text: String = "Hello, World!", sender: String = "", isPrivacyControlled: Bool = false) {
        self.init(id: .event(uniqueID: .init(UUID().uuidString), eventOrTransactionID: .eventID(eventID)),
                  timestamp: .mock,
                  isOutgoing: sender == "bob",
                  isEditable: sender == "bob",
                  canBeRepliedTo: true,
                  sender: .init(id: sender.isEmpty ? "" : "@\(sender):server.com", displayName: sender),
                  content: .init(body: text),
                  properties: .init(isPrivacyControlled: isPrivacyControlled))
    }
}

private extension TextRoomTimelineItem {
    init(eventID: String, keyForwarder: TimelineItemKeyForwarder) {
        self.init(id: .event(uniqueID: .init(UUID().uuidString), eventOrTransactionID: .eventID(eventID)),
                  timestamp: .mock,
                  isOutgoing: false,
                  isEditable: false,
                  canBeRepliedTo: true,
                  sender: .init(id: ""),
                  content: .init(body: "Hello, World!"),
                  properties: RoomTimelineItemProperties(encryptionForwarder: keyForwarder))
    }
}

private extension TextRoomTimelineItem {
    init(eventID: String, encryptionAuthenticity: EncryptionAuthenticity) {
        self.init(id: .event(uniqueID: .init(UUID().uuidString), eventOrTransactionID: .eventID(eventID)),
                  timestamp: .mock,
                  isOutgoing: false,
                  isEditable: false,
                  canBeRepliedTo: true,
                  sender: .init(id: ""),
                  content: .init(body: "Hello, World!"),
                  properties: RoomTimelineItemProperties(encryptionAuthenticity: encryptionAuthenticity))
    }
}

private extension TimelineItemSender {
    init(with proxy: RoomMemberProxyMock) {
        self.init(id: proxy.userID,
                  displayName: proxy.displayName ?? "",
                  isDisplayNameAmbiguous: false,
                  avatarURL: proxy.avatarURL)
    }
}

private extension TimelineItemKeyForwarder {
    static var test: TimelineItemKeyForwarder {
        TimelineItemKeyForwarder(id: "@alice:matrix.org", displayName: "alice")
    }
}
