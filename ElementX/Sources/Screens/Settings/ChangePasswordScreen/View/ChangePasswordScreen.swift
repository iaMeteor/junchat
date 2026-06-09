//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChangePasswordScreen: View {
    @Bindable var context: ChangePasswordScreenViewModel.Context
    
    var body: some View {
        Form {
            Section {
                ListRow(label: .plain(title: "原密码"),
                        kind: .secureField(text: $context.oldPassword))
                ListRow(label: .plain(title: "新密码"),
                        kind: .secureField(text: $context.newPassword))
                ListRow(label: .plain(title: "确认新密码"),
                        kind: .secureField(text: $context.confirmNewPassword))
            } footer: {
                Text(context.viewState.validationMessage ?? "修改后当前设备会继续保持登录，其他设备不会被退出。")
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .safeAreaInset(edge: .bottom) {
            Button("保存新密码") {
                context.send(viewAction: .submit)
            }
            .buttonStyle(.compound(.primary))
            .disabled(!context.viewState.canSubmit)
            .padding(16)
            .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        }
        .navigationTitle("修改登录密码")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
    }
}

struct ChangePasswordScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ChangePasswordScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                         userIndicatorController: UserIndicatorControllerMock())
    static var previews: some View {
        ElementNavigationStack {
            ChangePasswordScreen(context: viewModel.context)
        }
    }
}
