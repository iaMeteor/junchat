//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ChangePasswordScreenViewModelAction {
    case passwordChanged
}

struct ChangePasswordScreenViewState: BindableState {
    var isSubmitting = false
    var bindings = ChangePasswordScreenViewStateBindings()
    
    var validationMessage: String? {
        if bindings.oldPassword.isEmpty || bindings.newPassword.isEmpty || bindings.confirmNewPassword.isEmpty {
            return nil
        }
        
        if bindings.newPassword.count < 8 {
            return "新密码至少需要 8 位。"
        }
        
        if bindings.newPassword != bindings.confirmNewPassword {
            return "两次输入的新密码不一致。"
        }
        
        return nil
    }
    
    var canSubmit: Bool {
        !isSubmitting &&
            !bindings.oldPassword.isEmpty &&
            bindings.newPassword.count >= 8 &&
            bindings.newPassword == bindings.confirmNewPassword
    }
}

struct ChangePasswordScreenViewStateBindings {
    var oldPassword = ""
    var newPassword = ""
    var confirmNewPassword = ""
    var alertInfo: AlertInfo<ChangePasswordScreenAlert>?
}

enum ChangePasswordScreenAlert {
    case failed
}

enum ChangePasswordScreenViewAction {
    case submit
}
