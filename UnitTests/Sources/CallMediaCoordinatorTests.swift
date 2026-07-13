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
struct CallMediaCoordinatorTests {
    @Test
    func outboundVoiceCallUsesEarpieceUntilRemoteMediaConnects() {
        let audioSession = AudioSessionMock()
        let ringbackTonePlayer = TestCallRingbackTonePlayer()
        var connectedToneCount = 0
        var proximityValues = [Bool]()
        let setProximityMonitoringEnabled: (Bool) -> Void = { proximityValues.append($0) }
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: true,
                                               audioSessionController: .init(audioSession: audioSession),
                                               connectedTonePlayer: { connectedToneCount += 1 },
                                               ringbackTonePlayer: ringbackTonePlayer,
                                               setProximityMonitoringEnabled: setProximityMonitoringEnabled)

        coordinator.prepareForCall()

        #expect(audioSession.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
        #expect(ringbackTonePlayer.startCallCount == 1)
        #expect(proximityValues.last == false)

        coordinator.remoteMediaConnected()
        coordinator.remoteMediaConnected()

        #expect(ringbackTonePlayer.stopCallCount == 1)
        #expect(connectedToneCount == 1)
        #expect(proximityValues.last == true)
    }

    @Test
    func lifecycleRecoveryPreservesTheSelectedSpeakerAndMuteState() {
        let audioSession = AudioSessionMock()
        var proximityValues = [Bool]()
        let setProximityMonitoringEnabled: (Bool) -> Void = { proximityValues.append($0) }
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: false,
                                               audioSessionController: .init(audioSession: audioSession),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: TestCallRingbackTonePlayer(),
                                               setProximityMonitoringEnabled: setProximityMonitoringEnabled)

        coordinator.selectOutput(.nativeSpeaker)
        coordinator.updateAudioEnabled(false)
        coordinator.recoverAfterLifecycleEvent()

        #expect(coordinator.currentAudioEnabled == false)
        #expect(coordinator.selectedOutput == .nativeSpeaker)
        #expect(audioSession.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.speaker)
        #expect(proximityValues.last == false)
    }

    @Test
    func stopIsIdempotent() {
        let audioSession = AudioSessionMock()
        let ringbackTonePlayer = TestCallRingbackTonePlayer()
        var proximityValues = [Bool]()
        let setProximityMonitoringEnabled: (Bool) -> Void = { proximityValues.append($0) }
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: true,
                                               audioSessionController: .init(audioSession: audioSession),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: ringbackTonePlayer,
                                               setProximityMonitoringEnabled: setProximityMonitoringEnabled)
        coordinator.prepareForCall()

        coordinator.stop()
        let routeOverrideCount = audioSession.overrideOutputAudioPortCallsCount
        coordinator.stop()

        #expect(audioSession.overrideOutputAudioPortCallsCount == routeOverrideCount)
        #expect(ringbackTonePlayer.stopCallCount == 1)
        #expect(proximityValues.last == false)
    }
}

private final class TestCallRingbackTonePlayer: CallRingbackTonePlaying {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}
