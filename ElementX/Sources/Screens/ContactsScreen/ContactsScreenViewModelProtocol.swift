//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol ContactsScreenViewModelProtocol {
    var actions: AnyPublisher<ContactsScreenViewModelAction, Never> { get }
    var context: ContactsScreenViewModelType.Context { get }
}
