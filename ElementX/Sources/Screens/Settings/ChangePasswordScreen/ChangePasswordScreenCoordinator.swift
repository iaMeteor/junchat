//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ChangePasswordScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ChangePasswordScreenCoordinatorAction {
    case passwordChanged
}

final class ChangePasswordScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ChangePasswordScreenViewModelProtocol
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<ChangePasswordScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePasswordScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: ChangePasswordScreenCoordinatorParameters) {
        viewModel = ChangePasswordScreenViewModel(clientProxy: parameters.clientProxy,
                                                 userIndicatorController: parameters.userIndicatorController)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .passwordChanged:
                    self?.actionsSubject.send(.passwordChanged)
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(ChangePasswordScreen(context: viewModel.context))
    }
}
