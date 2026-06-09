//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct IncomingCallOverlayView: View {
    let roomTitle: String
    let roomAvatar: RoomAvatar
    let isVoiceCall: Bool
    let mediaProvider: MediaProviderProtocol?
    let onDecline: () -> Void
    let onAccept: () -> Void
    
    private var copy: IncomingCallOverlayCopy {
        IncomingCallOverlayCopy.current
    }
    
    var body: some View {
        ZStack {
            Color.compound.bgCanvasDefault
                .opacity(0.98)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer(minLength: 48)
                
                VStack(spacing: 18) {
                    RoomAvatarImage(avatar: roomAvatar, avatarSize: .custom(108), mediaProvider: mediaProvider)
                        .frame(width: 124, height: 124)
                    
                    Text(roomTitle)
                        .font(.compound.headingLGBold)
                        .foregroundStyle(.compound.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 24)
                    
                    Text(isVoiceCall ? copy.voiceCall : copy.videoCall)
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                
                Spacer(minLength: 40)
                
                HStack(spacing: 64) {
                    actionButton(title: copy.decline,
                                 systemImage: "phone.down.fill",
                                 color: Color(red: 0.86, green: 0.18, blue: 0.18),
                                 action: onDecline)
                    
                    actionButton(title: copy.accept,
                                 systemImage: "phone.fill",
                                 color: Color(red: 0.10, green: 0.74, blue: 0.34),
                                 action: onAccept)
                }
                .padding(.bottom, 64)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
    }
    
    private func actionButton(title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Circle()
                    .fill(color)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                
                Text(title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct IncomingCallOverlayCopy {
    let voiceCall: String
    let videoCall: String
    let decline: String
    let accept: String
    
    static var current: Self {
        if Bundle.junchatPreferredLocalizations.first == Bundle.junchatTraditionalChineseLocalization {
            return .init(voiceCall: "語音通話邀請",
                         videoCall: "視訊通話邀請",
                         decline: "掛斷",
                         accept: "接聽")
        }
        
        return .init(voiceCall: "语音通话邀请",
                     videoCall: "视频通话邀请",
                     decline: "挂断",
                     accept: "接听")
    }
}
