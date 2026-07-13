//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum ElementCallServiceAction {
    case receivedIncomingCallRequest
    case startCall(roomID: String, isVoiceCall: Bool)
    case endCall(roomID: String)
    case setAudioEnabled(_ enabled: Bool, roomID: String)
}

struct ElementCallSessionGeneration: Equatable {
    private let identifier = UUID()
}

// sourcery: AutoMockable
@MainActor
protocol ElementCallServiceProtocol {
    var actions: AnyPublisher<ElementCallServiceAction, Never> { get }

    var ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> { get }

    var incomingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> { get }

    func setClientProxy(_ clientProxy: ClientProxyProtocol)

    func registerCallSession(generation: ElementCallSessionGeneration)

    func setupCallSession(roomID: String, roomDisplayName: String, generation: ElementCallSessionGeneration) async

    func acceptIncomingCall(roomID: String, isVoiceCall: Bool) async

    func declineIncomingCall(roomID: String) async

    func tearDownCallSession()

    func tearDownCallSession(generation: ElementCallSessionGeneration)

    func setAudioEnabled(_ enabled: Bool, roomID: String)
}
