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
    func activateForVoiceCallConfiguresTheSessionWithoutTakingCallKitActivation() throws {
        controller.activateForCall(voiceOnly: true)

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingReceivedInValue == true)
        let arguments = try #require(audioSessionMock.setCategoryModeOptionsReceivedArguments)
        #expect(arguments.category == .playAndRecord)
        #expect(arguments.mode == .voiceChat)
        #expect(arguments.options == [.allowBluetoothHFP])
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func activateForVideoCallDefaultsToSpeaker() throws {
        controller.activateForCall(voiceOnly: false)

        let arguments = try #require(audioSessionMock.setCategoryModeOptionsReceivedArguments)
        #expect(arguments.category == .playAndRecord)
        #expect(arguments.mode == .videoChat)
        #expect(arguments.options == [.allowBluetoothHFP, .defaultToSpeaker])
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func handleInterruptionEndedDoesNotReactivateWebKitAudioSession() {
        controller.activateForCall(voiceOnly: true)
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
    func handleMediaServicesResetAllowsCallAudioConfigurationToBeRestored() {
        controller.activateForCall(voiceOnly: true)

        controller.handleMediaServicesReset()
        controller.activateForCall(voiceOnly: true)

        #expect(audioSessionMock.setAllowHapticsAndSystemSoundsDuringRecordingCallsCount == 2)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 2)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
    }

    @Test
    func deactivateAfterCallOnlyClearsRouteOverride() {
        controller.activateForCall(voiceOnly: true)
        controller.routeAudioToSpeaker()
        controller.deactivateAfterCall()

        #expect(audioSessionMock.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
        #expect(audioSessionMock.setActiveOptionsCallsCount == 0)
        #expect(audioSessionMock.setCategoryModeOptionsCallsCount == 1)
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
