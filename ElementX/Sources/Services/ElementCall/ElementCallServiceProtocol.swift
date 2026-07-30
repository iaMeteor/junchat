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
    case startCall(roomID: String, isVoiceCall: Bool, incomingCallIdentity: ElementCallIncomingCallIdentity)
    case endCall(roomID: String)
    case setAudioEnabled(_ enabled: Bool, roomID: String)
}

struct ElementCallIncomingCallIdentity: Hashable {
    let callKitID: UUID
    let roomID: String
    let isVoiceCall: Bool
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

    var incomingCallIdentityPublisher: CurrentValuePublisher<ElementCallIncomingCallIdentity?, Never> { get }

    var acceptedIncomingCallIdentity: ElementCallIncomingCallIdentity? { get }

    func setClientProxy(_ clientProxy: ClientProxyProtocol)

    func registerCallSession(generation: ElementCallSessionGeneration)

    func setupCallSession(roomID: String,
                          roomDisplayName: String,
                          isVoiceCall: Bool,
                          incomingCallIdentity: ElementCallIncomingCallIdentity?,
                          generation: ElementCallSessionGeneration) async

    func acceptIncomingCall(roomID: String,
                            isVoiceCall: Bool,
                            incomingCallIdentity: ElementCallIncomingCallIdentity?) async -> ElementCallIncomingCallIdentity?

    func declineIncomingCall(roomID: String) async

    func declineIncomingCall(incomingCallIdentity: ElementCallIncomingCallIdentity) async

    func clearAcceptedIncomingCall(incomingCallIdentity: ElementCallIncomingCallIdentity)

    func tearDownCallSession()

    func tearDownCallSession(generation: ElementCallSessionGeneration)

    func setAudioEnabled(_ enabled: Bool, roomID: String)
}
