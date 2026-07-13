//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
@testable import ElementX
import Testing
import UIKit

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
    func lifecycleNotificationsAreOwnedByTheCoordinator() async {
        let notificationCenter = NotificationCenter()
        let audioSession = AudioSessionMock()
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: false,
                                               audioSessionController: .init(audioSession: audioSession),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: TestCallRingbackTonePlayer(),
                                               setProximityMonitoringEnabled: { _ in },
                                               notificationCenter: notificationCenter)
        var events = [CallMediaLifecycleEvent]()
        coordinator.startLifecycleHandling { event in
            events.append(event)
        } pictureInPictureAttemptHandler: { _ in
            true
        }

        notificationCenter.post(name: AVAudioSession.routeChangeNotification, object: nil)
        await waitUntil { events == [.audioRouteChanged] }

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await Task.yield()
        #expect(events == [.audioRouteChanged])

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await waitUntil { events.contains(.lifecycleRecovery(.audioInterruptionEnded)) }

        notificationCenter.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await waitUntil { events.contains(.lifecycleRecovery(.mediaServicesReset)) }

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { events.contains(.lifecycleRecovery(.applicationDidBecomeActive)) }
    }

    @Test
    func resigningActiveForcesOnePictureInPictureAttempt() async {
        let notificationCenter = NotificationCenter()
        let applicationStateProvider: @MainActor () -> UIApplication.State = { .active }
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: false,
                                               audioSessionController: .init(audioSession: AudioSessionMock()),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: TestCallRingbackTonePlayer(),
                                               setProximityMonitoringEnabled: { _ in },
                                               allowsPictureInPicture: true,
                                               notificationCenter: notificationCenter,
                                               applicationStateProvider: applicationStateProvider)
        var attempts = [CallPictureInPictureRecoveryAttempt]()
        coordinator.startLifecycleHandling { _ in
        } pictureInPictureAttemptHandler: { attempt in
            attempts.append(attempt)
            return true
        }

        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        await waitUntil { attempts.count == 1 }

        #expect(attempts == [.init(reason: .applicationWillResignActive, attempt: 1)])

        coordinator.stop()
        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        await Task.yield()
        #expect(attempts.count == 1)
    }

    @Test
    func stoppingCancelsPictureInPictureRetries() async throws {
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: false,
                                               audioSessionController: .init(audioSession: AudioSessionMock()),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: TestCallRingbackTonePlayer(),
                                               setProximityMonitoringEnabled: { _ in },
                                               allowsPictureInPicture: true,
                                               applicationStateProvider: { .background },
                                               pictureInPictureRetryDelay: .milliseconds(20))
        var attempts = [CallPictureInPictureRecoveryAttempt]()
        coordinator.startLifecycleHandling { _ in
        } pictureInPictureAttemptHandler: { attempt in
            attempts.append(attempt)
            return false
        }

        coordinator.schedulePictureInPictureRecovery(reason: .remoteMediaConnected)
        await waitUntil { attempts.count == 1 }
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(50))

        #expect(attempts.count == 1)
    }

    @Test
    func stoppingDuringLifecycleRecoveryPreventsPictureInPicture() async {
        let notificationCenter = NotificationCenter()
        let applicationStateProvider: @MainActor () -> UIApplication.State = { .background }
        let coordinator = CallMediaCoordinator(voiceOnly: true,
                                               playConnectedTone: false,
                                               audioSessionController: .init(audioSession: AudioSessionMock()),
                                               connectedTonePlayer: { },
                                               ringbackTonePlayer: TestCallRingbackTonePlayer(),
                                               setProximityMonitoringEnabled: { _ in },
                                               allowsPictureInPicture: true,
                                               notificationCenter: notificationCenter,
                                               applicationStateProvider: applicationStateProvider)
        var releaseRecovery: CheckedContinuation<Void, Never>?
        var pictureInPictureAttempts = 0
        coordinator.startLifecycleHandling { event in
            guard event == .lifecycleRecovery(.applicationDidBecomeActive) else { return }
            await withCheckedContinuation { releaseRecovery = $0 }
        } pictureInPictureAttemptHandler: { _ in
            pictureInPictureAttempts += 1
            return true
        }

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { releaseRecovery != nil }
        coordinator.stop()
        releaseRecovery?.resume()
        await Task.yield()

        #expect(pictureInPictureAttempts == 0)
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

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<20 {
            guard !condition() else { return }
            await Task.yield()
        }
        #expect(condition())
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
