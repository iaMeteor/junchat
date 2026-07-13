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

class ElementCallService: NSObject, ElementCallServiceProtocol, PKPushRegistryDelegate, CXProviderDelegate {
    private struct CallID: Equatable {
        let callKitID: UUID
        let roomID: String
        let rtcNotificationID: String?
        let isVoiceCall: Bool
    }

    private let pushRegistry: PKPushRegistry
    private let callController = CXCallController()
    private var callProvider: CXProviderProtocol
    private let timeProvider: TimeProvider

    private weak var clientProxy: ClientProxyProtocol? {
        didSet {
            // There's a race condition where a call starts when the app has been killed and the
            // observation set in `incomingCallID` occurs *before* the user session is restored.
            // So observe when the client proxy is set to fix this (the method guards for the call).
            Task { await observeIncomingCall() }
        }
    }

    private var incomingCallRoomInfoCancellable: AnyCancellable?
    private var callRingtoneCancellable: AnyCancellable?
    private var acceptedIncomingCallID: CallID?
    private var incomingCallID: CallID? {
        didSet {
            MXLog.info("[JunchatCall] incomingCallID changed present=\(incomingCallID != nil) voice=\(incomingCallID?.isVoiceCall.description ?? "nil")")
            incomingCallRoomIDSubject.send(incomingCallID?.roomID)
            Task { await observeIncomingCall() }
        }
    }

    private var endUnansweredCallTask: Task<Void, Never>?

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

    private let actionsSubject: PassthroughSubject<ElementCallServiceAction, Never> = .init()
    var actions: AnyPublisher<ElementCallServiceAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var declineListenerHandle: TaskHandle?

    init(callProvider: CXProviderProtocol? = nil, timeProvider: TimeProvider? = nil, appSettings: AppSettings? = nil) {
        pushRegistry = PKPushRegistry(queue: nil)

        self.timeProvider = timeProvider ?? TimeProvider(clock: ContinuousClock(), now: Date.init)

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

    func setupCallSession(roomID: String, roomDisplayName: String) async {
        MXLog.info("[JunchatCall] setupCallSession hasIncoming=\(incomingCallID?.roomID == roomID) hasAccepted=\(acceptedIncomingCallID?.roomID == roomID) hasOngoing=\(ongoingCallID != nil)")

        // Drop any ongoing calls when starting a new one
        if ongoingCallID != nil {
            tearDownCallSession()
        }

        // If this starting from a ring reuse those identifiers
        // Make sure the roomID matches
        let isAnsweringIncomingCall = incomingCallID?.roomID == roomID
        let acceptedCallID = acceptedIncomingCallID?.roomID == roomID ? acceptedIncomingCallID : nil
        let callID = if let incomingCallID, incomingCallID.roomID == roomID {
            incomingCallID
        } else if let acceptedCallID {
            acceptedCallID
        } else {
            CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil, isVoiceCall: false)
        }

        if isAnsweringIncomingCall {
            endUnansweredCallTask?.cancel()
            endUnansweredCallTask = nil
            declineListenerHandle?.cancel()
            declineListenerHandle = nil
            MXLog.info("[JunchatCall] ending CallKit incoming ring for accepted call")
            callProvider.reportCall(with: callID.callKitID, endedAt: nil, reason: .remoteEnded)
        }

        incomingCallID = nil
        if acceptedCallID != nil {
            acceptedIncomingCallID = nil
        }
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
        tearDownCallSession(sendEndCallAction: true)
    }

    func acceptIncomingCall(roomID: String, isVoiceCall: Bool) async {
        guard let incomingCallID else {
            MXLog.info("[JunchatCall] accepting foreground synced call voice=\(isVoiceCall)")
            acceptedIncomingCallID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: nil, isVoiceCall: isVoiceCall)
            return
        }

        guard incomingCallID.roomID == roomID else {
            MXLog.info("Incoming call room does not match accept request")
            return
        }

        endUnansweredCallTask?.cancel()
        endUnansweredCallTask = nil
        declineListenerHandle?.cancel()
        declineListenerHandle = nil
        acceptedIncomingCallID = incomingCallID
        MXLog.info("[JunchatCall] acceptIncomingCall stopping CallKit ring")
        callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)
        self.incomingCallID = nil
    }

    func declineIncomingCall(roomID: String) async {
        guard let incomingCallID else {
            MXLog.info("No incoming call to decline.")
            return
        }

        guard incomingCallID.roomID == roomID else {
            MXLog.info("Incoming call room does not match decline request")
            return
        }

        await sendDeclineCallEvent(incomingCallID)
        reportEndedCall(incomingCallID: incomingCallID, reason: .declinedElsewhere)
        self.incomingCallID = nil
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
        guard let roomID = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomID.rawValue] as? String else {
            MXLog.error("Missing room identifier for incoming voip call: \(CallDiagnostics.dictionarySummary(payload.dictionaryPayload))")
            completion()
            return
        }

        guard let rtcNotificationID = payload.dictionaryPayload[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] as? String else {
            MXLog.error("Missing rtc notification event identifier for incoming voip call: \(CallDiagnostics.dictionarySummary(payload.dictionaryPayload))")
            completion()
            return
        }

        guard ongoingCallID?.roomID != roomID else {
            MXLog.warning("Call already ongoing, ignoring incoming push")
            completion()
            return
        }

        let isVoiceCall = payload.dictionaryPayload[ElementCallServiceNotificationKey.isVoiceCall.rawValue] as? Bool ?? false

        let callID = CallID(callKitID: UUID(), roomID: roomID, rtcNotificationID: rtcNotificationID, isVoiceCall: isVoiceCall)
        incomingCallID = callID

        guard let expirationDate = (payload.dictionaryPayload[ElementCallServiceNotificationKey.expirationDate.rawValue] as? Date) else {
            MXLog.error("Missing expiration timestamp for incoming voip call: \(CallDiagnostics.dictionarySummary(payload.dictionaryPayload))")
            completion()
            return
        }

        let nowDate = timeProvider.now()

        guard nowDate < expirationDate else {
            MXLog.warning("Call expired, ignoring incoming push")
            completion()
            return
        }

        let ringDuration: Duration = .seconds(min(expirationDate.timeIntervalSince1970 - nowDate.timeIntervalSince1970, 90))

        let roomDisplayName = payload.dictionaryPayload[ElementCallServiceNotificationKey.roomDisplayName.rawValue] as? String

        let update = CXCallUpdate()
        // Work Around: Always set video to true! https://github.com/element-hq/element-x-ios/issues/5335
        // If not for audio call the app will not be put to foreground and the webview won't be able to handle the call...
        // Consequence: The call will be presented to the user as a video call in CallKit UI,
        // but once Element Call is launched it will correctly route to a voice-only call.
        update.hasVideo = true
        update.localizedCallerName = roomDisplayName
        // https://stackoverflow.com/a/41230020/730924
        update.remoteHandle = .init(type: .generic, value: roomID)

        callProvider.reportNewIncomingCall(with: callID.callKitID, update: update) { [weak self] error in
            if let error {
                MXLog.error("Failed reporting new incoming call: \(CallDiagnostics.errorSummary(error))")
            }

            self?.actionsSubject.send(.receivedIncomingCallRequest)

            completion()
        }

        endUnansweredCallTask = Task { [weak self] in
            try? await self?.timeProvider.clock.sleep(for: ringDuration)

            guard let self, !Task.isCancelled else {
                return
            }

            if let incomingCallID, incomingCallID.callKitID == callID.callKitID {
                reportEndedCall(incomingCallID: incomingCallID, reason: .unanswered)
            }
        }
    }

    // MARK: - CXProviderDelegate

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did activate audio session")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MXLog.info("Call provider did deactivate audio session")
    }

    func providerDidReset(_ provider: CXProvider) {
        MXLog.info("Call provider did reset")
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let incomingCallID else {
            MXLog.error("Failed answering incoming call, missing incomingCallID")
            return
        }

        MXLog.info("[JunchatCall] CallKit answer voice=\(incomingCallID.isVoiceCall)")

        // Fixes broken videos on EC web when a CallKit session is established.
        //
        // Reporting an ongoing call through `reportNewIncomingCall` + `CXAnswerCallAction`
        // or `reportOutgoingCall:connectedAt:` will give exclusive access for media to the
        // ongoing process, which is different than the WKWebKit is running on, making EC
        // unable to aquire media streams.
        // Reporting the call as ended imediately after answering it works around that
        // as EC gets access to media again and EX builds the right UI in `setupCallSession`
        //
        // https://developer.apple.com/forums//thread/767949?answerId=812951022#812951022
        //
        // https://github.com/element-hq/element-x-ios/issues/3041
        // https://forums.developer.apple.com/forums/thread/685268
        // https://stackoverflow.com/questions/71483732/webrtc-running-from-wkwebview-avaudiosession-development-roadblock

        // First fullfill the action
        action.fulfill()

        // And delay ending the call so that the app has enough time
        // to get deeplinked into
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Then end the and call rely on `setupCallSession` to create a new one
            provider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)

            self.actionsSubject.send(.startCall(roomID: incomingCallID.roomID, isVoiceCall: incomingCallID.isVoiceCall))
            self.endUnansweredCallTask?.cancel()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let ongoingCallID {
            actionsSubject.send(.setAudioEnabled(!action.isMuted, roomID: ongoingCallID.roomID))
        } else {
            MXLog.error("Failed muting/unmuting call, missing ongoingCallID")
        }

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if targetEnvironment(simulator)
        // This gets called for no reason on simulators, where CallKit
        // isn't even supported, ignore it.
        #else
        if let ongoingCallID {
            actionsSubject.send(.endCall(roomID: ongoingCallID.roomID))
        }

        if let incomingCallID {
            Task {
                await sendDeclineCallEvent(incomingCallID)
            }
        }

        tearDownCallSession(sendEndCallAction: false)

        action.fulfill()
        #endif
    }

    // MARK: - Private

    private func tearDownCallSession(sendEndCallAction: Bool = true) {
        MXLog.info("[JunchatCall] tearDownCallSession sendEndCallAction=\(sendEndCallAction) hasOngoing=\(ongoingCallID != nil) hasIncoming=\(incomingCallID != nil)")

        if sendEndCallAction, let ongoingCallID {
            let transaction = CXTransaction(action: CXEndCallAction(call: ongoingCallID.callKitID))
            callController.request(transaction) { error in
                if let error {
                    MXLog.error("Failed transaction: \(CallDiagnostics.errorSummary(error))")
                }
            }
        }

        ongoingCallID = nil
        incomingCallID = nil
        acceptedIncomingCallID = nil
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

    private func observeIncomingCall() async {
        incomingCallRoomInfoCancellable = nil

        guard let incomingCallID else {
            MXLog.info("No incoming call to observe for.")
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

        roomProxy.subscribeToRoomInfoUpdates()

        incomingCallRoomInfoCancellable = roomProxy
            .infoPublisher
            .compactMap { ($0.hasRoomCall, $0.activeRoomCallParticipants) }
            .removeDuplicates { $0 == $1 }
            .drop { hasRoomCall, _ in
                // Filter all updates before hasRoomCall becomes `true`. Then we can correctly
                // detect its change to `false` to stop ringing when the caller hangs up.
                !hasRoomCall
            }
            .sink { [weak self] hasOngoingCall, activeRoomCallParticipants in
                guard let self else { return }

                let participants: [String] = activeRoomCallParticipants

                if !hasOngoingCall {
                    MXLog.info("Call cancelled by remote")
                    reportEndedCall(incomingCallID: incomingCallID, reason: .remoteEnded)
                } else if participants.contains(roomProxy.ownUserID) {
                    MXLog.info("Call answered elsewhere")
                    reportEndedCall(incomingCallID: incomingCallID, reason: .answeredElsewhere)
                }
            }

        guard let rtcNotificationID = incomingCallID.rtcNotificationID else {
            MXLog.warning("Decline: No RTC notification ID found for the incoming call.")
            return
        }

        MXLog.info("Observe decline events for incoming call")

        let listener: CallDeclineListener = SDKListener { [weak self] senderID in
            guard let self else { return }

            MXLog.debug("Call declined event received")

            if senderID == roomProxy.ownUserID {
                // Stop ringing!
                MXLog.debug("Call declined elsewhere")
                reportEndedCall(incomingCallID: incomingCallID, reason: .declinedElsewhere)
            }
        }

        guard case let .success(handle) = roomProxy.subscribeToCallDeclineEvents(rtcNotificationEventID: rtcNotificationID, listener: listener) else {
            MXLog.error("Unable to listen for decline events.")
            return
        }

        declineListenerHandle = handle
    }

    private func reportEndedCall(incomingCallID: CallID, reason: CXCallEndedReason) {
        MXLog.info("[JunchatCall] reportEndedCall reason=\(reason.rawValue)")
        declineListenerHandle?.cancel()
        declineListenerHandle = nil
        endUnansweredCallTask?.cancel()
        endUnansweredCallTask = nil
        callProvider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: reason)
        self.incomingCallID = nil
    }
}
