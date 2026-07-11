//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import AudioToolbox
import CallKit
import Combine
import SwiftUI
import UIKit

typealias CallScreenViewModelType = StateStoreViewModel<CallScreenViewState, CallScreenViewAction>

enum CallAudioOutputSelection {
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

class CallScreenViewModel: CallScreenViewModelType, CallScreenViewModelProtocol {
    private let elementCallService: ElementCallServiceProtocol
    private let configuration: ElementCallConfiguration
    private let isPictureInPictureAllowed: Bool
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let callAudioSessionController: CallAudioSessionController
    private let callConnectedTonePlayer: () -> Void
    private let callEndedTonePlayer: () -> Void
    private let callRingbackTonePlayer: CallRingbackTonePlaying
    private let setProximityMonitoringEnabled: (Bool) -> Void
    private let applicationStateProvider: @MainActor () -> UIApplication.State
    private let deviceID: String

    private let widgetDriver: ElementCallWidgetDriverProtocol

    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    @CancellableTask
    private var timeoutTask: Task<Void, Never>?
    private var pictureInPictureRecoveryTask: Task<Void, Never>?

    private var hasAppliedInitialVoiceOutputDevice = false
    private var hasPlayedCallConnectedTone = false
    private var hasCompletedCall = false
    private var hasRequestedHangup = false
    private var hasRemoteMediaConnected = false
    private var currentAudioEnabled = true
    private var selectedNativeOutput: CallAudioOutputSelection = .nativeEarpiece

    /// Designated initialiser
    /// - Parameters:
    ///   - elementCallService: service responsible for setting up CallKit
    ///   - roomProxy: The room in which the call should be created
    ///   - callBaseURL: Which Element Call instance should be used
    ///   - clientID: Something to identify the current client on the Element Call side
    init(elementCallService: ElementCallServiceProtocol,
         configuration: ElementCallConfiguration,
         allowPictureInPicture: Bool,
         appHooks: AppHooks,
         appSettings: AppSettings,
         analyticsService: AnalyticsService,
         callAudioSessionController: CallAudioSessionController = .init(),
         callConnectedTonePlayer: @escaping () -> Void = CallScreenViewModel.playDefaultCallConnectedTone,
         callEndedTonePlayer: @escaping () -> Void = CallScreenViewModel.playDefaultCallEndedTone,
         callRingbackTonePlayer: CallRingbackTonePlaying = DefaultCallRingbackTonePlayer(),
         setProximityMonitoringEnabled: @escaping (Bool) -> Void = { UIDevice.current.isProximityMonitoringEnabled = $0 },
         applicationStateProvider: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }) {
        self.elementCallService = elementCallService
        self.configuration = configuration
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.callAudioSessionController = callAudioSessionController
        self.callConnectedTonePlayer = callConnectedTonePlayer
        self.callEndedTonePlayer = callEndedTonePlayer
        self.callRingbackTonePlayer = callRingbackTonePlayer
        self.setProximityMonitoringEnabled = setProximityMonitoringEnabled
        self.applicationStateProvider = applicationStateProvider
        isPictureInPictureAllowed = allowPictureInPicture

        guard let deviceID = configuration.clientProxy.deviceID else { fatalError("Missing device ID for the call.") }
        self.deviceID = deviceID
        widgetDriver = configuration.roomProxy.elementCallWidgetDriver(deviceID: deviceID)

        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript,
                                                         certificateValidator: appHooks.certificateValidatorHook))

        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case let .setAudioEnabled(enabled, roomID):
                    guard roomID == configuration.callRoomID else {
                        MXLog.error("Received mute request for a different room: \(roomID) != \(configuration.callRoomID)")
                        return
                    }

                    currentAudioEnabled = enabled
                    Task {
                        await self.setAudioEnabled(enabled)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        widgetDriver.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedMessage in
                guard let self else { return }

                Task {
                    await self.handleWidgetDriverMessage(receivedMessage)
                }
            }
            .store(in: &cancellables)

        widgetDriver.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .callEnded:
                    completeCall()
                case .mediaStateChanged(let audioEnabled, _):
                    currentAudioEnabled = audioEnabled
                    elementCallService.setAudioEnabled(audioEnabled, roomID: configuration.callRoomID)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                guard let self, !hasCompletedCall else { return }
                Task { await self.recoverPreferredVoiceOutputOnWeb(reason: "audio route changed") }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let self else { return }
                callAudioSessionController.handleInterruption(notification: notification)
                guard isAudioSessionInterruptionEnded(notification) else { return }
                recoverCallMediaAfterLifecycleEvent(reason: "audio interruption ended")
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                callAudioSessionController.handleMediaServicesReset()
                recoverCallMediaAfterLifecycleEvent(reason: "media services reset")
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.schedulePictureInPictureRecovery(reason: "app will resign active", forceFirstAttempt: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                recoverCallMediaAfterLifecycleEvent(reason: "app became active")
            }
            .store(in: &cancellables)

        setupCall()
    }

    override func process(viewAction: CallScreenViewAction) {
        switch viewAction {
        case .urlChanged(let url):
            guard let url else { return }
            MXLog.info("URL changed to: \(url)")
        case .pictureInPictureIsAvailable(let controller):
            actionsSubject.send(.pictureInPictureIsAvailable(controller))
        case .navigateBack:
            Task { await handleBackwardsNavigation() }
        case .pictureInPictureWillStop:
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            MXLog.info("[JunchatCall] end call requested by user room=\(configuration.callRoomID)")
            requestHangup()
            completeCall()
        case .mediaCapturePermissionGranted:
            logAudioSessionSnapshot(reason: "before media capture permission grant handling")
            callAudioSessionController.activateForCall()
            restoreVoiceCallNativeOutputIfNeeded()
            logAudioSessionSnapshot(reason: "after media capture permission grant handling")
            Task {
                await recoverPreferredVoiceOutputOnWeb(reason: "media capture permission granted")
                await ensurePictureInPictureForInactiveCall(reason: "media capture permission granted")
            }
        case .outputDeviceSelected(deviceID: let deviceID):
            handleOutputDeviceSelected(deviceID: deviceID)
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        }
    }

    func stop() {
        if hasCompletedCall {
            MXLog.info("[JunchatCall] skip hangup on stop because call is already complete room=\(configuration.callRoomID)")
        } else {
            requestHangup()
        }

        cleanUpLocalCallState()
    }

    private func requestHangup() {
        guard !hasRequestedHangup else {
            MXLog.info("[JunchatCall] skip duplicate hangup request room=\(configuration.callRoomID)")
            return
        }

        hasRequestedHangup = true
        Task { [weak self] in
            await self?.hangup()
        }
    }

    private func cleanUpLocalCallState() {
        logAudioSessionSnapshot(reason: "before call cleanup")
        timeoutTask = nil
        pictureInPictureRecoveryTask?.cancel()
        pictureInPictureRecoveryTask = nil
        callAudioSessionController.deactivateAfterCall()
        elementCallService.tearDownCallSession()
        callRingbackTonePlayer.stop()
        setProximityMonitoringEnabled(false)
        logAudioSessionSnapshot(reason: "after call cleanup")
    }

    // MARK: - Private

    private func handleWidgetAction(message: String) async {
        switch JunchatCallMemberWidgetMessageFilter.fromWidgetResult(for: message,
                                                                     ownUserID: configuration.roomProxy.ownUserID,
                                                                     deviceID: deviceID) {
        case .forward:
            break
        case .acknowledge(let response):
            MXLog.info("[JunchatCall] suppress own empty call.member from widget room=\(configuration.callRoomID) device=\(deviceID)")
            await postJSONToWidget(response)
            return
        }

        if let decodedMessage = try? DecodedWidgetMessage.decode(message: message) {
            if decodedMessage.isJunchatCallConnected {
                MXLog.info("[JunchatCall] widget reported remote media connected room=\(configuration.callRoomID)")
                await handleRemoteMediaConnectedIfNeeded()
                return
            }

            if timeoutTask != nil, decodedMessage.hasLoaded {
                // This means that the call room was joined succesfully, we can stop the timeout task
                MXLog.info("[JunchatCall] widget loaded room=\(configuration.callRoomID)")
                timeoutTask = nil
            }
        }
        await widgetDriver.handleMessage(message)
    }

    private func handleWidgetDriverMessage(_ message: String) async {
        switch JunchatCallMemberWidgetMessageFilter.toWidgetResult(for: message,
                                                                   ownUserID: configuration.roomProxy.ownUserID,
                                                                   deviceID: deviceID) {
        case .forward(let message):
            await postJSONToWidget(message)
        case .acknowledge(let response):
            MXLog.info("[JunchatCall] suppress own empty call.member to widget room=\(configuration.callRoomID) device=\(deviceID)")
            await widgetDriver.handleMessage(response)
        }
    }

    nonisolated private static func playDefaultCallConnectedTone() {
        AudioServicesPlaySystemSound(1104)
    }

    nonisolated private static func playDefaultCallEndedTone() {
        AudioServicesPlaySystemSound(1053)
    }

    private func playCallConnectedToneIfNeeded() {
        callRingbackTonePlayer.stop()
        guard configuration.playConnectedTone, !hasPlayedCallConnectedTone else {
            MXLog.info("[JunchatCall] skip connected tone room=\(configuration.callRoomID) playConnectedTone=\(configuration.playConnectedTone) hasPlayed=\(hasPlayedCallConnectedTone)")
            return
        }

        hasPlayedCallConnectedTone = true
        MXLog.info("[JunchatCall] play connected tone room=\(configuration.callRoomID)")
        callConnectedTonePlayer()
    }

    private func completeCall() {
        guard !hasCompletedCall else {
            return
        }

        MXLog.info("[JunchatCall] completeCall room=\(configuration.callRoomID)")
        hasCompletedCall = true
        cleanUpLocalCallState()
        callEndedTonePlayer()
        actionsSubject.send(.dismiss)
    }

    private func setupCall() {
        Task { [weak self] in
            guard let self else { return }

            MXLog.info("[JunchatCall] setupCall start room=\(configuration.callRoomID) voice=\(configuration.voiceOnly) playConnectedTone=\(configuration.playConnectedTone)")

            let baseURL = if let baseURLOverride = configuration.elementCallBaseURLOverride {
                baseURLOverride
            } else {
                configuration.elementCallBaseURL
            }

            // We only set the analytics configuration if analytics are enabled
            let analyticsConfiguration: ElementCallAnalyticsConfiguration? = if analyticsService.isEnabled {
                .init(posthogAPIHost: appSettings.elementCallPosthogAPIHost,
                      posthogAPIKey: appSettings.elementCallPosthogAPIKey,
                      sentryDSN: appSettings.elementCallPosthogSentryDSN)
            } else {
                nil
            }
            let rageshakeURL: String? = if case let .url(baseURL) = appSettings.bugReportRageshakeURL.publisher.value {
                baseURL.absoluteString
            } else {
                nil
            }

            switch await widgetDriver.start(baseURL: baseURL,
                                            clientID: configuration.clientID,
                                            colorScheme: configuration.colorScheme,
                                            voiceOnly: configuration.voiceOnly,
                                            rageshakeURL: rageshakeURL,
                                            analyticsConfiguration: analyticsConfiguration) {
            case .success(let url):
                state.url = url
            case .failure(let error):
                MXLog.error("Failed starting ElementCall Widget Driver with error: \(error)")
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: L10n.errorUnknown,
                                                 primaryButton: .init(title: L10n.actionOk) {
                                                     self.actionsSubject.send(.dismiss)
                                                 })
                return
            }

            startRingbackToneIfNeeded()
            callAudioSessionController.activateForCall()
            restoreVoiceCallNativeOutputIfNeeded()

            await elementCallService.setupCallSession(roomID: configuration.roomProxy.id,
                                                      roomDisplayName: configuration.roomProxy.infoPublisher.value.displayName ?? configuration.roomProxy.id)
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            MXLog.error("Failed to join Element Call: Timeout")
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: L10n.commonError,
                                             message: L10n.errorUnknown,
                                             primaryButton: .init(title: L10n.actionDismiss) { [weak self] in self?.actionsSubject.send(.dismiss) })
            timeoutTask = nil
        }
    }

    nonisolated private static let nativeEarpieceID = "earpiece-id"
    nonisolated private static let nativeSpeakerID = "junchat-native-speaker"

    nonisolated static func junchatAudioOutputJavaScript(portType: AVAudioSession.Port,
                                                         uid: String,
                                                         portName: String,
                                                         preferInitialEarpiece: Bool) -> String {
        let deviceList: String
        let canUseBuiltInRoutes = portType == .builtInSpeaker || portType == .builtInReceiver
        let shouldSelectEarpiece = canUseBuiltInRoutes && preferInitialEarpiece

        if canUseBuiltInRoutes {
            // Element Call's iOS audio model expects the speaker device to be
            // marked with forEarpiece, then it exposes the hard-coded
            // earpiece-id option back to native.
            let speakerName = portType == .builtInSpeaker ? portName : "Speaker"
            deviceList = "{id: \(javaScriptStringLiteral(nativeSpeakerID)), name: \(javaScriptStringLiteral(speakerName)), isSpeaker: true, forEarpiece: true}"
        } else {
            // Doesn't matter because the switch is handled through the OS.
            deviceList = "{id: \"dummy\", name: \"dummy\"}"
        }

        let selectInitialEarpiece = shouldSelectEarpiece ? "window.controls.setAudioDevice(\(javaScriptStringLiteral(nativeEarpieceID)));" : ""

        return """
        (() => {
            window.controls.setAvailableAudioDevices([\(deviceList)]);
            \(selectInitialEarpiece)
        })()
        """
    }

    nonisolated private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return string
    }

    private func handleOutputDeviceSelected(deviceID: String) {
        if deviceID == Self.nativeEarpieceID {
            selectedNativeOutput = .nativeEarpiece
            MXLog.info("Selected native earpiece output")
            callAudioSessionController.routeAudioToNativeEarpiece()
        } else if deviceID == Self.nativeSpeakerID {
            selectedNativeOutput = .nativeSpeaker
            MXLog.info("Selected native speaker output")
            callAudioSessionController.routeAudioToSpeaker()
        } else {
            selectedNativeOutput = .system
            MXLog.info("Selected system output device: \(deviceID)")
        }

        applyProximityMonitoringPolicy()
        logAudioSessionSnapshot(reason: "after output device selected \(deviceID)")
    }

    private func restoreVoiceCallNativeOutputIfNeeded() {
        guard configuration.voiceOnly else {
            applyProximityMonitoringPolicy()
            return
        }

        switch selectedNativeOutput {
        case .nativeEarpiece:
            callAudioSessionController.routeAudioToNativeEarpiece()
        case .nativeSpeaker:
            callAudioSessionController.routeAudioToSpeaker()
        case .system:
            break
        }
        applyProximityMonitoringPolicy()
    }

    private func recoverCallMediaAfterLifecycleEvent(reason: String) {
        guard !hasCompletedCall else { return }
        MXLog.info("[JunchatCall] recover call media after \(reason) room=\(configuration.callRoomID)")
        logAudioSessionSnapshot(reason: "before lifecycle recovery \(reason)")
        callAudioSessionController.activateForCall()
        restoreVoiceCallNativeOutputIfNeeded()
        logAudioSessionSnapshot(reason: "after lifecycle route recovery \(reason)")

        Task { [weak self] in
            guard let self else { return }
            await recoverPreferredVoiceOutputOnWeb(reason: reason)
            await setAudioEnabled(currentAudioEnabled)
            logAudioSessionSnapshot(reason: "after lifecycle web recovery \(reason)")
            await ensurePictureInPictureForInactiveCall(reason: reason)
        }
    }

    private func isAudioSessionInterruptionEnded(_ notification: Notification) -> Bool {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return true
        }

        return type == .ended
    }

    private func handleRemoteMediaConnectedIfNeeded() async {
        guard !hasRemoteMediaConnected else {
            return
        }
        hasRemoteMediaConnected = true
        MXLog.info("[JunchatCall] remote media connected room=\(configuration.callRoomID)")
        logAudioSessionSnapshot(reason: "before remote media connected recovery")
        restoreVoiceCallNativeOutputIfNeeded()
        applyProximityMonitoringPolicy()
        playCallConnectedToneIfNeeded()
        logAudioSessionSnapshot(reason: "after remote media connected recovery")
        await recoverPreferredVoiceOutputOnWeb(reason: "remote media connected")
        schedulePictureInPictureRecovery(reason: "remote media connected")
    }

    private func applyProximityMonitoringPolicy() {
        setProximityMonitoringEnabled(CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: configuration.voiceOnly,
                                                                                           selectedOutput: selectedNativeOutput,
                                                                                           remoteMediaConnected: hasRemoteMediaConnected))
    }

    private func startRingbackToneIfNeeded() {
        guard configuration.playConnectedTone else {
            MXLog.info("[JunchatCall] not starting ringback room=\(configuration.callRoomID)")
            return
        }
        MXLog.info("[JunchatCall] start ringback room=\(configuration.callRoomID)")
        callRingbackTonePlayer.start()
    }

    private func handleBackwardsNavigation() async {
        guard state.url != nil,
              isPictureInPictureAllowed,
              let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler else {
            actionsSubject.send(.dismiss)
            return
        }

        switch await requestPictureInPictureHandler() {
        case .success:
            actionsSubject.send(.pictureInPictureStarted)
        case .failure:
            actionsSubject.send(.dismiss)
        }
    }

    private func schedulePictureInPictureRecovery(reason: String, forceFirstAttempt: Bool = false) {
        pictureInPictureRecoveryTask?.cancel()
        pictureInPictureRecoveryTask = Task { [weak self] in
            await self?.ensurePictureInPictureForInactiveCall(reason: reason, forceFirstAttempt: forceFirstAttempt)
        }
    }

    private func ensurePictureInPictureForInactiveCall(reason: String, forceFirstAttempt: Bool = false) async {
        guard isPictureInPictureAllowed else { return }

        for attempt in 1...6 {
            guard !Task.isCancelled else { return }

            let applicationState = await MainActor.run { applicationStateProvider() }
            MXLog.info("[JunchatCall] PiP recovery check reason=\(reason) attempt=\(attempt) appState=\(applicationState.rawValue) forceFirstAttempt=\(forceFirstAttempt) room=\(configuration.callRoomID)")
            guard applicationState != .active || (forceFirstAttempt && attempt == 1) else { return }

            if await startPictureInPictureForBackgrounding(reason: reason, attempt: attempt) {
                return
            }

            guard attempt < 6 else { break }

            try? await Task.sleep(for: .milliseconds(350))
        }

        MXLog.warning("[JunchatCall] unable to recover call picture in picture while inactive reason=\(reason) room=\(configuration.callRoomID)")
    }

    private func startPictureInPictureForBackgrounding(reason: String, attempt: Int) async -> Bool {
        logAudioSessionSnapshot(reason: "before PiP recovery attempt \(attempt) \(reason)")
        guard state.url != nil,
              isPictureInPictureAllowed,
              let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler else {
            MXLog.info("[JunchatCall] skip picture in picture recovery reason=\(reason) attempt=\(attempt) hasURL=\(state.url != nil) hasHandler=\(state.bindings.requestPictureInPictureHandler != nil) room=\(configuration.callRoomID)")
            return false
        }

        switch await requestPictureInPictureHandler() {
        case .success:
            MXLog.info("[JunchatCall] started picture in picture recovery reason=\(reason) attempt=\(attempt) room=\(configuration.callRoomID)")
            logAudioSessionSnapshot(reason: "after successful PiP recovery attempt \(attempt) \(reason)")
            return true
        case .failure(let error):
            MXLog.warning("[JunchatCall] unable to start picture in picture recovery reason=\(reason) attempt=\(attempt) error=\(error) room=\(configuration.callRoomID)")
            logAudioSessionSnapshot(reason: "after failed PiP recovery attempt \(attempt) \(reason)")
            return false
        }
    }

    private func logAudioSessionSnapshot(reason: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName):\($0.uid)" }.joined(separator: ",")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName):\($0.uid)" }.joined(separator: ",")
        let availableInputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName):\($0.uid)" }.joined(separator: ",") ?? "nil"
        let appState = UIApplication.shared.applicationState.rawValue
        MXLog.info("[JunchatCallAudio] reason=\(reason) appState=\(appState) category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) outputs=[\(outputs)] inputs=[\(inputs)] availableInputs=[\(availableInputs)] secondarySilenced=\(session.secondaryAudioShouldBeSilencedHint) otherAudio=\(session.isOtherAudioPlaying) selectedNativeOutput=\(selectedNativeOutput) remoteConnected=\(hasRemoteMediaConnected) audioEnabled=\(currentAudioEnabled) room=\(configuration.callRoomID)")
    }

    private func setAudioEnabled(_ enabled: Bool) async {
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .mediaState,
                                               data: .init(audioEnabled: enabled),
                                               widgetId: widgetDriver.widgetID)
        await postMessageToWidget(message)
    }

    func hangup() async {
        let message = ElementCallWidgetMessage(direction: .fromWidget,
                                               action: .hangup,
                                               widgetId: widgetDriver.widgetID)

        await postMessageToWidget(message)
    }

    private func postMessageToWidget(_ message: ElementCallWidgetMessage) async {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            MXLog.error("Failed encoding widget message with error: \(error)")
            return
        }

        guard let json = String(data: data, encoding: .utf8) else {
            MXLog.error("Invalid data for widget message")
            return
        }

        await postJSONToWidget(json)
    }

    private func postJSONToWidget(_ json: String) async {
        do {
            let message = "postMessage(\(json), '*')"
            let result = try await state.bindings.javaScriptEvaluator?(message)
            MXLog.debug("Evaluated javascript: \(json) with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }

    /// This function updates the list of available audio outputs on the web side
    /// however since we actually handle switching the audio output through the OS,
    /// this is only used to inform the webview when the speaker is selected,
    /// so that the option to use the earpiece can be displayed.
    private func recoverPreferredVoiceOutputOnWeb(reason: String) async {
        guard !hasCompletedCall else { return }
        await updateOutputsListOnWeb(forcePreferInitialEarpiece: true)

        guard configuration.voiceOnly,
              selectedNativeOutput == .nativeEarpiece,
              let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first,
              currentOutput.portType == .builtInSpeaker || currentOutput.portType == .builtInReceiver else {
            return
        }

        callAudioSessionController.routeAudioToNativeEarpiece()
        let javaScript = """
        (() => {
            if (!window.controls?.setAudioDevice) {
                return false;
            }
            window.controls.setAudioDevice(\(Self.javaScriptStringLiteral(Self.nativeEarpieceID)));
            return true;
        })()
        """

        do {
            let result = try await state.bindings.javaScriptEvaluator?(javaScript)
            MXLog.info("[JunchatCall] recovered preferred voice output on web after \(reason) result=\(String(describing: result)) room=\(configuration.callRoomID)")
        } catch {
            MXLog.error("[JunchatCall] failed recovering preferred voice output on web after \(reason): \(error)")
        }

        applyProximityMonitoringPolicy()
        logAudioSessionSnapshot(reason: "after preferred voice output web recovery \(reason)")
    }

    private func updateOutputsListOnWeb(forcePreferInitialEarpiece: Bool = false) async {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }

        let shouldApplyInitialVoiceOutputDevice = CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: configuration.voiceOnly,
                                                                                                           selectedOutput: selectedNativeOutput,
                                                                                                           hasAppliedInitialVoiceOutputDevice: hasAppliedInitialVoiceOutputDevice,
                                                                                                           forcePreferInitialEarpiece: forcePreferInitialEarpiece,
                                                                                                           portType: currentOutput.portType)

        let javaScript = Self.junchatAudioOutputJavaScript(portType: currentOutput.portType,
                                                           uid: currentOutput.uid,
                                                           portName: currentOutput.portName,
                                                           preferInitialEarpiece: shouldApplyInitialVoiceOutputDevice)
        do {
            let result = try await state.bindings.javaScriptEvaluator?(javaScript)
            if shouldApplyInitialVoiceOutputDevice {
                hasAppliedInitialVoiceOutputDevice = true
            }
            MXLog.debug("Evaluated audio output devices javascript with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
}
