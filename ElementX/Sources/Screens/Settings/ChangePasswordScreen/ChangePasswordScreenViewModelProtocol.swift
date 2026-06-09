//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol ChangePasswordScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<ChangePasswordScreenViewModelAction, Never> { get }
    var context: ChangePasswordScreenViewModelType.Context { get }
}
