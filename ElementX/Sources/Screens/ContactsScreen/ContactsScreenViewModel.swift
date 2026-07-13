//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ContactsScreenViewModelType = StateStoreViewModel<ContactsScreenViewState, ContactsScreenViewAction>

class ContactsScreenViewModel: ContactsScreenViewModelType, ContactsScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let contactsService: ContactsServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private var contactsLoadTask: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<ContactsScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<ContactsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol,
         contactsService: ContactsServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.userSession = userSession
        self.contactsService = contactsService
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: ContactsScreenViewState(), mediaProvider: userSession.mediaProvider)
    }

    deinit {
        contactsLoadTask?.cancel()
    }
    
    override func process(viewAction: ContactsScreenViewAction) {
        switch viewAction {
        case .task, .refresh:
            guard !state.isLoading else { return }
            loadContacts()
        case .selectContact(let contact):
            openDirectRoom(for: contact)
        }
    }
    
    private func loadContacts() {
        guard contactsLoadTask == nil else { return }

        state.isLoading = true
        state.hasLoadError = false
        let contactsService = contactsService
        contactsLoadTask = Task { [weak self] in
            let result = await contactsService.contacts()
            guard let self, !Task.isCancelled else { return }

            switch result {
            case .success(let contacts):
                state.contacts = contacts
            case .failure:
                state.hasLoadError = true
            }
            state.isLoading = false
            contactsLoadTask = nil
        }
    }
    
    private func openDirectRoom(for contact: UserProfileProxy) {
        state.processingUserID = contact.userID
        showLoadingIndicator()
        
        switch userSession.clientProxy.directRoomForUserID(contact.userID) {
        case .success(.some(let roomID)):
            hideLoadingIndicator()
            state.processingUserID = nil
            actionsSubject.send(.showRoom(roomID: roomID))
        case .success:
            Task { await createDirectRoom(for: contact) }
        case .failure:
            hideLoadingIndicator()
            state.processingUserID = nil
            displayStartingChatError()
        }
    }
    
    private func createDirectRoom(for contact: UserProfileProxy) async {
        defer {
            hideLoadingIndicator()
            state.processingUserID = nil
        }
        
        switch await userSession.clientProxy.createDirectRoom(with: contact.userID, expectedRoomName: contact.displayName) {
        case .success(let roomID):
            actionsSubject.send(.showRoom(roomID: roomID))
        case .failure:
            displayStartingChatError()
        }
    }
    
    private func displayStartingChatError() {
        state.bindings.alertInfo = .init(id: .failedStartingChat,
                                         title: L10n.commonError,
                                         message: L10n.screenStartChatErrorStartingChat)
    }
    
    private static let loadingIndicatorIdentifier = "\(ContactsScreenViewModel.self)-Loading"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: false, allowsInteraction: true),
                                                              title: L10n.commonLoading,
                                                              persistent: true),
                                                delay: .milliseconds(200))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
}
