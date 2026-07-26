//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
@testable import ElementX
import Testing

@MainActor
struct CallAudioSessionControllerTests {
    private var audioSessionMock: AudioSessionMock!
    private var controller: CallAudioSessionController!

    init() {
        audioSessionMock = AudioSessionMock()
        controller = CallAudioSessionController(audioSession: audioSessionMock)
    }

    @Test
    func activateForCallPreparesHapticsWithoutTakingWebKitAudioSession() {
        controller.activateForCall()

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingReceivedInValue == true)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 0)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func handleInterruptionEndedDoesNotReactivateWebKitAudioSession() {
        controller.activateForCall()
        let hapticsCount = audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount
        let activationCount = audioSessionMock.setActiveOptionsCallsCount
        let categoryCount = audioSessionMock.setCategoryModeOptionsCallsCount

        controller.handleInterruption(notification: .init(name: AVAudioSession.interruptionNotification,
                                                          userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]))

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount == hapticsCount)
        #expect(audioSessionMock.setActiveOptionsCallsCount == activationCount)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == categoryCount)
    }

    @Test
    func handleInterruptionDoesNotActivateWhenCallSessionIsIdle() {
        controller.handleInterruption(notification: .init(name: AVAudioSession.interruptionNotification,
                                                          userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]))

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount == 0)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func handleMediaServicesResetDoesNotReactivateWebKitAudioSession() {
        controller.activateForCall()
        let hapticsCount = audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount

        controller.handleMediaServicesReset()

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount == hapticsCount)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 0)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func deactivateAfterCallOnlyClearsRouteOverride() {
        controller.routeAudioToSpeaker()
        controller.deactivateAfterCall()

        #expect(audioSessionMock.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 0)
    }

    @Test
    func routeAudioToNativeEarpieceClearsSpeakerOverride() {
        controller.routeAudioToNativeEarpiece()

        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 0)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
        #expect(audioSessionMock.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
    }

    @Test
    func routeAudioToSpeakerUsesSpeakerPortOverride() {
        controller.routeAudioToSpeaker()

        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 0)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
        #expect(audioSessionMock.overrideOutputAudioPortReceivedPortOverride == .speaker)
    }
}
