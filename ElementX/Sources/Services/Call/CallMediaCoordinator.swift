//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AudioToolbox
import AVFoundation
import Combine
import Foundation
import UIKit

enum CallAudioOutputSelection: Equatable {
    case nativeEarpiece
    case nativeSpeaker
    case system
}

enum CallMediaRecoveryReason: String, Equatable {
    case audioInterruptionEnded = "audio interruption ended"
    case mediaServicesReset = "media services reset"
    case applicationWillResignActive = "app will resign active"
    case applicationDidBecomeActive = "app became active"
    case mediaCapturePermissionGranted = "media capture permission granted"
    case remoteMediaConnected = "remote media connected"
}

enum CallMediaLifecycleEvent: Equatable {
    case audioRouteChanged
    case lifecycleRecovery(CallMediaRecoveryReason)
}

struct CallPictureInPictureRecoveryAttempt: Equatable {
    let reason: CallMediaRecoveryReason
    let attempt: Int
}

enum CallPictureInPictureAttemptResult: Equatable {
    case succeeded
    case retry
    case waitingForTransition
    case waitingForReadiness
}

typealias CallMediaLifecycleEventHandler = @MainActor (CallMediaLifecycleEvent) async -> Void
typealias CallPictureInPictureAttemptHandler = @MainActor (CallPictureInPictureRecoveryAttempt) async -> CallPictureInPictureAttemptResult

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

    func startLifecycleHandling(eventHandler: @escaping CallMediaLifecycleEventHandler,
                                pictureInPictureAttemptHandler: @escaping CallPictureInPictureAttemptHandler)
    func prepareForCall()
    func mediaCapturePermissionGranted()
    func selectOutput(_ output: CallAudioOutputSelection)
    func updateAudioEnabled(_ enabled: Bool)
    func recoverAfterLifecycleEvent()
    func restoreSelectedOutput()
    func handleInterruption(_ notification: Notification) -> Bool
    func handleMediaServicesReset()
    @discardableResult func remoteMediaConnected() -> Bool
    func schedulePictureInPictureRecovery(reason: CallMediaRecoveryReason, forceFirstAttempt: Bool)
    func pictureInPictureReadinessChanged()
    func stop()
}

extension CallMediaCoordinatorProtocol {
    func schedulePictureInPictureRecovery(reason: CallMediaRecoveryReason) {
        schedulePictureInPictureRecovery(reason: reason, forceFirstAttempt: false)
    }
}

@MainActor
final class CallMediaCoordinator: CallMediaCoordinatorProtocol {
    private struct PictureInPictureRecoveryState {
        let id = UUID()
        let reason: CallMediaRecoveryReason
        let forceFirstAttempt: Bool
        var attempt = 1
        var transitionWaits = 0
        var readinessWaits = 0
        var isWaitingForReadiness = false
    }

    private let voiceOnly: Bool
    private let playConnectedTone: Bool
    private let audioSessionController: CallAudioSessionController
    private let connectedTonePlayer: () -> Void
    private let ringbackTonePlayer: CallRingbackTonePlaying
    private let setProximityMonitoringEnabled: (Bool) -> Void
    private let allowsPictureInPicture: Bool
    private let notificationCenter: NotificationCenter
    private let applicationStateProvider: @MainActor () -> UIApplication.State
    private let pictureInPictureRetryDelay: Duration
    private let pictureInPictureMaxAttempts: Int
    private let pictureInPictureMaxTransitionWaits: Int
    private let pictureInPictureMaxReadinessWaits: Int

    private(set) var selectedOutput = CallAudioOutputSelection.nativeEarpiece
    private(set) var currentAudioEnabled = true
    private(set) var hasRemoteMediaConnected = false

    private var hasPlayedConnectedTone = false
    private var hasStopped = false
    private var hasStartedLifecycleHandling = false
    private var notificationCancellables = Set<AnyCancellable>()
    private var lifecycleEventHandler: CallMediaLifecycleEventHandler?
    private var pictureInPictureAttemptHandler: CallPictureInPictureAttemptHandler?
    private var routeRecoveryTask: Task<Void, Never>?
    private var lifecycleRecoveryTask: Task<Void, Never>?
    private var pictureInPictureRecoveryTask: Task<Void, Never>?
    private var pictureInPictureRecoveryTaskID: UUID?
    private var pictureInPictureRecoveryState: PictureInPictureRecoveryState?
    private var pictureInPictureReadinessVersion = 0

    init(voiceOnly: Bool,
         playConnectedTone: Bool,
         audioSessionController: CallAudioSessionController,
         connectedTonePlayer: @escaping () -> Void,
         ringbackTonePlayer: CallRingbackTonePlaying,
         setProximityMonitoringEnabled: @escaping (Bool) -> Void,
         allowsPictureInPicture: Bool = false,
         notificationCenter: NotificationCenter = .default,
         applicationStateProvider: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
         pictureInPictureRetryDelay: Duration = .milliseconds(350),
         pictureInPictureMaxAttempts: Int = 6,
         pictureInPictureMaxTransitionWaits: Int = 30,
         pictureInPictureMaxReadinessWaits: Int = 30) {
        self.voiceOnly = voiceOnly
        self.playConnectedTone = playConnectedTone
        self.audioSessionController = audioSessionController
        self.connectedTonePlayer = connectedTonePlayer
        self.ringbackTonePlayer = ringbackTonePlayer
        self.setProximityMonitoringEnabled = setProximityMonitoringEnabled
        self.allowsPictureInPicture = allowsPictureInPicture
        self.notificationCenter = notificationCenter
        self.applicationStateProvider = applicationStateProvider
        self.pictureInPictureRetryDelay = pictureInPictureRetryDelay
        self.pictureInPictureMaxAttempts = pictureInPictureMaxAttempts
        self.pictureInPictureMaxTransitionWaits = pictureInPictureMaxTransitionWaits
        self.pictureInPictureMaxReadinessWaits = max(1, pictureInPictureMaxReadinessWaits)
    }

    func startLifecycleHandling(eventHandler: @escaping CallMediaLifecycleEventHandler,
                                pictureInPictureAttemptHandler: @escaping CallPictureInPictureAttemptHandler) {
        guard !hasStopped else { return }

        lifecycleEventHandler = eventHandler
        self.pictureInPictureAttemptHandler = pictureInPictureAttemptHandler
        guard !hasStartedLifecycleHandling else { return }

        hasStartedLifecycleHandling = true
        observeLifecycleNotifications()
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

    func schedulePictureInPictureRecovery(reason: CallMediaRecoveryReason, forceFirstAttempt: Bool) {
        guard !hasStopped, allowsPictureInPicture, pictureInPictureAttemptHandler != nil else { return }

        pictureInPictureRecoveryState = .init(reason: reason, forceFirstAttempt: forceFirstAttempt)
        startPictureInPictureRecoveryTask()
    }

    func pictureInPictureReadinessChanged() {
        guard !hasStopped, allowsPictureInPicture else { return }

        pictureInPictureReadinessVersion &+= 1
        guard var recoveryState = pictureInPictureRecoveryState,
              recoveryState.isWaitingForReadiness else {
            return
        }

        recoveryState.readinessWaits = 0
        recoveryState.isWaitingForReadiness = false
        pictureInPictureRecoveryState = recoveryState
        startPictureInPictureRecoveryTask()
    }

    func stop() {
        guard !hasStopped else { return }

        hasStopped = true
        notificationCancellables.removeAll()
        routeRecoveryTask?.cancel()
        routeRecoveryTask = nil
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = nil
        pictureInPictureRecoveryTask?.cancel()
        pictureInPictureRecoveryTask = nil
        pictureInPictureRecoveryTaskID = nil
        pictureInPictureRecoveryState = nil
        lifecycleEventHandler = nil
        pictureInPictureAttemptHandler = nil
        audioSessionController.deactivateAfterCall()
        ringbackTonePlayer.stop()
        setProximityMonitoringEnabled(false)
    }

    private func applyProximityMonitoringPolicy() {
        setProximityMonitoringEnabled(CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: voiceOnly,
                                                                                           selectedOutput: selectedOutput,
                                                                                           remoteMediaConnected: hasRemoteMediaConnected))
    }

    private func observeLifecycleNotifications() {
        notificationCenter.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.emitAudioRouteChanged()
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, handleInterruption(notification) else { return }
                recoverAfterLifecycleEvent(reason: .audioInterruptionEnded)
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                handleMediaServicesReset()
                recoverAfterLifecycleEvent(reason: .mediaServicesReset)
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.schedulePictureInPictureRecovery(reason: .applicationWillResignActive, forceFirstAttempt: true)
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recoverAfterLifecycleEvent(reason: .applicationDidBecomeActive)
            }
            .store(in: &notificationCancellables)
    }

    private func emitAudioRouteChanged() {
        guard !hasStopped else { return }

        routeRecoveryTask?.cancel()
        routeRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !hasStopped, let lifecycleEventHandler else { return }
            await lifecycleEventHandler(.audioRouteChanged)
        }
    }

    private func recoverAfterLifecycleEvent(reason: CallMediaRecoveryReason) {
        guard !hasStopped else { return }

        recoverAfterLifecycleEvent()
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !hasStopped else { return }
            if let lifecycleEventHandler {
                await lifecycleEventHandler(.lifecycleRecovery(reason))
            }
            guard !Task.isCancelled, !hasStopped else { return }
            schedulePictureInPictureRecovery(reason: reason)
        }
    }

    private func startPictureInPictureRecoveryTask() {
        guard let recoveryState = pictureInPictureRecoveryState else { return }

        pictureInPictureRecoveryTask?.cancel()
        let taskID = UUID()
        pictureInPictureRecoveryTaskID = taskID
        pictureInPictureRecoveryTask = Task { @MainActor [weak self] in
            await self?.recoverPictureInPicture(recoveryID: recoveryState.id, taskID: taskID)
        }
    }

    private func recoverPictureInPicture(recoveryID: UUID, taskID: UUID) async {
        defer {
            if pictureInPictureRecoveryTaskID == taskID {
                pictureInPictureRecoveryTask = nil
                pictureInPictureRecoveryTaskID = nil
            }
        }

        guard let pictureInPictureAttemptHandler else { return }

        while true {
            guard !Task.isCancelled,
                  !hasStopped,
                  var recoveryState = pictureInPictureRecoveryState,
                  recoveryState.id == recoveryID else {
                return
            }

            let applicationState = applicationStateProvider()
            guard applicationState != .active || (recoveryState.forceFirstAttempt && recoveryState.attempt == 1) else {
                pictureInPictureRecoveryState = nil
                return
            }

            let readinessVersion = pictureInPictureReadinessVersion
            let result = await pictureInPictureAttemptHandler(.init(reason: recoveryState.reason,
                                                                    attempt: recoveryState.attempt))
            guard !Task.isCancelled,
                  !hasStopped,
                  pictureInPictureRecoveryState?.id == recoveryID else {
                return
            }

            switch result {
            case .succeeded:
                pictureInPictureRecoveryState = nil
                return
            case .retry:
                recoveryState.attempt += 1
                recoveryState.transitionWaits = 0
                recoveryState.readinessWaits = 0
                recoveryState.isWaitingForReadiness = false
                guard recoveryState.attempt <= pictureInPictureMaxAttempts else {
                    pictureInPictureRecoveryState = nil
                    MXLog.warning("[JunchatCall] unable to recover call picture in picture while inactive reason=\(recoveryState.reason.rawValue)")
                    return
                }
            case .waitingForTransition:
                recoveryState.transitionWaits += 1
                recoveryState.readinessWaits = 0
                recoveryState.isWaitingForReadiness = false
                guard recoveryState.transitionWaits <= pictureInPictureMaxTransitionWaits else {
                    pictureInPictureRecoveryState = nil
                    MXLog.warning("[JunchatCall] unable to recover call picture in picture while inactive reason=\(recoveryState.reason.rawValue)")
                    return
                }
            case .waitingForReadiness:
                recoveryState.transitionWaits = 0
                recoveryState.isWaitingForReadiness = true

                if readinessVersion != pictureInPictureReadinessVersion {
                    recoveryState.readinessWaits = 0
                    recoveryState.isWaitingForReadiness = false
                    pictureInPictureRecoveryState = recoveryState
                    continue
                }

                recoveryState.readinessWaits += 1
                pictureInPictureRecoveryState = recoveryState
                guard recoveryState.readinessWaits < pictureInPictureMaxReadinessWaits else {
                    MXLog.info("[JunchatCall] waiting for picture in picture readiness reason=\(recoveryState.reason.rawValue) attempt=\(recoveryState.attempt)")
                    return
                }
            }

            pictureInPictureRecoveryState = recoveryState
            try? await Task.sleep(for: pictureInPictureRetryDelay)
        }
    }
}
