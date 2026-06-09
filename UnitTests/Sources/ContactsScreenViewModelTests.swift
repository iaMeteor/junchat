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
    mutating func loadingContactsFailureShowsAlert() async throws {
        contactsService.result = .failure(.failedFetchingContacts)
        
        let deferred = deferFulfillment(context.$viewState) { viewState in
            viewState.bindings.alertInfo?.id == .failedLoadingContacts
        }
        
        context.send(viewAction: .task)
        try await deferred.fulfill()
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

private final class ContactsServiceFake: ContactsServiceProtocol {
    var result: Result<[UserProfileProxy], ContactsServiceError>
    var contactsCallsCount = 0
    
    init(result: Result<[UserProfileProxy], ContactsServiceError>) {
        self.result = result
    }
    
    func contacts() async -> Result<[UserProfileProxy], ContactsServiceError> {
        contactsCallsCount += 1
        return result
    }
}
