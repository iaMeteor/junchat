//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

typealias ChangePasswordScreenViewModelType = StateStoreViewModelV2<ChangePasswordScreenViewState, ChangePasswordScreenViewAction>

class ChangePasswordScreenViewModel: ChangePasswordScreenViewModelType, ChangePasswordScreenViewModelProtocol {
    private static let changingPasswordIndicatorID = "\(ChangePasswordScreenViewModel.self)-ChangingPassword"
    
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let actionsSubject: PassthroughSubject<ChangePasswordScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePasswordScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(clientProxy: ClientProxyProtocol, userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: ChangePasswordScreenViewState())
    }
    
    override func process(viewAction: ChangePasswordScreenViewAction) {
        switch viewAction {
        case .submit:
            guard state.canSubmit else {
                return
            }
            
            Task { await changePassword() }
        }
    }
    
    private func changePassword() async {
        state.isSubmitting = true
        userIndicatorController.submitIndicator(UserIndicator(id: Self.changingPasswordIndicatorID,
                                                              type: .modal(progress: .indeterminate,
                                                                           interactiveDismissDisabled: true,
                                                                           allowsInteraction: false),
                                                              title: "正在修改密码",
                                                              persistent: true))
        
        defer {
            state.isSubmitting = false
            userIndicatorController.retractIndicatorWithId(Self.changingPasswordIndicatorID)
        }
        
        switch await clientProxy.changePassword(oldPassword: state.bindings.oldPassword,
                                                newPassword: state.bindings.newPassword,
                                                logoutDevices: false) {
        case .success:
            state.bindings.oldPassword = ""
            state.bindings.newPassword = ""
            state.bindings.confirmNewPassword = ""
            userIndicatorController.submitIndicator(UserIndicator(title: "密码已修改", iconName: "checkmark"))
            actionsSubject.send(.passwordChanged)
        case .failure:
            state.bindings.alertInfo = AlertInfo(id: .failed,
                                                 title: "修改失败",
                                                 message: "请确认原密码正确，并检查网络后再试一次。")
        }
    }
}
