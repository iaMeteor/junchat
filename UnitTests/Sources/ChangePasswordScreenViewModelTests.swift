//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct ChangePasswordScreenViewModelTests {
    private var viewModel: ChangePasswordScreenViewModelProtocol
    private var context: ChangePasswordScreenViewModelType.Context
    private var clientProxy: ClientProxyMock
    
    init() {
        clientProxy = ClientProxyMock(.init(userID: "@alice:junchat.yyzs120.cn"))
        viewModel = ChangePasswordScreenViewModel(clientProxy: clientProxy,
                                                  userIndicatorController: UserIndicatorControllerMock())
        context = viewModel.context
    }
    
    @Test
    func submitIsDisabledUntilNewPasswordsMatch() {
        context.oldPassword = "old-password"
        context.newPassword = "new-password"
        context.confirmNewPassword = "different-password"
        
        #expect(!context.viewState.canSubmit)
        #expect(context.viewState.validationMessage == "两次输入的新密码不一致。")
    }
    
    @Test
    func submitChangesPasswordWithoutLoggingOutOtherDevices() async throws {
        context.oldPassword = "old-password"
        context.newPassword = "new-password"
        context.confirmNewPassword = "new-password"
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .passwordChanged }
        context.send(viewAction: .submit)
        try await deferred.fulfill()
        
        #expect(clientProxy.changePasswordOldPasswordNewPasswordLogoutDevicesReceivedArguments?.oldPassword == "old-password")
        #expect(clientProxy.changePasswordOldPasswordNewPasswordLogoutDevicesReceivedArguments?.newPassword == "new-password")
        #expect(clientProxy.changePasswordOldPasswordNewPasswordLogoutDevicesReceivedArguments?.logoutDevices == false)
    }
    
    @Test
    mutating func submitShowsFailureAlert() async throws {
        clientProxy.changePasswordOldPasswordNewPasswordLogoutDevicesReturnValue = .failure(.forbiddenAccess)
        viewModel = ChangePasswordScreenViewModel(clientProxy: clientProxy,
                                                  userIndicatorController: UserIndicatorControllerMock())
        context = viewModel.context
        context.oldPassword = "old-password"
        context.newPassword = "new-password"
        context.confirmNewPassword = "new-password"
        
        let deferred = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0?.id == .failed }
        context.send(viewAction: .submit)
        try await deferred.fulfill()
    }
}
