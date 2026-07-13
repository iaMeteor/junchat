//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct ContactsScreenViewModelTests {
    private var clientProxy: ClientProxyMock
    private var contactsService: ContactsServiceFake
    private var viewModel: ContactsScreenViewModel

    private var context: ContactsScreenViewModel.Context {
        viewModel.context
    }

    init() {
        clientProxy = .init(.init(userID: "@me:junchat.yyzs120.cn"))
        contactsService = ContactsServiceFake(result: .success([
            .init(userID: "@alice:junchat.yyzs120.cn", displayName: "Alice"),
            .init(userID: "@bob:junchat.yyzs120.cn", displayName: "Bob")
        ]))

        viewModel = ContactsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                            contactsService: contactsService,
                                            userIndicatorController: UserIndicatorControllerMock())
    }

    @Test
    func loadingContactsShowsDisplayNames() async throws {
        let deferred = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.contacts.map(\.displayName) == ["Alice", "Bob"]
        }

        context.send(viewAction: .task)
        try await deferred.fulfill()

        #expect(contactsService.contactsCallsCount == 1)
    }

    @Test
    mutating func taskRefreshesPreviouslyLoadedContacts() async throws {
        let firstLoad = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.contacts.map(\.userID) == [
                "@alice:junchat.yyzs120.cn",
                "@bob:junchat.yyzs120.cn"
            ]
        }

        context.send(viewAction: .task)
        try await firstLoad.fulfill()

        contactsService.result = .success([
            .init(userID: "@alice:junchat.yyzs120.cn", displayName: "Alice"),
            .init(userID: "@bob:junchat.yyzs120.cn", displayName: "Bob"),
            .init(userID: "@charlie:junchat.yyzs120.cn", displayName: "Charlie")
        ])
        let secondLoad = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.contacts.map(\.userID).contains("@charlie:junchat.yyzs120.cn")
        }

        context.send(viewAction: .task)
        try await secondLoad.fulfill()

        #expect(contactsService.contactsCallsCount == 2)
    }

    @Test
    mutating func initialLoadingFailureShowsInlineError() async throws {
        contactsService.result = .failure(.failedFetchingContacts)

        let deferred = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.hasLoadError
        }

        context.send(viewAction: .task)
        try await deferred.fulfill()

        #expect(context.viewState.contacts.isEmpty)
        #expect(context.viewState.bindings.alertInfo == nil)
    }

    @Test
    mutating func refreshFailureKeepsExistingContactsVisibleAndCanRetry() async throws {
        let initialLoad = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.contacts.count == 2
        }
        context.send(viewAction: .task)
        try await initialLoad.fulfill()

        contactsService.suspendsRequests = true
        context.send(viewAction: .refresh)
        try await waitForContactsCalls(2)
        #expect(context.viewState.isLoading)
        #expect(context.viewState.contacts.map(\.userID) == [
            "@alice:junchat.yyzs120.cn",
            "@bob:junchat.yyzs120.cn"
        ])

        let failedRefresh = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && viewState.hasLoadError
        }
        contactsService.completeSuspendedRequest(with: .failure(.failedFetchingContacts))
        try await failedRefresh.fulfill()
        #expect(context.viewState.contacts.count == 2)

        contactsService.suspendsRequests = false
        contactsService.result = .success([
            .init(userID: "@charlie:junchat.yyzs120.cn", displayName: "Charlie")
        ])
        let successfulRetry = deferFulfillment(context.$viewState) { viewState in
            !viewState.isLoading && !viewState.hasLoadError && viewState.contacts.map(\.userID) == ["@charlie:junchat.yyzs120.cn"]
        }
        context.send(viewAction: .refresh)
        try await successfulRetry.fulfill()
    }

    @Test
    func concurrentLifecycleAndManualRefreshesAreCoalesced() async throws {
        contactsService.suspendsRequests = true

        context.send(viewAction: .task)
        context.send(viewAction: .refresh)
        context.send(viewAction: .task)
        try await waitForContactsCalls(1)

        #expect(contactsService.contactsCallsCount == 1)
        let finished = deferFulfillment(context.$viewState) { !$0.isLoading }
        contactsService.completeSuspendedRequest(with: .success([]))
        try await finished.fulfill()
    }

    private func waitForContactsCalls(_ expectedCount: Int) async throws {
        for _ in 0..<100 where contactsService.contactsCallsCount < expectedCount {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(contactsService.contactsCallsCount == expectedCount)
    }

    @Test
    func selectingContactWithExistingDirectRoomShowsRoom() async throws {
        let contact = UserProfileProxy(userID: "@alice:junchat.yyzs120.cn", displayName: "Alice")
        clientProxy.directRoomForUserIDReturnValue = .success("!existing:junchat.yyzs120.cn")

        let deferred = deferFulfillment(viewModel.actions) { action in
            action == .showRoom(roomID: "!existing:junchat.yyzs120.cn")
        }

        context.send(viewAction: .selectContact(contact))
        try await deferred.fulfill()

        #expect(clientProxy.directRoomForUserIDReceivedUserID == contact.userID)
    }

    @Test
    func selectingContactWithoutDirectRoomCreatesRoom() async throws {
        let contact = UserProfileProxy(userID: "@bob:junchat.yyzs120.cn", displayName: "Bob")
        clientProxy.directRoomForUserIDReturnValue = .success(nil)
        clientProxy.createDirectRoomWithExpectedRoomNameReturnValue = .success("!new:junchat.yyzs120.cn")

        let deferred = deferFulfillment(viewModel.actions) { action in
            action == .showRoom(roomID: "!new:junchat.yyzs120.cn")
        }

        context.send(viewAction: .selectContact(contact))
        try await deferred.fulfill()

        #expect(clientProxy.createDirectRoomWithExpectedRoomNameReceivedArguments?.userID == contact.userID)
        #expect(clientProxy.createDirectRoomWithExpectedRoomNameReceivedArguments?.expectedRoomName == contact.displayName)
    }
}

struct ContactsScreenAccessibilityTests {
    @Test
    func announcesEachLoadErrorTransitionExactlyOnce() {
        var announcements = [String]()
        var previousValue = false

        for currentValue in [false, true, true, false, true] {
            ContactsScreenAccessibility.announceLoadErrorIfNeeded(wasLoadError: previousValue,
                                                                  hasLoadError: currentValue) { announcement in
                announcements.append(announcement)
            }
            previousValue = currentValue
        }

        #expect(announcements == [
            ContactsScreenAccessibility.loadErrorAnnouncement,
            ContactsScreenAccessibility.loadErrorAnnouncement
        ])
    }
}

private final class ContactsServiceFake: ContactsServiceProtocol {
    var result: Result<[UserProfileProxy], ContactsServiceError>
    var contactsCallsCount = 0
    var suspendsRequests = false
    private var suspendedContinuation: CheckedContinuation<Result<[UserProfileProxy], ContactsServiceError>, Never>?

    init(result: Result<[UserProfileProxy], ContactsServiceError>) {
        self.result = result
    }

    func contacts() async -> Result<[UserProfileProxy], ContactsServiceError> {
        contactsCallsCount += 1
        if suspendsRequests {
            return await withCheckedContinuation { suspendedContinuation = $0 }
        }
        return result
    }

    func completeSuspendedRequest(with result: Result<[UserProfileProxy], ContactsServiceError>) {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(returning: result)
    }
}
