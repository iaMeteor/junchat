//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct IncomingCallScreenCoordinatorParameters {
    let candidate: GlobalIncomingCallCandidate
    let mediaProvider: MediaProviderProtocol?
}

enum IncomingCallScreenCoordinatorAction {
    case accept(GlobalIncomingCallCandidate)
    case decline(GlobalIncomingCallCandidate)
}

final class IncomingCallScreenCoordinator: CoordinatorProtocol {
    private let parameters: IncomingCallScreenCoordinatorParameters
    private let actionsSubject: PassthroughSubject<IncomingCallScreenCoordinatorAction, Never> = .init()
    
    var actions: AnyPublisher<IncomingCallScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: IncomingCallScreenCoordinatorParameters) {
        self.parameters = parameters
    }
    
    func toPresentable() -> AnyView {
        AnyView(IncomingCallOverlayView(roomTitle: parameters.candidate.roomTitle,
                                        roomAvatar: parameters.candidate.roomAvatar,
                                        isVoiceCall: parameters.candidate.isVoiceCall,
                                        mediaProvider: parameters.mediaProvider) { [actionsSubject, candidate = parameters.candidate] in
                actionsSubject.send(.decline(candidate))
            } onAccept: { [actionsSubject, candidate = parameters.candidate] in
                actionsSubject.send(.accept(candidate))
            })
    }
}
