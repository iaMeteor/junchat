//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ContactsScreenViewModelAction: Equatable {
    case showRoom(roomID: String)
}

struct ContactsScreenViewState: BindableState {
    var contacts: [UserProfileProxy] = []
    var isLoading = false
    var processingUserID: String?
    var bindings = ContactsScreenViewStateBindings()
    
    var isEmpty: Bool {
        !isLoading && contacts.isEmpty
    }
}

struct ContactsScreenViewStateBindings {
    var alertInfo: AlertInfo<ContactsScreenAlertType>?
}

enum ContactsScreenViewAction {
    case task
    case refresh
    case selectContact(UserProfileProxy)
}

enum ContactsScreenAlertType: Hashable {
    case failedLoadingContacts
    case failedStartingChat
}
