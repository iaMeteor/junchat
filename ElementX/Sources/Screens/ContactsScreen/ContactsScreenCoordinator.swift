//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ContactsScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ContactsScreenCoordinatorAction {
    case showRoom(roomID: String)
}

final class ContactsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ContactsScreenViewModelProtocol
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<ContactsScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ContactsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: ContactsScreenCoordinatorParameters) {
        let contactsService = ContactsService(clientProxy: parameters.userSession.clientProxy)
        viewModel = ContactsScreenViewModel(userSession: parameters.userSession,
                                            contactsService: contactsService,
                                            userIndicatorController: parameters.userIndicatorController)
    }
    
    func start() {
        viewModel.actions
            .sink { [weak self] action in
                switch action {
                case .showRoom(let roomID):
                    self?.actionsSubject.send(.showRoom(roomID: roomID))
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(ContactsScreen(context: viewModel.context))
    }
}
