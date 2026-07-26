//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct RoomCallControlsToolbar: ToolbarContent {
    /// A call the user can start from the room toolbar.
    enum StartCallOption: Hashable {
        case voice
        case video

        var isVoiceCall: Bool {
            self == .voice
        }

        var title: String {
            switch self {
            case .voice: L10n.a11yStartVoiceCall
            case .video: L10n.a11yStartVideoCall
            }
        }

        var icon: KeyPath<CompoundIcons, Image> {
            switch self {
            case .voice: \.voiceCallSolid
            case .video: \.videoCallSolid
            }
        }
    }

    /// Both a voice and a video call can be started in every room. A voice call outside of a
    /// 1:1 DM maps to the group call intent and skips the lobby, so group voice calls are
    /// startable rather than only joinable.
    static let startCallOptions: [StartCallOption] = [.voice, .video]

    let viewState: RoomScreenViewState
    var isDisabled = false
    let onCallTap: (_ isVoiceCall: Bool) -> Void
    
    var body: some ToolbarContent {
        if viewState.hasOngoingCall {
            ToolbarItem(placement: .primaryAction) {
                JoinCallButton(isVoiceCall: viewState.activeRoomCallIntent == .audio) {
                    onCallTap(viewState.activeRoomCallIntent == .audio)
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.joinCall)
                .disabled(!viewState.canJoinCall || isDisabled)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(Self.startCallOptions, id: \.self) { option in
                        Button {
                            onCallTap(option.isVoiceCall)
                        } label: {
                            Label(option.title, icon: option.icon)
                        }
                    }
                } label: {
                    CompoundIcon(\.voiceCallSolid)
                }
                .accessibilityLabel(L10n.a11yStartCall)
                .disabled(!viewState.canJoinCall || isDisabled)
            }
        }
    }
}

// MARK: - Previews

struct RoomCallControlsToolbar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            ElementNavigationStack {
                Color.clear.toolbar { RoomCallControlsToolbar(viewState: .mock(hasOngoingCall: true)) { _ in } }
            }
            ElementNavigationStack {
                Color.clear.toolbar { RoomCallControlsToolbar(viewState: .mock(hasOngoingCall: false, isDirectOneToOneRoom: true)) { _ in } }
            }
            ElementNavigationStack {
                Color.clear.toolbar { RoomCallControlsToolbar(viewState: .mock(hasOngoingCall: false)) { _ in } }
            }
            ElementNavigationStack {
                Color.clear.toolbar { RoomCallControlsToolbar(viewState: .mock(hasOngoingCall: false, canJoinCall: false)) { _ in } }
            }
            ElementNavigationStack {
                Color.clear.toolbar { RoomCallControlsToolbar(viewState: .mock(hasOngoingCall: true, activeRoomCallIntent: .audio)) { _ in } }
            }
        }
        .previewDisplayName("All states")
    }
}

private extension RoomScreenViewState {
    static func mock(hasOngoingCall: Bool, isDirectOneToOneRoom: Bool = false, canJoinCall: Bool = true, activeRoomCallIntent: CallIntent? = nil) -> RoomScreenViewState {
        RoomScreenViewState(roomAvatar: .room(id: "mock", name: "Mock Room", avatarURL: nil),
                            canJoinCall: canJoinCall,
                            hasOngoingCall: hasOngoingCall,
                            activeRoomCallIntent: activeRoomCallIntent,
                            isDirectOneToOneRoom: isDirectOneToOneRoom,
                            hasSuccessor: false)
    }
}
