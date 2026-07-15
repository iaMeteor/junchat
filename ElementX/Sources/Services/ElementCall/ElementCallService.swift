//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import CallKit
import Combine
import Foundation
import MatrixRustSDK
import PushKit
import UIKit

/// Keep this class testable
struct TimeProvider {
    var clock: any Clock<Duration>
    var now: () -> Date
}

#if targetEnvironment(simulator)
private let ignoresCallKitEndActionsByDefault = true
#else
private let ignoresCallKitEndActionsByDefault = false
#endif

@MainActor
class ElementCallService: NSObject, ElementCallServiceProtocol, @preconcurrency PKPushRegistryDelegate, @preconcurrency CXProviderDelegate {
    private struct CallID: Equatable {
        let callKitID: UUID
        let roomID: String
        let rtcNotificationID: String?
        let isVoiceCall: Bool

        var incomingCallIdentity: ElementCallIncomingCallIdentity {
            .init(callKitID: callKitID, roomID: roomID, isVoiceCall: isVoiceCall)
        }
    }

    private struct IncomingCallIdentity: Equatable {
        let callID: CallID
        let generation: UUID
    }

    private struct IncomingPushDetails {
        let roomID: String
        let rtcNotificationID: String
        let roomDisplayName: String?
        let isVoiceCall: Bool
        let ringDuration: Duration
    }

    private struct CallProviderAudioSessionDeactivationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let pushRegistry: PKPushRegistry
    private let callController = CXCallController()
    private var callProvider: CXProviderProtocol
    private let timeProvider: TimeProvider
    private let ignoresCallKitEndActions: Bool
    private let fulfillCallKitAction: @MainActor (CXAction) -> Void

    private weak var clientProxy: ClientProxyProtocol? {
        didSet {
            // There's a race condition where a call starts when the app has been killed and the
            // observation set in `incomingCallID` occurs *before* the user session is restored.
            // So observe when the client proxy is set to fix this (the method guards for the call).
            restartIncomingCallObservation()
        }
    }

    private var incomingCallRoomInfoCancellable: AnyCancellable?
    private var incomingCallObservationTask: Task<Void, Never>?
    private var incomingCallObservationRequestID = UUID()
    private var incomingCallGeneration = UUID()
    private var reportedIncomingCallKitIDs = Set<UUID>()
    private var callRingtoneCancellable: AnyCancellable?
    private var acceptedIncomingCallID: CallID?
    private var incomingCallID: CallID? {
        didSet {
            if let oldValue,
               let incomingCallID,
               oldValue.callKitID != incomingCallID.callKitID,
               reportedIncomingCallKitIDs.remove(oldValue.callKitID) != nil {
                callProvider.reportCall(with: oldValue.callKitID, endedAt: nil, reason: .remoteEnded)
            }

            incomingCallGeneration = UUID()
            endUnansweredCallTask?.cancel()
            endUnansweredCallTask = nil
            answerCallTask?.cancel()
            answerCallTask = nil
            MXLog.info("[JunchatCall] incomingCallID changed present=\(incomingCallID != nil) voice=\(incomingCallID?.isVoiceCall.description ?? "nil")")
            incomingCallRoomIDSubject.send(incomingCallID?.roomID)
            incomingCallIdentitySubject.send(incomingCallID?.incomingCallIdentity)
            restartIncomingCallObservation()
        }
    }

    private var endUnansweredCallTask: Task<Void, Never>?
    private var answerCallTask: Task<Void, Never>?
    private var callProviderAudioSessionDeactivationGeneration = UUID()
    private var callProviderAudioSessionDeactivationWaiter: CallProviderAudioSessionDeactivationWaiter?
    private var latestCallSessionGeneration: ElementCallSessionGeneration?
    private var ongoingCallSessionGeneration: ElementCallSessionGeneration?

    private var ongoingCallID: CallID? {
        didSet {
            MXLog.info("[JunchatCall] ongoingCallID changed present=\(ongoingCallID != nil) voice=\(ongoingCallID?.isVoiceCall.description ?? "nil")")
            ongoingCallRoomIDSubject.send(ongoingCallID?.roomID)
        }
    }

    let ongoingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)
    var ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> {
        ongoingCallRoomIDSubject.asCurrentValuePublisher()
    }

    let incomingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)
    var incomingCallRoomIDPublisher: CurrentValuePublisher<String?, Never> {
        incomingCallRoomIDSubject.asCurrentValuePublisher()
    }

    let incomingCallIdentitySubject = CurrentValueSubject<ElementCallIncomingCallIdentity?, Never>(nil)
    var incomingCallIdentityPublisher: CurrentValuePublisher<ElementCallIncomingCallIdentity?, Never> {
        incomingCallIdentitySubject.asCurrentValuePublisher()
    }

    var acceptedIncomingCallIdentity: ElementCallIncomingCallIdentity? {
        acceptedIncomingCallID?.incomingCallIdentity
    }

    private let actionsSubject: PassthroughSubject<ElementCallServiceAction, Never> = .init()
    var actions: AnyPublisher<ElementCallServiceAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var declineListenerHandle: TaskHandle?

    init(callProvider: CXProviderProtocol? = nil,
         timeProvider: TimeProvider? = nil,
         appSettings: AppSettings? = nil,
         ignoresCallKitEndActions: Bool = ignoresCallKitEndActionsByDefault,
         fulfillCallKitAction: @escaping @MainActor (CXAction) -> Void = { $0.fulfill() }) {
        pushRegistry = PKPushRegistry(queue: nil)

        self.timeProvider = timeProvider ?? TimeProvider(clock: ContinuousClock(), now: Date.init)
        self.ignoresCallKitEndActions = ignoresCallKitEndActions
        self.fulfillCallKitAction = fulfillCallKitAction

        if let callProvider {
            self.callProvider = callProvider
        } else {
            self.callProvider = CXProvider(configuration: Self.makeProviderConfiguration(ringtoneSoundName: appSettings?.callRingtoneSoundName ?? JunchatCallRingtone.classic.rawValue))
        }

        super.init()

        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]

        self.callProvider.setDelegate(self, queue: nil)

        if callProvider == nil {
            callRingtoneCancellable = appSettings?.$callRingtoneSoundName
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] ringtoneSoundName in
                    self?.updateCallProvider(ringtoneSoundName: ringtoneSoundName)
                }
        }
    }

    static func makeProviderConfiguration(ringtoneSoundName: String) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.includesCallsInRecents = true
        configuration.ringtoneSound = JunchatCallRingtone.ringtone(for: ringtoneSoundName).soundName

        if let callKitIcon = UIImage(named: "images/app-logo") {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }

        // https://stackoverflow.com/a/46077628/730924
        configuration.supportedHandleTypes = [.generic]

        return configuration
    }

    func setClientProxy(_ clientProxy: any ClientProxyProtocol) {
        self.clientProxy = clientProxy
    }

    func registerCallSession(generation: ElementCallSessionGeneration) {
        latestCallSessionGeneration = generation
    }

    func setupCallSession(roomID: String,
                          roomDisplayName: String,
                          incomingCallIdentity: ElementCallIncomingCallIdentity?,
                          generation: ElementCallSessionGeneration) async {
        guard latestCallSessionGeneration == generation else {
            MXLog.info("[JunchatCall] ignoring superseded call session setup")
            return
        }

        let callID: CallID
        if let incomingCallIdentity {
            guard let acceptedIncomingCallID,
                  acceptedIncomingCallID.incomingCallIdentity == incomingCallIdentity,
                  acceptedIncomingCallID.roomID == roomID else {
                MXLog.info("[JunchatCall] ignoring setup for a superseded accepted call")
                return
            }
            callID = acceptedIncomingCallID
        } else {
            callID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil, isVoiceCall: false)
        }

        MXLog.info("[JunchatCall] setupCallSession accepted=\(incomingCallIdentity != nil) hasOngoing=\(ongoingCallID != nil)")

        // Drop any ongoing calls when starting a new one
        if ongoingCallID != nil {
            ongoingCallSessionGeneration = nil
            tearDownOngoingCallSession(sendEndCallAction: true)
        }

        if incomingCallIdentity != nil {
            acceptedIncomingCallID = nil
        }
        guard latestCallSessionGeneration == generation else {
            return
        }
        ongoingCallSessionGeneration = generation
        ongoingCallID = callID

        // Don't bother starting another CallKit session as it won't work properly
        // https://developer.apple.com/forums//thread/767949?answerId=812951022#812951022

        // let handle = CXHandle(type: .generic, value: roomDisplayName)
        // let startCallAction = CXStartCallAction(call: callID.callKitID, handle: handle)
        // startCallAction.isVideo = true

        // do {
        //     try await callController.request(CXTransaction(action: startCallAction))
        // } catch {
        //     MXLog.error("Failed requesting start call action: \(CallDiagnostics.errorSummary(error))")
        // }
    }

    func tearDownCallSession() {
        latestCallSessionGeneration = nil
        ongoingCallSessionGeneration = nil
        tearDownCallSession(sendEndCallAction: true)
    }

    func tearDownCallSession(generation: ElementCallSessionGeneration) {
        if latestCallSessionGeneration == generation {
            latestCallSessionGeneration = nil
            ongoingCallSessionGeneration = nil
            tearDownCallSession(sendEndCallAction: true)
            return
        }

        guard ongoingCallSessionGeneration == generation else {
            return
        }

        ongoingCallSessionGeneration = nil
        tearDownOngoingCallSession(sendEndCallAction: true)
    }

    func acceptIncomingCall(roomID: String,
                            isVoiceCall: Bool,
                            incomingCallIdentity: ElementCallIncomingCallIdentity?) async -> ElementCallIncomingCallIdentity? {
        guard let incomingCallIdentity else {
            guard incomingCallID == nil else {
                MXLog.info("[JunchatCall] refusing foreground accept while a push-backed call is tracked")
                return nil
            }

            MXLog.info("[JunchatCall] accepting foreground synced call voice=\(isVoiceCall)")
            let acceptedCallID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil, isVoiceCall: isVoiceCall)
            acceptedIncomingCallID = acceptedCallID
            return acceptedCallID.incomingCallIdentity
        }

        guard let trackedIncomingCallIdentity = currentIncomingCallIdentity,
              trackedIncomingCallIdentity.callID.incomingCallIdentity == incomingCallIdentity,
              trackedIncomingCallIdentity.callID.roomID == roomID else {
            MXLog.info("Incoming call identity does not match accept request")
            return nil
        }

        let incomingCallID = trackedIncomingCallIdentity.callID
        endUnansweredCallTask?.cancel()
        endUnansweredCallTask = nil
        declineListenerHandle?.cancel()
        declineListenerHandle = nil
        acceptedIncomingCallID = incomingCallID
        MXLog.info("[JunchatCall] acceptIncomingCall stopping CallKit ring")
        reportedIncomingCallKitIDs.remove(incomingCallID.callKitID)
        callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)
        clearIncomingCall(ifMatches: trackedIncomingCallIdentity)
        return incomingCallID.incomingCallIdentity
    }

    func declineIncomingCall(roomID: String) async {
        guard let incomingCallIdentity = currentIncomingCallIdentity else {
            MXLog.info("No incoming call to decline.")
            return
        }

        let incomingCallID = incomingCallIdentity.callID
        guard incomingCallID.roomID == roomID else {
            MXLog.info("Incoming call room does not match decline request")
            return
        }

        await sendDeclineCallEvent(incomingCallID)
        reportEndedCall(incomingCallIdentity: incomingCallIdentity, reason: .declinedElsewhere)
    }

    func declineIncomingCall(incomingCallIdentity: ElementCallIncomingCallIdentity) async {
        guard let trackedIncomingCallIdentity = currentIncomingCallIdentity,
              trackedIncomingCallIdentity.callID.incomingCallIdentity == incomingCallIdentity else {
            MXLog.info("Incoming call identity does not match decline request")
            return
        }

        await sendDeclineCallEvent(trackedIncomingCallIdentity.callID)
        reportEndedCall(incomingCallIdentity: trackedIncomingCallIdentity, reason: .declinedElsewhere)
    }

    func clearAcceptedIncomingCall(incomingCallIdentity: ElementCallIncomingCallIdentity) {
        guard acceptedIncomingCallID?.incomingCallIdentity == incomingCallIdentity else { return }
        acceptedIncomingCallID = nil
    }

    func setAudioEnabled(_ enabled: Bool, roomID: String) {
        guard let ongoingCallID else {
            MXLog.error("Failed toggling call microphone, no calls running")
            return
        }

        guard ongoingCallID.roomID == roomID else {
            MXLog.error("Failed toggling call microphone, rooms don't match")
            return
        }

        let transaction = CXTransaction(action: CXSetMutedCallAction(call: ongoingCallID.callKitID, muted: !enabled))
        callController.request(transaction) { error in
            if let error {
                MXLog.error("Failed toggling call microphone: \(CallDiagnostics.errorSummary(error))")
            }
        }
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) { }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard let details = incomingPushDetails(from: payload) else {
            completion()
            return
        }

        guard ongoingCallID?.roomID != details.roomID else {
            MXLog.warning("Call already ongoing, ignoring incoming push")
            completion()
            return
        }

        let callID = CallID(callKitID: UUID(),
                            roomID: details.roomID,
                            rtcNotificationID: details.rtcNotificationID,
                            isVoiceCall: details.isVoiceCall)
        acceptedIncomingCallID = nil
        incomingCallID = callID
        guard let incomingCallIdentity = currentIncomingCallIdentity else {
            completion()
            return
        }

        let update = CXCallUpdate()
        // Work Around: Always set video to true! https://github.com/element-hq/element-x-ios/issues/5335
        // If not for audio call the app will not be put to foreground and the webview won't be able to handle the call...
        // Consequence: The call will be presented to the user as a video call in CallKit UI,
        // but once Element Call is launched it will correctly route to a voice-only call.
        update.hasVideo = true
        update.localizedCallerName = details.roomDisplayName
        // https://stackoverflow.com/a/41230020/730924
        update.remoteHandle = .init(type: .generic, value: details.roomID)

        endUnansweredCallTask = Task { [weak self] in
            try? await self?.timeProvider.clock.sleep(for: details.ringDuration)

            guard let self, !Task.isCancelled else {
                return
            }

            reportEndedCall(incomingCallIdentity: incomingCallIdentity, reason: .unanswered)
        }

        callProvider.reportNewIncomingCall(with: callID.callKitID, update: update) { [weak self] error in
            completion()
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                guard isCurrentIncomingCall(incomingCallIdentity) else {
                    if error == nil {
                        callProvider.reportCall(with: callID.callKitID, endedAt: nil, reason: .remoteEnded)
                    }
                    return
                }

                if let error {
                    MXLog.error("Failed reporting new incoming call: \(CallDiagnostics.errorSummary(error))")
                    reportedIncomingCallKitIDs.remove(callID.callKitID)
                    clearIncomingCall(ifMatches: incomingCallIdentity)
                    return
                }

                reportedIncomingCallKitIDs.insert(callID.callKitID)
                actionsSubject.send(.receivedIncomingCallRequest)
            }
        }
    }

    // MARK: - CXProviderDelegate

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did activate audio session")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did deactivate audio session")
        callProviderAudioSessionDeactivationGeneration = UUID()
        resumeCallProviderAudioSessionDeactivationWaiter(result: true)
    }

    func providerDidReset(_ provider: CXProvider) {
        MXLog.info("Call provider did reset")
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let incomingCallIdentity = currentIncomingCallIdentity,
              incomingCallIdentity.callID.callKitID == action.callUUID else {
            MXLog.warning("Ignoring CallKit answer for a superseded call")
            fulfillCallKitAction(action)
            return
        }

        let incomingCallID = incomingCallIdentity.callID
        MXLog.info("[JunchatCall] CallKit answer voice=\(incomingCallID.isVoiceCall)")

        // Fixes broken videos on EC web when a CallKit session is established.
        //
        // Reporting an ongoing call through `reportNewIncomingCall` + `CXAnswerCallAction`
        // or `reportOutgoingCall:connectedAt:` will give exclusive access for media to the
        // ongoing process, which is different from the process WKWebView is running in, making EC
        // unable to acquire media streams.
        // Reporting the call as ended after answering it works around that as EC gets access to
        // media again and EX builds the right UI in `setupCallSession`.
        //
        // https://developer.apple.com/forums//thread/767949?answerId=812951022#812951022
        //
        // https://github.com/element-hq/element-x-ios/issues/3041
        // https://forums.developer.apple.com/forums/thread/685268
        // https://stackoverflow.com/questions/71483732/webrtc-running-from-wkwebview-avaudiosession-development-roadblock

        // First fulfill the action
        fulfillCallKitAction(action)

        // And delay ending the call so that the app has enough time to get deep-linked into.
        answerCallTask?.cancel()
        resumeCallProviderAudioSessionDeactivationWaiter(result: false)
        answerCallTask = Task { @MainActor [weak self] in
            try? await self?.timeProvider.clock.sleep(for: .seconds(1))

            guard let self,
                  !Task.isCancelled,
                  isCurrentIncomingCall(incomingCallIdentity) else {
                return
            }

            // Then end CallKit ownership and wait for its audio session to be released before
            // asking WKWebView to acquire the camera and microphone.
            let audioSessionDeactivationGeneration = callProviderAudioSessionDeactivationGeneration
            reportedIncomingCallKitIDs.remove(incomingCallID.callKitID)
            callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)

            let didDeactivate = await waitForCallProviderAudioSessionDeactivation(after: audioSessionDeactivationGeneration)
            guard !Task.isCancelled,
                  isCurrentIncomingCall(incomingCallIdentity) else {
                return
            }

            if !didDeactivate {
                MXLog.warning("[JunchatCall] CallKit audio session deactivation timed out")
            }

            acceptedIncomingCallID = incomingCallID
            clearIncomingCall(ifMatches: incomingCallIdentity)
            actionsSubject.send(.startCall(roomID: incomingCallID.roomID,
                                           isVoiceCall: incomingCallID.isVoiceCall,
                                           incomingCallIdentity: incomingCallID.incomingCallIdentity))
        }
    }

    private func waitForCallProviderAudioSessionDeactivation(after generation: UUID) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }

                guard callProviderAudioSessionDeactivationGeneration == generation else {
                    continuation.resume(returning: true)
                    return
                }

                let timeoutTask = Task { @MainActor [weak self] in
                    try? await self?.timeProvider.clock.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    resumeCallProviderAudioSessionDeactivationWaiter(id: waiterID, result: false)
                }
                callProviderAudioSessionDeactivationWaiter = .init(id: waiterID,
                                                                    continuation: continuation,
                                                                    timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeCallProviderAudioSessionDeactivationWaiter(id: waiterID, result: false)
            }
        }
    }

    private func resumeCallProviderAudioSessionDeactivationWaiter(id: UUID? = nil, result: Bool) {
        guard let waiter = callProviderAudioSessionDeactivationWaiter,
              id == nil || waiter.id == id else {
            return
        }

        callProviderAudioSessionDeactivationWaiter = nil
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let ongoingCallID, ongoingCallID.callKitID == action.callUUID {
            actionsSubject.send(.setAudioEnabled(!action.isMuted, roomID: ongoingCallID.roomID))
        } else if ongoingCallID != nil {
            MXLog.warning("Ignoring CallKit mute for a superseded call")
        } else {
            MXLog.error("Failed muting/unmuting call, missing ongoingCallID")
        }

        fulfillCallKitAction(action)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let ongoingCallID, ongoingCallID.callKitID == action.callUUID {
            guard !ignoresCallKitEndActions else {
                fulfillCallKitAction(action)
                return
            }

            actionsSubject.send(.endCall(roomID: ongoingCallID.roomID))
            if latestCallSessionGeneration == ongoingCallSessionGeneration {
                latestCallSessionGeneration = nil
            }
            ongoingCallSessionGeneration = nil
            tearDownOngoingCallSession(sendEndCallAction: false)
            fulfillCallKitAction(action)
            return
        }

        if let incomingCallIdentity = currentIncomingCallIdentity,
           incomingCallIdentity.callID.callKitID == action.callUUID {
            guard !ignoresCallKitEndActions else {
                fulfillCallKitAction(action)
                return
            }

            clearIncomingCall(ifMatches: incomingCallIdentity)
            reportedIncomingCallKitIDs.remove(incomingCallIdentity.callID.callKitID)
            Task {
                await sendDeclineCallEvent(incomingCallIdentity.callID)
            }
            fulfillCallKitAction(action)
            return
        }

        if let acceptedIncomingCallID, acceptedIncomingCallID.callKitID == action.callUUID {
            guard !ignoresCallKitEndActions else {
                fulfillCallKitAction(action)
                return
            }

            self.acceptedIncomingCallID = nil
            Task {
                await sendDeclineCallEvent(acceptedIncomingCallID)
            }
            fulfillCallKitAction(action)
            return
        }

        MXLog.warning("Ignoring CallKit end for a superseded call")
        fulfillCallKitAction(action)
    }

    // MARK: - Private

    private func incomingPushDetails(from payload: PKPushPayload) -> IncomingPushDetails? {
        let dictionary = payload.dictionaryPayload
        guard let roomID = dictionary[ElementCallServiceNotificationKey.roomID.rawValue] as? String,
              !roomID.isEmpty else {
            MXLog.error("Missing room identifier for incoming voip call: \(CallDiagnostics.dictionarySummary(dictionary))")
            return nil
        }

        guard let rtcNotificationID = dictionary[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] as? String,
              !rtcNotificationID.isEmpty else {
            MXLog.error("Missing rtc notification event identifier for incoming voip call: \(CallDiagnostics.dictionarySummary(dictionary))")
            return nil
        }

        guard let expirationDate = dictionary[ElementCallServiceNotificationKey.expirationDate.rawValue] as? Date else {
            MXLog.error("Missing expiration timestamp for incoming voip call: \(CallDiagnostics.dictionarySummary(dictionary))")
            return nil
        }

        let now = timeProvider.now()
        guard now < expirationDate else {
            MXLog.warning("Call expired, ignoring incoming push")
            return nil
        }

        return IncomingPushDetails(roomID: roomID,
                                   rtcNotificationID: rtcNotificationID,
                                   roomDisplayName: dictionary[ElementCallServiceNotificationKey.roomDisplayName.rawValue] as? String,
                                   isVoiceCall: dictionary[ElementCallServiceNotificationKey.isVoiceCall.rawValue] as? Bool ?? false,
                                   ringDuration: .seconds(min(expirationDate.timeIntervalSince1970 - now.timeIntervalSince1970, 90)))
    }

    private var currentIncomingCallIdentity: IncomingCallIdentity? {
        guard let incomingCallID else { return nil }
        return IncomingCallIdentity(callID: incomingCallID, generation: incomingCallGeneration)
    }

    private func isCurrentIncomingCall(_ identity: IncomingCallIdentity) -> Bool {
        currentIncomingCallIdentity == identity
    }

    private func restartIncomingCallObservation() {
        incomingCallObservationRequestID = UUID()
        let requestID = incomingCallObservationRequestID

        incomingCallObservationTask?.cancel()
        incomingCallObservationTask = nil
        incomingCallRoomInfoCancellable = nil
        declineListenerHandle?.cancel()
        declineListenerHandle = nil

        guard let incomingCallIdentity = currentIncomingCallIdentity else {
            return
        }

        incomingCallObservationTask = Task { [weak self] in
            await self?.observeIncomingCall(incomingCallIdentity: incomingCallIdentity, requestID: requestID)
        }
    }

    private func tearDownCallSession(sendEndCallAction: Bool = true) {
        MXLog.info("[JunchatCall] tearDownCallSession sendEndCallAction=\(sendEndCallAction) hasOngoing=\(ongoingCallID != nil) hasIncoming=\(incomingCallID != nil)")

        tearDownOngoingCallSession(sendEndCallAction: sendEndCallAction)
    }

    private func tearDownOngoingCallSession(sendEndCallAction: Bool) {
        if sendEndCallAction, let ongoingCallID {
            let transaction = CXTransaction(action: CXEndCallAction(call: ongoingCallID.callKitID))
            callController.request(transaction) { error in
                if let error {
                    MXLog.error("Failed transaction: \(CallDiagnostics.errorSummary(error))")
                }
            }
        }

        ongoingCallID = nil
    }

    private func sendDeclineCallEvent(_ incomingCallID: CallID) async {
        guard let rtcNotificationID = incomingCallID.rtcNotificationID else {
            MXLog.info("No rtc notification event to decline.")
            return
        }

        guard let clientProxy else {
            MXLog.warning("A ClientProxy is needed to fetch the room.")
            return
        }

        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(incomingCallID.roomID) else {
            MXLog.warning("Failed to fetch a joined room for the incoming call.")
            return
        }

        _ = await roomProxy.declineCall(notificationID: rtcNotificationID)
    }

    private func updateCallProvider(ringtoneSoundName: String) {
        guard incomingCallID == nil, ongoingCallID == nil else {
            MXLog.info("Delaying CallKit ringtone update until calls are idle.")
            return
        }

        callProvider = CXProvider(configuration: Self.makeProviderConfiguration(ringtoneSoundName: ringtoneSoundName))
        callProvider.setDelegate(self, queue: nil)
    }

    private func observeIncomingCall(incomingCallIdentity: IncomingCallIdentity, requestID: UUID) async {
        guard let clientProxy else {
            MXLog.warning("A ClientProxy is needed to fetch the room.")
            return
        }

        let incomingCallID = incomingCallIdentity.callID
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(incomingCallID.roomID) else {
            MXLog.warning("Failed to fetch a joined room for the incoming call.")
            return
        }

        guard isCurrentIncomingCall(incomingCallIdentity),
              incomingCallObservationRequestID == requestID else {
            return
        }

        roomProxy.subscribeToRoomInfoUpdates()
        let roomInfoCancellable = makeIncomingCallRoomInfoCancellable(roomProxy: roomProxy,
                                                                      incomingCallIdentity: incomingCallIdentity,
                                                                      requestID: requestID)

        guard isCurrentIncomingCall(incomingCallIdentity),
              incomingCallObservationRequestID == requestID else {
            roomInfoCancellable.cancel()
            return
        }
        incomingCallRoomInfoCancellable = roomInfoCancellable

        guard let rtcNotificationID = incomingCallID.rtcNotificationID else {
            MXLog.warning("Decline: No RTC notification ID found for the incoming call.")
            return
        }

        MXLog.info("Observe decline events for incoming call")
        let listener = makeIncomingCallDeclineListener(roomProxy: roomProxy,
                                                       incomingCallIdentity: incomingCallIdentity,
                                                       requestID: requestID)

        guard case let .success(handle) = roomProxy.subscribeToCallDeclineEvents(rtcNotificationEventID: rtcNotificationID, listener: listener) else {
            MXLog.error("Unable to listen for decline events.")
            return
        }

        guard isCurrentIncomingCall(incomingCallIdentity),
              incomingCallObservationRequestID == requestID else {
            handle.cancel()
            return
        }
        declineListenerHandle = handle
    }

    private func makeIncomingCallRoomInfoCancellable(roomProxy: any JoinedRoomProxyProtocol,
                                                     incomingCallIdentity: IncomingCallIdentity,
                                                     requestID: UUID) -> AnyCancellable {
        roomProxy
            .infoPublisher
            .compactMap { ($0.hasRoomCall, $0.activeRoomCallParticipants) }
            .removeDuplicates { $0 == $1 }
            .drop { hasRoomCall, _ in
                // Ignore updates until a call exists so a later `false` means the caller hung up.
                !hasRoomCall
            }
            .sink { [weak self] hasOngoingCall, activeRoomCallParticipants in
                guard let self,
                      isCurrentIncomingCall(incomingCallIdentity),
                      incomingCallObservationRequestID == requestID else { return }

                let participants: [String] = activeRoomCallParticipants
                if !hasOngoingCall {
                    MXLog.info("Call cancelled by remote")
                    reportEndedCall(incomingCallIdentity: incomingCallIdentity, reason: .remoteEnded)
                } else if participants.contains(roomProxy.ownUserID) {
                    MXLog.info("Call answered elsewhere")
                    reportEndedCall(incomingCallIdentity: incomingCallIdentity, reason: .answeredElsewhere)
                }
            }
    }

    private func makeIncomingCallDeclineListener(roomProxy: any JoinedRoomProxyProtocol,
                                                 incomingCallIdentity: IncomingCallIdentity,
                                                 requestID: UUID) -> CallDeclineListener {
        SDKListener { [weak self] senderID in
            guard let self,
                  isCurrentIncomingCall(incomingCallIdentity),
                  incomingCallObservationRequestID == requestID else { return }

            MXLog.debug("Call declined event received")
            guard senderID == roomProxy.ownUserID else { return }

            MXLog.debug("Call declined elsewhere")
            reportEndedCall(incomingCallIdentity: incomingCallIdentity, reason: .declinedElsewhere)
        }
    }

    private func reportEndedCall(incomingCallIdentity: IncomingCallIdentity, reason: CXCallEndedReason) {
        guard isCurrentIncomingCall(incomingCallIdentity) else {
            MXLog.info("[JunchatCall] ignoring ended callback for superseded incoming call")
            return
        }

        MXLog.info("[JunchatCall] reportEndedCall reason=\(reason.rawValue)")
        reportedIncomingCallKitIDs.remove(incomingCallIdentity.callID.callKitID)
        callProvider.reportCall(with: incomingCallIdentity.callID.callKitID, endedAt: nil, reason: reason)
        clearIncomingCall(ifMatches: incomingCallIdentity)
    }

    private func clearIncomingCall(ifMatches incomingCallIdentity: IncomingCallIdentity) {
        guard isCurrentIncomingCall(incomingCallIdentity) else {
            MXLog.info("[JunchatCall] ignoring clear for superseded incoming call")
            return
        }

        incomingCallID = nil
    }
}
