//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct JunchatPasswordChangeRequest: Encodable {
    let newPassword: String
    let logoutDevices: Bool
    let auth: JunchatPasswordChangeAuth
    
    enum CodingKeys: String, CodingKey {
        case newPassword = "new_password"
        case logoutDevices = "logout_devices"
        case auth
    }
}

struct JunchatPasswordChangeAuth: Encodable {
    let type = "m.login.password"
    let identifier: JunchatPasswordChangeIdentifier
    let password: String
    var session: String?
    
    init(userID: String, password: String, session: String? = nil) {
        identifier = JunchatPasswordChangeIdentifier(user: userID)
        self.password = password
        self.session = session
    }
}

struct JunchatPasswordChangeIdentifier: Encodable {
    let type = "m.id.user"
    let user: String
}

struct JunchatPasswordChangeUIAResponse: Decodable {
    let session: String?
}

struct JunchatPasswordChangeResponse {
    let statusCode: Int
    let uiaSession: String?
}
