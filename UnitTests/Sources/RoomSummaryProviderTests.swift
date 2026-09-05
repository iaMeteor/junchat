//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@MainActor
final class RoomSummaryProviderTests {
    private let baseFilters: [RoomListEntriesDynamicFilterKind] = [.any(filters: [.all(filters: [.nonSpace, .nonLeft]),
                                                                                  .all(filters: [.space, .invite])]),
                                                                   .deduplicateVersions]

    var appSettings: AppSettings!
    var roomList: RoomListSDKMock!
    var dynamicEntriesController: RoomListDynamicEntriesControllerSDKMock!
    var roomSummaryProvider: RoomSummaryProvider!

    deinit {
        AppSettings.resetAllSettings()
    }

    @Test
    func defaultRustFilters() async {
        // Given a new room provider.
        setup()
        await Task.yield()

        // Then it should have the default Rust filters enabled.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 1)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: baseFilters))

        // When setting one our user filters.
        roomSummaryProvider.setFilter(.all(filters: [.favourites]))
        await Task.yield()

        // Then that filter should be added to the default Rust filters.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 2)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: [.all(filters: [.favourite, .joined])] + baseFilters))
    }

    @Test
    func lowPriorityRustFilters() async {
        // Given a new room provider with the low priority filter enabled.
        setup(isLowPriorityFilterEnabled: true)
        await Task.yield()

        // Then the default Rust filters should include the non-low priority filter,
        // so that low priority rooms are hidden from the top of the room list.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 1)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: baseFilters + [.nonLowPriority]))

        // When setting the low priority filter.
        roomSummaryProvider.setFilter(.all(filters: [.lowPriority]))
        await Task.yield()

        // Then the non-low priority filter should be replaced with the low priority filter.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 2)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: [.all(filters: [.lowPriority, .joined])] + baseFilters))

        // When setting another one of our filters.
        roomSummaryProvider.setFilter(.all(filters: [.rooms]))
        await Task.yield()

        // Then the filter should be combined with the non-low priority filter.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 3)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: [.all(filters: [.category(expect: .group), .joined])] + baseFilters + [.nonLowPriority]))
    }

    @Test
    func roomIdentifierFilters() async {
        setup()
        await Task.yield()

        // Then it should have the default Rust filters enabled.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 1)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: baseFilters))

        // When setting one our user filters.
        roomSummaryProvider.setFilter(.rooms(roomsIDs: ["SomeRoom"], filters: [.favourites]))
        await Task.yield()

        // Then that filter should be added to the default Rust filters.
        #expect(dynamicEntriesController.setFilterKindCallsCount == 2)
        #expect(dynamicEntriesController.setFilterKindReceivedInvocations.last == .all(filters: [.all(filters: [.favourite, .joined])] + baseFilters + [.identifiers(identifiers: ["SomeRoom"])]))
    }
    
    // MARK: - Helpers

    @Test
    func unavailableRoomDetailsDoNotCrashOrLoseTheSDKListSlot() async throws {
        setup()
        let room = RoomSDKMock()
        room.idReturnValue = "!unavailable:example.org"
        room.latestEventReturnValue = .some(.none)
        room.roomInfoClosure = { throw SummaryTestError.unavailable }
        let listener = try #require(roomList.entriesWithDynamicAdaptersPageSizeListenerReceivedArguments?.listener)
        let updated = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.map(\.id) == ["!unavailable:example.org"] }
        listener.onUpdate(roomEntriesUpdate: [.append(values: [room])])
        try await updated.fulfill()
        #expect(roomSummaryProvider.roomListPublisher.value.first?.lastMessage == nil)
        #expect(roomSummaryProvider.roomListPublisher.value.first?.hasLoadedDetails == false)
        let cleared = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.isEmpty }
        listener.onUpdate(roomEntriesUpdate: [.remove(index: 0)])
        try await cleared.fulfill()
    }

    @Test
    func timedOutRefreshKeepsIndicesAndCanRecoverWithoutALateOverwrite() async throws {
        setup(roomDetailsTimeout: .milliseconds(20))
        let slow = room(id: "!slow:example.org")
        slow.latestEventClosure = {
            try? await Task.sleep(for: .milliseconds(150))
            return .none
        }
        let second = room(id: "!second:example.org")
        let listener = try #require(roomList.entriesWithDynamicAdaptersPageSizeListenerReceivedArguments?.listener)
        let both = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.count == 2 }
        listener.onUpdate(roomEntriesUpdate: [.append(values: [slow])])
        listener.onUpdate(roomEntriesUpdate: [.pushBack(value: second)])
        try await both.fulfill()
        #expect(roomSummaryProvider.roomListPublisher.value.map(\.id) == [slow.id(), second.id()])
        #expect(roomSummaryProvider.roomListPublisher.value.map(\.hasLoadedDetails) == [false, true])
        let replaced = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.count == 1 && $0.first?.id == second.id() }
        listener.onUpdate(roomEntriesUpdate: [.remove(index: 0)])
        try await replaced.fulfill()
        try await Task.sleep(for: .milliseconds(200))
        #expect(roomSummaryProvider.roomListPublisher.value.map(\.id) == [second.id()])
        let refreshed = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.first?.name == "Recovered" }
        var info = try #require(second.roomInfoReturnValue)
        info.displayName = "Recovered"
        second.roomInfoReturnValue = info
        roomSummaryProvider.refreshRoomSummaries()
        try await refreshed.fulfill()
    }

    @Test
    func unavailableSummaryRetainsUnreadMetadataButDropsPreview() {
        let room = room(id: "!room:example.org")
        let previous = RoomSummary(room: room, id: room.id(), settingsMode: .allMessages,
                                   hasUnreadMessages: true, hasUnreadMentions: true, hasUnreadNotifications: true)
        let summary = RoomSummary.unavailable(room: room, previous: previous)
        #expect(summary.name == previous.name)
        #expect(summary.hasUnreadNotifications)
        #expect(summary.lastMessage == nil)
        #expect(!summary.hasLoadedDetails)
    }

    @Test
    func invalidIndicesDoNotCrashAndFollowingResetRecovers() async throws {
        setup()
        let listener = try #require(roomList.entriesWithDynamicAdaptersPageSizeListenerReceivedArguments?.listener)
        let room = room(id: "!room:example.org")
        let recovered = deferFulfillment(roomSummaryProvider.roomListPublisher) { $0.map(\.id) == [room.id()] }
        listener.onUpdate(roomEntriesUpdate: [.popFront, .popBack, .remove(index: 3), .set(index: 4, value: room),
                                              .insert(index: 8, value: room), .reset(values: [room])])
        try await recovered.fulfill()
    }

    private func room(id: String) -> RoomSDKMock {
        let room = RoomSDKMock()
        room.idReturnValue = id
        room.latestEventReturnValue = .some(.none)
        room.roomInfoReturnValue = RoomInfo(id: id, encryptionState: .encrypted, creators: nil,
                                            displayName: "Room", rawName: nil, topic: nil, avatarUrl: nil,
                                            isDirect: true, isPublic: nil, isSpace: false, successorRoom: nil,
                                            isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [],
                                            membership: .joined, inviter: nil, heroes: [], activeMembersCount: 2,
                                            invitedMembersCount: 0, joinedMembersCount: 2, activeServiceMembersCount: 0,
                                            serviceMembers: [], highlightCount: 0, notificationCount: 0,
                                            cachedUserDefinedNotificationMode: nil, hasRoomCall: false,
                                            activeRoomCallParticipants: [], activeRoomCallConsensusIntent: .none,
                                            isMarkedUnread: false, numUnreadMessages: 0, numUnreadNotifications: 0,
                                            numUnreadMentions: 0, pinnedEventIds: [], joinRule: nil,
                                            historyVisibility: .shared, powerLevels: nil, roomVersion: nil, privilegedCreatorsRole: false)
        return room
    }
    
    private func setup(isLowPriorityFilterEnabled: Bool = false, roomDetailsTimeout: Duration = .seconds(10)) {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        appSettings.lowPriorityFilterEnabled = isLowPriorityFilterEnabled

        let stateEventStringBuilder = RoomStateEventStringBuilder(userID: "@me:matrix.org")
        let attributedStringBuilder = AttributedStringBuilder(mentionBuilder: MentionBuilder())
        let eventStringBuilder = RoomEventStringBuilder(stateEventStringBuilder: stateEventStringBuilder,
                                                        messageEventStringBuilder: RoomMessageEventStringBuilder(attributedStringBuilder: attributedStringBuilder,
                                                                                                                 style: .senderPrefixed),
                                                        shouldPrefixSenderName: true)

        roomSummaryProvider = RoomSummaryProvider(roomListService: RoomListServiceSDKMock(),
                                                  eventStringBuilder: eventStringBuilder,
                                                  name: "Test",
                                                  notificationSettings: NotificationSettingsProxyMock(with: .init()),
                                                  appSettings: appSettings,
                                                  roomDetailsTimeout: roomDetailsTimeout)

        dynamicEntriesController = RoomListDynamicEntriesControllerSDKMock()
        dynamicEntriesController.setFilterKindReturnValue = true
        let dynamicAdaptersResult = RoomListEntriesWithDynamicAdaptersResultSDKMock()
        dynamicAdaptersResult.controllerReturnValue = dynamicEntriesController
        roomList = RoomListSDKMock()
        roomList.entriesWithDynamicAdaptersPageSizeListenerReturnValue = dynamicAdaptersResult
        roomList.loadingStateListenerReturnValue = .some(.init(state: .notLoaded, stateStream: .init(noHandle: .init())))
        roomSummaryProvider.setRoomList(roomList)
    }
}

private enum SummaryTestError: Error {
    case unavailable
}
