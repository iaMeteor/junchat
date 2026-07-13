//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AudioToolbox
import AVFoundation
import CallKit
import Combine
import SwiftUI
import UIKit

typealias CallScreenViewModelType = StateStoreViewModel<CallScreenViewState, CallScreenViewAction>

class CallScreenViewModel: CallScreenViewModelType, CallScreenViewModelProtocol {
    private let elementCallService: ElementCallServiceProtocol
    private let configuration: ElementCallConfiguration
    private let isPictureInPictureAllowed: Bool
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let callMediaCoordinator: CallMediaCoordinatorProtocol
    private let callEndedTonePlayer: () -> Void
    private let deviceID: String

    private let widgetDriver: ElementCallWidgetDriverProtocol

    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    @CancellableTask
    private var timeoutTask: Task<Void, Never>?

    @CancellableTask
    private var setupTask: Task<Void, Never>?

    private var hasAppliedInitialVoiceOutputDevice = false
    private var hasCleanedUpLocalCallState = false
    private var hasCompletedCall = false
    private var hasRequestedHangup = false

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
         applicationStateProvider: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
         callMediaCoordinator: CallMediaCoordinatorProtocol? = nil) {
        self.elementCallService = elementCallService
        self.configuration = configuration
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.callMediaCoordinator = callMediaCoordinator ?? CallMediaCoordinator(voiceOnly: configuration.voiceOnly,
                                                                                 playConnectedTone: configuration.playConnectedTone,
                                                                                 audioSessionController: callAudioSessionController,
                                                                                 connectedTonePlayer: callConnectedTonePlayer,
                                                                                 ringbackTonePlayer: callRingbackTonePlayer,
                                                                                 setProximityMonitoringEnabled: setProximityMonitoringEnabled,
                                                                                 allowsPictureInPicture: allowPictureInPicture,
                                                                                 applicationStateProvider: applicationStateProvider)
        self.callEndedTonePlayer = callEndedTonePlayer
        isPictureInPictureAllowed = allowPictureInPicture

        guard let deviceID = configuration.clientProxy.deviceID else { fatalError("Missing device ID for the call.") }
        self.deviceID = deviceID
        widgetDriver = configuration.roomProxy.elementCallWidgetDriver(deviceID: deviceID)

        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript,
                                                         certificateValidator: appHooks.certificateValidatorHook))

        self.callMediaCoordinator.startLifecycleHandling { [weak self] event in
            await self?.handleCallMediaLifecycleEvent(event)
        } pictureInPictureAttemptHandler: { [weak self] attempt in
            guard let self else { return .succeeded }
            return await startPictureInPictureForBackgrounding(attempt)
        }

        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case let .setAudioEnabled(enabled, roomID):
                    guard roomID == configuration.callRoomID else {
                        MXLog.error("Received mute request for a different room")
                        return
                    }

                    self.callMediaCoordinator.updateAudioEnabled(enabled)
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
                    self.callMediaCoordinator.updateAudioEnabled(audioEnabled)
                    elementCallService.setAudioEnabled(audioEnabled, roomID: configuration.callRoomID)
                }
            }
            .store(in: &cancellables)

        setupCall()
    }

    override func process(viewAction: CallScreenViewAction) {
        switch viewAction {
        case .urlChanged(let url):
            guard let url else { return }
            MXLog.info("Call URL changed \(CallDiagnostics.urlSummary(url))")
        case .pictureInPictureStarted:
            actionsSubject.send(.pictureInPictureStarted)
        case .pictureInPictureReadinessChanged:
            callMediaCoordinator.pictureInPictureReadinessChanged()
        case .navigateBack:
            Task { await handleBackwardsNavigation() }
        case .pictureInPictureWillStop:
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            MXLog.info("[JunchatCall] end call requested by user")
            requestHangup()
            completeCall()
        case .mediaCapturePermissionGranted:
            logAudioSessionSnapshot(reason: "before media capture permission grant handling")
            callMediaCoordinator.mediaCapturePermissionGranted()
            logAudioSessionSnapshot(reason: "after media capture permission grant handling")
            Task {
                await recoverPreferredVoiceOutputOnWeb(reason: "media capture permission granted")
                callMediaCoordinator.schedulePictureInPictureRecovery(reason: .mediaCapturePermissionGranted)
            }
        case .outputDeviceSelected(deviceID: let deviceID):
            handleOutputDeviceSelected(deviceID: deviceID)
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        }
    }

    func stop() {
        if hasCompletedCall {
            MXLog.info("[JunchatCall] skip hangup on stop because call is already complete")
        } else {
            requestHangup()
        }

        cleanUpLocalCallState()
    }

    func requestPictureInPicture() async -> Result<Void, CallScreenError> {
        guard let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler else {
            return .failure(.pictureInPictureNotAvailable)
        }
        return await requestPictureInPictureHandler()
    }

    func stopPictureInPicture() {
        state.bindings.stopPictureInPictureHandler?()
    }

    private func requestHangup() {
        guard !hasRequestedHangup else {
            MXLog.info("[JunchatCall] skip duplicate hangup request")
            return
        }

        hasRequestedHangup = true
        Task { [weak self] in
            await self?.hangup()
        }
    }

    private func cleanUpLocalCallState() {
        guard !hasCleanedUpLocalCallState else { return }
        hasCleanedUpLocalCallState = true

        logAudioSessionSnapshot(reason: "before call cleanup")
        timeoutTask = nil
        setupTask = nil
        widgetDriver.stop()
        stopPictureInPicture()
        callMediaCoordinator.stop()
        elementCallService.tearDownCallSession()
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
            MXLog.info("[JunchatCall] suppress own empty call.member from widget")
            await postJSONToWidget(response)
            return
        }

        if let decodedMessage = try? DecodedWidgetMessage.decode(message: message) {
            if decodedMessage.isJunchatCallConnected {
                MXLog.info("[JunchatCall] widget reported remote media connected")
                await handleRemoteMediaConnectedIfNeeded()
                return
            }

            if timeoutTask != nil, decodedMessage.hasLoaded {
                // This means that the call room was joined succesfully, we can stop the timeout task
                MXLog.info("[JunchatCall] widget loaded")
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
            MXLog.info("[JunchatCall] suppress own empty call.member to widget")
            await widgetDriver.handleMessage(response)
        }
    }

    private nonisolated static func playDefaultCallConnectedTone() {
        AudioServicesPlaySystemSound(1104)
    }

    private nonisolated static func playDefaultCallEndedTone() {
        AudioServicesPlaySystemSound(1053)
    }

    private func completeCall() {
        guard !hasCompletedCall else {
            return
        }

        MXLog.info("[JunchatCall] completeCall")
        hasCompletedCall = true
        cleanUpLocalCallState()
        callEndedTonePlayer()
        actionsSubject.send(.dismiss)
    }

    private func setupCall() {
        setupTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            MXLog.info("[JunchatCall] setupCall start voice=\(configuration.voiceOnly) playConnectedTone=\(configuration.playConnectedTone)")

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
                guard !Task.isCancelled, !hasCleanedUpLocalCallState else { return }
                state.url = url
                callMediaCoordinator.pictureInPictureReadinessChanged()
            case .failure(let error):
                guard !Task.isCancelled, !hasCleanedUpLocalCallState else { return }
                MXLog.error("Failed starting ElementCall Widget Driver with \(CallDiagnostics.errorSummary(error))")
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: L10n.errorUnknown,
                                                 primaryButton: .init(title: L10n.actionOk) {
                                                     self.actionsSubject.send(.dismiss)
                                                 })
                return
            }

            guard !Task.isCancelled, !hasCleanedUpLocalCallState else { return }
            callMediaCoordinator.prepareForCall()

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

    private nonisolated static let nativeEarpieceID = "earpiece-id"
    private nonisolated static let nativeSpeakerID = "junchat-native-speaker"

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

    private nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return string
    }

    private func handleOutputDeviceSelected(deviceID: String) {
        let selectedOutput: CallAudioOutputSelection
        if deviceID == Self.nativeEarpieceID {
            selectedOutput = .nativeEarpiece
            MXLog.info("Selected native earpiece output")
        } else if deviceID == Self.nativeSpeakerID {
            selectedOutput = .nativeSpeaker
            MXLog.info("Selected native speaker output")
        } else {
            selectedOutput = .system
            MXLog.info("Selected system output device")
        }

        callMediaCoordinator.selectOutput(selectedOutput)
        logAudioSessionSnapshot(reason: "after output device selected")
    }

    private func handleCallMediaLifecycleEvent(_ event: CallMediaLifecycleEvent) async {
        guard !hasCompletedCall, !hasCleanedUpLocalCallState else { return }

        switch event {
        case .audioRouteChanged:
            await recoverPreferredVoiceOutputOnWeb(reason: "audio route changed")
        case .lifecycleRecovery(let reason):
            MXLog.info("[JunchatCall] recover call media after \(reason.rawValue)")
            logAudioSessionSnapshot(reason: "after lifecycle route recovery \(reason.rawValue)")
            await recoverPreferredVoiceOutputOnWeb(reason: reason.rawValue)
            guard !Task.isCancelled, !hasCleanedUpLocalCallState else { return }
            await setAudioEnabled(callMediaCoordinator.currentAudioEnabled)
            logAudioSessionSnapshot(reason: "after lifecycle web recovery \(reason.rawValue)")
        }
    }

    private func handleRemoteMediaConnectedIfNeeded() async {
        guard callMediaCoordinator.remoteMediaConnected() else { return }

        MXLog.info("[JunchatCall] remote media connected")
        logAudioSessionSnapshot(reason: "before remote media connected recovery")
        logAudioSessionSnapshot(reason: "after remote media connected recovery")
        await recoverPreferredVoiceOutputOnWeb(reason: "remote media connected")
        callMediaCoordinator.schedulePictureInPictureRecovery(reason: .remoteMediaConnected)
    }

    private func handleBackwardsNavigation() async {
        guard state.url != nil,
              isPictureInPictureAllowed else {
            actionsSubject.send(.dismiss)
            return
        }

        switch await requestPictureInPicture() {
        case .success:
            break
        case .failure:
            MXLog.warning("[JunchatCall] picture in picture did not start, keeping the call screen visible")
        }
    }

    private func startPictureInPictureForBackgrounding(_ recoveryAttempt: CallPictureInPictureRecoveryAttempt) async -> CallPictureInPictureAttemptResult {
        let reason = recoveryAttempt.reason.rawValue
        let attempt = recoveryAttempt.attempt
        logAudioSessionSnapshot(reason: "before PiP recovery attempt \(attempt) \(reason)")
        guard isPictureInPictureAllowed else {
            MXLog.info("[JunchatCall] skip picture in picture recovery reason=\(reason) attempt=\(attempt) hasURL=\(state.url != nil) hasHandler=\(state.bindings.requestPictureInPictureHandler != nil)")
            return .retry
        }
        guard state.url != nil,
              state.bindings.requestPictureInPictureHandler != nil else {
            MXLog.info("[JunchatCall] waiting for picture in picture readiness reason=\(reason) attempt=\(attempt) hasURL=\(state.url != nil) hasHandler=\(state.bindings.requestPictureInPictureHandler != nil)")
            return .waitingForReadiness
        }

        switch await requestPictureInPicture() {
        case .success:
            MXLog.info("[JunchatCall] started picture in picture recovery reason=\(reason) attempt=\(attempt)")
            logAudioSessionSnapshot(reason: "after successful PiP recovery attempt \(attempt) \(reason)")
            return .succeeded
        case .failure(.pictureInPictureTransitionInProgress):
            MXLog.info("[JunchatCall] waiting for picture in picture transition reason=\(reason) attempt=\(attempt)")
            return .waitingForTransition
        case .failure(let error):
            MXLog.warning("[JunchatCall] unable to start picture in picture recovery reason=\(reason) attempt=\(attempt) \(CallDiagnostics.errorSummary(error))")
            logAudioSessionSnapshot(reason: "after failed PiP recovery attempt \(attempt) \(reason)")
            return .retry
        }
    }

    private func logAudioSessionSnapshot(reason: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let availableInputs = session.availableInputs?.map(\.portType.rawValue).joined(separator: ",") ?? "nil"
        let appState = UIApplication.shared.applicationState.rawValue
        let snapshot = [
            "[JunchatCallAudio]",
            "reason=\(reason)",
            "appState=\(appState)",
            "category=\(session.category.rawValue)",
            "mode=\(session.mode.rawValue)",
            "options=\(session.categoryOptions.rawValue)",
            "outputs=[\(outputs)]",
            "inputs=[\(inputs)]",
            "availableInputs=[\(availableInputs)]",
            "secondarySilenced=\(session.secondaryAudioShouldBeSilencedHint)",
            "otherAudio=\(session.isOtherAudioPlaying)",
            "selectedNativeOutput=\(callMediaCoordinator.selectedOutput)",
            "remoteConnected=\(callMediaCoordinator.hasRemoteMediaConnected)",
            "audioEnabled=\(callMediaCoordinator.currentAudioEnabled)"
        ].joined(separator: " ")
        MXLog.info(snapshot)
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
            MXLog.error("Failed encoding widget message with \(CallDiagnostics.errorSummary(error))")
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
            MXLog.debug("Evaluated widget javascript \(CallDiagnostics.jsonSummary(json)) result=\(CallDiagnostics.valueSummary(result))")
        } catch {
            MXLog.error("Received javascript evaluation \(CallDiagnostics.errorSummary(error))")
        }
    }

    /// This function updates the list of available audio outputs on the web side
    /// however since we actually handle switching the audio output through the OS,
    /// this is only used to inform the webview when the speaker is selected,
    /// so that the option to use the earpiece can be displayed.
    private func recoverPreferredVoiceOutputOnWeb(reason: String) async {
        guard !hasCompletedCall, !hasCleanedUpLocalCallState else { return }
        await updateOutputsListOnWeb(forcePreferInitialEarpiece: true)

        guard configuration.voiceOnly,
              callMediaCoordinator.selectedOutput == .nativeEarpiece,
              let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first,
              currentOutput.portType == .builtInSpeaker || currentOutput.portType == .builtInReceiver else {
            return
        }

        callMediaCoordinator.restoreSelectedOutput()
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
            MXLog.info("[JunchatCall] recovered preferred voice output on web after \(reason) result=\(CallDiagnostics.valueSummary(result))")
        } catch {
            MXLog.error("[JunchatCall] failed recovering preferred voice output on web after \(reason) \(CallDiagnostics.errorSummary(error))")
        }

        logAudioSessionSnapshot(reason: "after preferred voice output web recovery \(reason)")
    }

    private func updateOutputsListOnWeb(forcePreferInitialEarpiece: Bool = false) async {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }

        let shouldApplyInitialVoiceOutputDevice = CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: configuration.voiceOnly,
                                                                                                           selectedOutput: callMediaCoordinator.selectedOutput,
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
            MXLog.debug("Evaluated audio output devices javascript result=\(CallDiagnostics.valueSummary(result))")
        } catch {
            MXLog.error("Received javascript evaluation \(CallDiagnostics.errorSummary(error))")
        }
    }
}
