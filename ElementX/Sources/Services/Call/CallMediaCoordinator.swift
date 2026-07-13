//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AudioToolbox
import AVFoundation
import Foundation

enum CallAudioOutputSelection: Equatable {
    case nativeEarpiece
    case nativeSpeaker
    case system
}

enum CallAudioRoutePolicy {
    static func shouldEnableProximityMonitoring(voiceOnly: Bool,
                                                selectedOutput: CallAudioOutputSelection,
                                                remoteMediaConnected: Bool) -> Bool {
        voiceOnly && remoteMediaConnected && selectedOutput == .nativeEarpiece
    }

    static func shouldApplyInitialVoiceOutputDevice(voiceOnly: Bool,
                                                    selectedOutput: CallAudioOutputSelection,
                                                    hasAppliedInitialVoiceOutputDevice: Bool,
                                                    forcePreferInitialEarpiece: Bool,
                                                    portType: AVAudioSession.Port) -> Bool {
        let canUseBuiltInRoutes = portType == .builtInSpeaker || portType == .builtInReceiver

        return voiceOnly &&
            selectedOutput == .nativeEarpiece &&
            (!hasAppliedInitialVoiceOutputDevice || forcePreferInitialEarpiece) &&
            canUseBuiltInRoutes
    }
}

protocol CallRingbackTonePlaying: AnyObject {
    func start()
    func stop()
}

final class DefaultCallRingbackTonePlayer: CallRingbackTonePlaying {
    private var timer: Timer?

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard timer == nil else { return }

            playTone()
            let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.playTone()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    private func playTone() {
        AudioServicesPlaySystemSound(1151)
    }
}

@MainActor
protocol CallMediaCoordinatorProtocol: AnyObject {
    var selectedOutput: CallAudioOutputSelection { get }
    var currentAudioEnabled: Bool { get }
    var hasRemoteMediaConnected: Bool { get }

    func prepareForCall()
    func mediaCapturePermissionGranted()
    func selectOutput(_ output: CallAudioOutputSelection)
    func updateAudioEnabled(_ enabled: Bool)
    func recoverAfterLifecycleEvent()
    func restoreSelectedOutput()
    func handleInterruption(_ notification: Notification) -> Bool
    func handleMediaServicesReset()
    @discardableResult func remoteMediaConnected() -> Bool
    func stop()
}

@MainActor
final class CallMediaCoordinator: CallMediaCoordinatorProtocol {
    private let voiceOnly: Bool
    private let playConnectedTone: Bool
    private let audioSessionController: CallAudioSessionController
    private let connectedTonePlayer: () -> Void
    private let ringbackTonePlayer: CallRingbackTonePlaying
    private let setProximityMonitoringEnabled: (Bool) -> Void

    private(set) var selectedOutput = CallAudioOutputSelection.nativeEarpiece
    private(set) var currentAudioEnabled = true
    private(set) var hasRemoteMediaConnected = false

    private var hasPlayedConnectedTone = false
    private var hasStopped = false

    init(voiceOnly: Bool,
         playConnectedTone: Bool,
         audioSessionController: CallAudioSessionController,
         connectedTonePlayer: @escaping () -> Void,
         ringbackTonePlayer: CallRingbackTonePlaying,
         setProximityMonitoringEnabled: @escaping (Bool) -> Void) {
        self.voiceOnly = voiceOnly
        self.playConnectedTone = playConnectedTone
        self.audioSessionController = audioSessionController
        self.connectedTonePlayer = connectedTonePlayer
        self.ringbackTonePlayer = ringbackTonePlayer
        self.setProximityMonitoringEnabled = setProximityMonitoringEnabled
    }

    func prepareForCall() {
        guard !hasStopped else { return }

        if playConnectedTone {
            ringbackTonePlayer.start()
        }
        audioSessionController.activateForCall()
        restoreSelectedOutput()
    }

    func mediaCapturePermissionGranted() {
        guard !hasStopped else { return }

        audioSessionController.activateForCall()
        restoreSelectedOutput()
    }

    func selectOutput(_ output: CallAudioOutputSelection) {
        guard !hasStopped else { return }

        selectedOutput = output
        restoreSelectedOutput()
    }

    func updateAudioEnabled(_ enabled: Bool) {
        currentAudioEnabled = enabled
    }

    func recoverAfterLifecycleEvent() {
        guard !hasStopped else { return }

        audioSessionController.activateForCall()
        restoreSelectedOutput()
    }

    func restoreSelectedOutput() {
        guard !hasStopped else { return }

        if voiceOnly {
            switch selectedOutput {
            case .nativeEarpiece:
                audioSessionController.routeAudioToNativeEarpiece()
            case .nativeSpeaker:
                audioSessionController.routeAudioToSpeaker()
            case .system:
                break
            }
        }
        applyProximityMonitoringPolicy()
    }

    func handleInterruption(_ notification: Notification) -> Bool {
        audioSessionController.handleInterruption(notification: notification)

        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return true
        }

        return type == .ended
    }

    func handleMediaServicesReset() {
        audioSessionController.handleMediaServicesReset()
    }

    @discardableResult
    func remoteMediaConnected() -> Bool {
        guard !hasStopped, !hasRemoteMediaConnected else { return false }

        hasRemoteMediaConnected = true
        restoreSelectedOutput()
        ringbackTonePlayer.stop()
        if playConnectedTone, !hasPlayedConnectedTone {
            hasPlayedConnectedTone = true
            connectedTonePlayer()
        }
        return true
    }

    func stop() {
        guard !hasStopped else { return }

        hasStopped = true
        audioSessionController.deactivateAfterCall()
        ringbackTonePlayer.stop()
        setProximityMonitoringEnabled(false)
    }

    private func applyProximityMonitoringPolicy() {
        setProximityMonitoringEnabled(CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: voiceOnly,
                                                                                           selectedOutput: selectedOutput,
                                                                                           remoteMediaConnected: hasRemoteMediaConnected))
    }
}
