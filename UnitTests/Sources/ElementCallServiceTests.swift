//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import CallKit
import Clocks
import Combine
@testable import ElementX
import MatrixRustSDKMocks
import PushKit
import Testing

@MainActor
final class ElementCallServiceTests {
    private var callKitActionRecorder: CallKitActionRecorder!
    private var callProvider: CXProviderMock!
    private var currentDate: Date!
    private var testClock: TestClock<Duration>!
    private var pushRegistry: PKPushRegistry!
    private var service: ElementCallService!
    
    init() {
        pushRegistry = PKPushRegistry(queue: nil)
        callProvider = CXProviderMock(.init())
        currentDate = Date()
        testClock = TestClock()
        callKitActionRecorder = CallKitActionRecorder()
        let dateProvider: () -> Date = {
            self.currentDate
        }
        service = ElementCallService(callProvider: callProvider,
                                     timeProvider: TimeProvider(clock: testClock, now: dateProvider),
                                     ignoresCallKitEndActions: false,
                                     fulfillCallKitAction: callKitActionRecorder.fulfill)
    }
    
    deinit {
        callKitActionRecorder = nil
        callProvider = nil
        currentDate = nil
        testClock = nil
        pushRegistry = nil
    }
    
    @Test
    func incomingCall() async {
        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        await confirmation { confirmation in
            let pkPushPayloadMock = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
            
            service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: pkPushPayloadMock, for: .voIP) {
                confirmation()
            }
        }
        
        #expect(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        // Verify the provider was called with a CXCallUpdate that has video enabled
        if let args = callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments {
            #expect(args.update.hasVideo == true)
        } else {
            Issue.record("Expected reportNewIncomingCallWithUpdateCompletionReceivedArguments to be captured")
        }
    }
    
    @Test
    func incomingVoiceCall() async {
        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        await confirmation { confirmation in
            let pkPushPayloadMock = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
                .updateIsVoice(true)
            
            service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: pkPushPayloadMock, for: .voIP) {
                confirmation()
            }
        }
        
        #expect(callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        // Verify the provider was called with a CXCallUpdate that has video enabled
        if let args = callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments {
            // Due to a limitation on Callkit and Webviews, we currently have to report voice calls as having video,
            // even if they are voice calls :/ If not the webview is not started and the call is not shown to the user.
            #expect(args.update.hasVideo == true)
        } else {
            Issue.record("Expected reportNewIncomingCallWithUpdateCompletionReceivedArguments to be captured")
        }
    }

    @Test
    func acceptingIncomingCallStopsCallKitRingingImmediately() async throws {
        await confirmation { confirmation in
            let pkPushPayloadMock = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
                .updateIsVoice(true)
            
            service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: pkPushPayloadMock, for: .voIP) {
                confirmation()
            }
        }
        
        #expect(service.incomingCallRoomIDPublisher.value == "!room:example.com")
        #expect(!callProvider.reportCallWithEndedAtReasonCalled)
        
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let acceptedIncomingCallIdentity = try #require(await service.acceptIncomingCall(roomID: "!room:example.com",
                                                                                         isVoiceCall: true,
                                                                                         incomingCallIdentity: incomingCallIdentity))
        
        #expect(callProvider.reportCallWithEndedAtReasonCalled)
        #expect(callProvider.reportCallWithEndedAtReasonReceivedArguments?.reason == .remoteEnded)
        #expect(callProvider.reportCallWithEndedAtReasonCallsCount == 1)
        #expect(service.incomingCallRoomIDPublisher.value == nil)
        
        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        await service.setupCallSession(roomID: "!room:example.com",
                                       roomDisplayName: "welcome",
                                       incomingCallIdentity: acceptedIncomingCallIdentity,
                                       generation: generation)
        
        #expect(callProvider.reportCallWithEndedAtReasonCallsCount == 1)
        #expect(service.incomingCallRoomIDPublisher.value == nil)
        #expect(service.ongoingCallRoomIDPublisher.value == "!room:example.com")
    }

    @Test
    func delayedAcceptedCallSetupCannotClearOrOrphanReplacementIncomingPush() async throws {
        let acceptedRoomID = "!accepted:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(acceptedRoomID)
            .updatingRTCNotificationID("$accepted"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let acceptedIncomingCallIdentity = try #require(await service.acceptIncomingCall(roomID: acceptedRoomID,
                                                                                         isVoiceCall: true,
                                                                                         incomingCallIdentity: incomingCallIdentity))

        let replacementRoomID = acceptedRoomID
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        let replacementIncomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let replacementCallKitID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)

        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        await service.setupCallSession(roomID: acceptedRoomID,
                                       roomDisplayName: "Accepted",
                                       incomingCallIdentity: acceptedIncomingCallIdentity,
                                       generation: generation)

        #expect(service.incomingCallIdentityPublisher.value == replacementIncomingCallIdentity)
        #expect(service.ongoingCallRoomIDPublisher.value == nil)
        #expect(!callProvider.reportCallWithEndedAtReasonReceivedInvocations.contains { $0.uuid == replacementCallKitID })
    }

    @Test
    func videoAnswerWaitsForCallKitAudioSessionDeactivationBeforeStartingWebKit() async throws {
        let roomID = "!video:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$video"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedRoomID: String?
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRoomID = roomID
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil { self.callProvider.reportCallWithEndedAtReasonCalled }

        #expect(startedRoomID == nil)

        service.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await waitUntil { startedRoomID != nil }

        #expect(startedRoomID == roomID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func answerCancelsUnansweredTimerWhileWaitingForCallKitAudioSessionDeactivation() async throws {
        let roomID = "!timer:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 2)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$timer"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedRoomID: String?
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRoomID = roomID
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil {
            self.callProvider.reportCallWithEndedAtReasonReceivedInvocations.contains {
                $0.uuid == incomingCallIdentity.callKitID && $0.reason == .remoteEnded
            }
        }

        await testClock.advance(by: .seconds(1))

        #expect(!callProvider.reportCallWithEndedAtReasonReceivedInvocations.contains {
            $0.uuid == incomingCallIdentity.callKitID && $0.reason == .unanswered
        })
        #expect(startedRoomID == nil)

        service.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await waitUntil { startedRoomID != nil }

        #expect(startedRoomID == roomID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func matchingAnswerUsesAndPublishesTheExactCallKitIdentity() async throws {
        let roomID = "!answered:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$answered")
            .updateIsVoice(true))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedIncomingCallIdentity: ElementCallIncomingCallIdentity?
        let cancellable = service.actions.sink { action in
            if case .startCall(_, _, let identity) = action {
                startedIncomingCallIdentity = identity
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        service.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await waitUntil { startedIncomingCallIdentity != nil }

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == action.uuid }.count == 1)
        #expect(startedIncomingCallIdentity == incomingCallIdentity)
        #expect(service.acceptedIncomingCallIdentity == incomingCallIdentity)
        #expect(service.incomingCallIdentityPublisher.value == nil)
        #expect(callProvider.reportCallWithEndedAtReasonReceivedArguments?.uuid == incomingCallIdentity.callKitID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func answerStartsWebKitAfterBoundedCallKitAudioSessionDeactivationTimeout() async throws {
        let roomID = "!timeout:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$timeout"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedRoomID: String?
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRoomID = roomID
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(3))
        await waitUntil { startedRoomID != nil }

        #expect(startedRoomID == roomID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func providerResetCancelsAnswerHandoffAndInvalidatesIncomingCall() async throws {
        let roomID = "!reset:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$reset"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedRooms = [String]()
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRooms.append(roomID)
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil { self.callProvider.reportCallWithEndedAtReasonCalled }

        service.providerDidReset(provider)

        #expect(service.incomingCallIdentityPublisher.value == nil)
        #expect(service.acceptedIncomingCallIdentity == nil)
        try await testClock.checkSuspension()

        await testClock.advance(by: .seconds(2))

        #expect(startedRooms.isEmpty)
        #expect(service.acceptedIncomingCallIdentity == nil)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func duplicateAnswerDoesNotRestartActiveCallKitHandoff() async throws {
        let roomID = "!duplicate:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$duplicate"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedIncomingCallIdentities = [ElementCallIncomingCallIdentity]()
        let cancellable = service.actions.sink { action in
            if case .startCall(_, _, let incomingCallIdentity) = action {
                startedIncomingCallIdentities.append(incomingCallIdentity)
            }
        }
        let firstAction = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let duplicateAction = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: firstAction)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil { self.callProvider.reportCallWithEndedAtReasonCalled }

        service.provider(provider, perform: duplicateAction)
        service.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await waitUntil { startedIncomingCallIdentities.count == 1 }
        await testClock.advance(by: .seconds(3))

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == firstAction.uuid }.count == 1)
        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == duplicateAction.uuid }.count == 1)
        #expect(callProvider.reportCallWithEndedAtReasonReceivedInvocations.filter {
            $0.uuid == incomingCallIdentity.callKitID && $0.reason == .remoteEnded
        }.count == 1)
        #expect(startedIncomingCallIdentities == [incomingCallIdentity])
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func inAppAcceptCannotBypassActiveCallKitAudioSessionDeactivationBarrier() async throws {
        let roomID = "!in-app:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$in-app"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedIncomingCallIdentity: ElementCallIncomingCallIdentity?
        let cancellable = service.actions.sink { action in
            if case .startCall(_, _, let incomingCallIdentity) = action {
                startedIncomingCallIdentity = incomingCallIdentity
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil { self.callProvider.reportCallWithEndedAtReasonCalled }

        let inAppAcceptedIdentity = await service.acceptIncomingCall(roomID: roomID,
                                                                     isVoiceCall: false,
                                                                     incomingCallIdentity: incomingCallIdentity)

        #expect(inAppAcceptedIdentity == nil)
        #expect(service.incomingCallIdentityPublisher.value == incomingCallIdentity)
        #expect(service.acceptedIncomingCallIdentity == nil)
        #expect(callProvider.reportCallWithEndedAtReasonReceivedInvocations.filter {
            $0.uuid == incomingCallIdentity.callKitID && $0.reason == .remoteEnded
        }.count == 1)

        service.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await waitUntil { startedIncomingCallIdentity != nil }

        #expect(startedIncomingCallIdentity == incomingCallIdentity)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func answerWaitingForCallKitDeactivationCannotStartAfterIncomingReplacement() async throws {
        let firstRoomID = "!first:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(firstRoomID)
            .updatingRTCNotificationID("$first"))
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        var startedRooms = [String]()
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRooms.append(roomID)
            }
        }
        let action = CXAnswerCallAction(call: incomingCallIdentity.callKitID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))
        await waitUntil { self.callProvider.reportCallWithEndedAtReasonCalled }
        #expect(startedRooms.isEmpty)

        let replacementRoomID = "!replacement:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        await Task.yield()

        #expect(startedRooms.isEmpty)
        #expect(service.incomingCallRoomIDPublisher.value == replacementRoomID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func stoppedCallSessionGenerationCannotPublishAnOngoingCall() async {
        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        service.tearDownCallSession(generation: generation)

        await service.setupCallSession(roomID: "!stopped:example.com",
                                       roomDisplayName: "Stopped",
                                       incomingCallIdentity: nil,
                                       generation: generation)

        #expect(service.ongoingCallRoomIDPublisher.value == nil)
    }

    @Test
    func supersededCallSessionGenerationCannotMutateTheReplacement() async {
        let firstGeneration = ElementCallSessionGeneration()
        service.registerCallSession(generation: firstGeneration)
        let replacementGeneration = ElementCallSessionGeneration()
        service.registerCallSession(generation: replacementGeneration)

        await service.setupCallSession(roomID: "!stale:example.com",
                                       roomDisplayName: "Stale",
                                       incomingCallIdentity: nil,
                                       generation: firstGeneration)
        #expect(service.ongoingCallRoomIDPublisher.value == nil)

        await service.setupCallSession(roomID: "!replacement:example.com",
                                       roomDisplayName: "Replacement",
                                       incomingCallIdentity: nil,
                                       generation: replacementGeneration)
        #expect(service.ongoingCallRoomIDPublisher.value == "!replacement:example.com")

        service.tearDownCallSession(generation: firstGeneration)
        #expect(service.ongoingCallRoomIDPublisher.value == "!replacement:example.com")

        service.tearDownCallSession(generation: replacementGeneration)
        #expect(service.ongoingCallRoomIDPublisher.value == nil)
    }
    
    @Test(.disabled())
    func callIsTimingOut() async {
        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        await confirmation { confirmation in
            let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 20)
            
            service.pushRegistry(pushRegistry,
                                 didReceiveIncomingPushWith: pushPayload,
                                 for: .voIP) {
                confirmation()
            }
        }
        
        await confirmation { confirmation in
            callProvider.reportCallWithEndedAtReasonClosure = { _, _, reason in
                if reason == .unanswered {
                    confirmation()
                } else {
                    Issue.record("Call should have ended as unanswered")
                }
            }
            
            // advance past the timeout
            await testClock.advance(by: .seconds(30))
        }
    }
    
    @Test
    func expiredRingLifetimeIsIgnored() async {
        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        
        let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 20)
        
        currentDate = currentDate.addingTimeInterval(60)
        
        await confirmation { confirmation in
            service.pushRegistry(pushRegistry,
                                 didReceiveIncomingPushWith: pushPayload,
                                 for: .voIP) {
                confirmation()
            }
        }
        
        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        #expect(service.incomingCallRoomIDPublisher.value == nil)
    }

    @Test(arguments: [ElementCallServiceNotificationKey.roomID.rawValue,
                      ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue,
                      ElementCallServiceNotificationKey.expirationDate.rawValue])
    func missingRequiredPushFieldDoesNotPublishIncomingCall(key: String) async {
        let payload = PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .removing(key)

        await receiveIncomingPush(payload)

        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        #expect(service.incomingCallRoomIDPublisher.value == nil)
    }

    @Test
    func invalidRequiredPushFieldsDoNotPublishIncomingCall() async {
        let invalidPayloads = [
            PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30).updatingRoomID(""),
            PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30).updatingRTCNotificationID(""),
            PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30)
                .updatingValue("not-a-date", for: ElementCallServiceNotificationKey.expirationDate.rawValue)
        ]

        for payload in invalidPayloads {
            await receiveIncomingPush(payload)
        }

        #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
        #expect(service.incomingCallRoomIDPublisher.value == nil)
    }

    @Test
    func delayedIncomingObservationCannotReplaceCurrentSubscriptionsOrClearReplacement() async throws {
        let firstRoomID = "!first:example.com"
        let replacementRoomID = "!replacement:example.com"
        let firstRoom = JoinedRoomProxyMock(.init(id: firstRoomID, name: "First"))
        let replacementRoom = JoinedRoomProxyMock(.init(id: replacementRoomID, name: "Replacement"))
        let firstRoomInfo = CurrentValueSubject<RoomInfoProxyProtocol, Never>(firstRoom.infoPublisher.value)
        firstRoom.infoPublisher = firstRoomInfo.asCurrentValuePublisher()
        firstRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReturnValue = .success(TaskHandleSDKMock())
        replacementRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReturnValue = .success(TaskHandleSDKMock())

        let delayedLookup = SuspendedIncomingCallRoomLookup()
        let clientProxy = ClientProxyMock(.init())
        clientProxy.roomForIdentifierClosure = { roomID in
            switch roomID {
            case firstRoomID:
                await delayedLookup.wait()
                return .joined(firstRoom)
            case replacementRoomID:
                return .joined(replacementRoom)
            default:
                return nil
            }
        }
        service.setClientProxy(clientProxy)

        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(firstRoomID)
            .updatingRTCNotificationID("$first"))
        await waitUntil { delayedLookup.hasRequest }

        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        await waitUntil { replacementRoom.subscribeToRoomInfoUpdatesCallsCount == 1 }

        delayedLookup.resume()
        try await Task.sleep(for: .milliseconds(50))
        firstRoomInfo.send(RoomInfoProxyMock(.init(id: firstRoomID, name: "First", hasOngoingCall: false)))
        try await Task.sleep(for: .milliseconds(50))

        #expect(firstRoom.subscribeToRoomInfoUpdatesCallsCount == 0)
        #expect(service.incomingCallRoomIDPublisher.value == replacementRoomID)
    }

    @Test
    func staleIncomingDeclineCallbackCannotClearReplacement() async throws {
        let firstRoomID = "!first:example.com"
        let replacementRoomID = "!replacement:example.com"
        let firstRoom = JoinedRoomProxyMock(.init(id: firstRoomID, name: "First"))
        let replacementRoom = JoinedRoomProxyMock(.init(id: replacementRoomID, name: "Replacement"))
        firstRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReturnValue = .success(TaskHandleSDKMock())
        replacementRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReturnValue = .success(TaskHandleSDKMock())

        let clientProxy = ClientProxyMock(.init())
        clientProxy.roomForIdentifierClosure = { roomID in
            switch roomID {
            case firstRoomID: .joined(firstRoom)
            case replacementRoomID: .joined(replacementRoom)
            default: nil
            }
        }
        service.setClientProxy(clientProxy)

        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(firstRoomID)
            .updatingRTCNotificationID("$first"))
        await waitUntil { firstRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReceivedArguments != nil }
        let staleListener = try #require(firstRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReceivedArguments?.listener)

        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        await waitUntil { replacementRoom.subscribeToCallDeclineEventsRtcNotificationEventIDListenerReceivedArguments != nil }

        staleListener.call(declinerUserId: firstRoom.ownUserID)

        #expect(service.incomingCallRoomIDPublisher.value == replacementRoomID)
    }

    @Test
    func failedCallKitReportDoesNotPublishIncomingCall() async {
        var receivedIncomingCallActionCount = 0
        let cancellable = service.actions.sink { action in
            if case .receivedIncomingCallRequest = action {
                receivedIncomingCallActionCount += 1
            }
        }
        callProvider.reportNewIncomingCallWithUpdateCompletionClosure = { _, _, completion in
            completion(ElementCallServiceTestError.callKitReportFailed)
        }

        await receiveIncomingPush(PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 30))
        await waitUntil { service.incomingCallRoomIDPublisher.value == nil }

        #expect(service.incomingCallRoomIDPublisher.value == nil)
        #expect(receivedIncomingCallActionCount == 0)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func staleCallKitReportCompletionCannotClearReplacement() async {
        var reportCompletions = [@Sendable (Error?) -> Void]()
        var pushCompletionCount = 0
        var receivedIncomingCallActionCount = 0
        let cancellable = service.actions.sink { action in
            if case .receivedIncomingCallRequest = action {
                receivedIncomingCallActionCount += 1
            }
        }
        callProvider.reportNewIncomingCallWithUpdateCompletionClosure = { _, _, completion in
            reportCompletions.append(completion)
        }

        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: PKPushPayloadMock()
                                 .updatingExpiration(currentDate, lifetime: 30)
                                 .updatingRoomID("!first:example.com")
                                 .updatingRTCNotificationID("$first"),
                             for: .voIP) {
            pushCompletionCount += 1
        }
        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: PKPushPayloadMock()
                                 .updatingExpiration(currentDate, lifetime: 30)
                                 .updatingRoomID("!replacement:example.com")
                                 .updatingRTCNotificationID("$replacement"),
                             for: .voIP) {
            pushCompletionCount += 1
        }

        #expect(reportCompletions.count == 2)
        reportCompletions[1](nil)
        await waitUntil { pushCompletionCount == 1 }
        await waitUntil { receivedIncomingCallActionCount == 1 }
        reportCompletions[0](ElementCallServiceTestError.callKitReportFailed)
        await waitUntil { pushCompletionCount == 2 }

        #expect(service.incomingCallRoomIDPublisher.value == "!replacement:example.com")
        #expect(receivedIncomingCallActionCount == 1)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func lateSuccessfulCallKitReportEndsOnlyTheSupersededCall() async throws {
        var reportedCallIDs = [UUID]()
        var reportCompletions = [@Sendable (Error?) -> Void]()
        callProvider.reportNewIncomingCallWithUpdateCompletionClosure = { callID, _, completion in
            reportedCallIDs.append(callID)
            reportCompletions.append(completion)
        }

        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: PKPushPayloadMock()
                                 .updatingExpiration(currentDate, lifetime: 30)
                                 .updatingRoomID("!first:example.com")
                                 .updatingRTCNotificationID("$first"),
                             for: .voIP) { }
        service.pushRegistry(pushRegistry,
                             didReceiveIncomingPushWith: PKPushPayloadMock()
                                 .updatingExpiration(currentDate, lifetime: 30)
                                 .updatingRoomID("!replacement:example.com")
                                 .updatingRTCNotificationID("$replacement"),
                             for: .voIP) { }

        #expect(reportCompletions.count == 2)
        reportCompletions[1](nil)
        reportCompletions[0](nil)
        await waitUntil { callProvider.reportCallWithEndedAtReasonCalled }

        let endedCall = try #require(callProvider.reportCallWithEndedAtReasonReceivedArguments)
        #expect(endedCall.uuid == reportedCallIDs[0])
        #expect(endedCall.reason == .remoteEnded)
        #expect(service.incomingCallRoomIDPublisher.value == "!replacement:example.com")
    }

    @Test
    func replacingReportedIncomingCallEndsTheOldCallKitUUID() async throws {
        var receivedIncomingCallActionCount = 0
        let cancellable = service.actions.sink { action in
            if case .receivedIncomingCallRequest = action {
                receivedIncomingCallActionCount += 1
            }
        }
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!first:example.com")
            .updatingRTCNotificationID("$first"))
        let firstCallUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)
        await waitUntil { receivedIncomingCallActionCount == 1 }

        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!replacement:example.com")
            .updatingRTCNotificationID("$replacement"))

        let endedCall = try #require(callProvider.reportCallWithEndedAtReasonReceivedArguments)
        #expect(endedCall.uuid == firstCallUUID)
        #expect(endedCall.reason == .remoteEnded)
        #expect(service.incomingCallRoomIDPublisher.value == "!replacement:example.com")
        withExtendedLifetime(cancellable) { }
    }

    @Test
    func staleAnswerActionCannotStartReplacementCall() async throws {
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!first:example.com")
            .updatingRTCNotificationID("$first"))
        let firstCallUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!replacement:example.com")
            .updatingRTCNotificationID("$replacement"))

        var startedRooms = [String]()
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRooms.append(roomID)
            }
        }
        let action = CXAnswerCallAction(call: firstCallUUID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await testClock.advance(by: .seconds(1))

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == action.uuid }.count == 1)
        #expect(startedRooms.isEmpty)
        #expect(service.incomingCallRoomIDPublisher.value == "!replacement:example.com")
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func delayedAnswerCannotStartCallAfterIncomingReplacement() async throws {
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!first:example.com")
            .updatingRTCNotificationID("$first"))
        let firstCallUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)
        var startedRooms = [String]()
        let cancellable = service.actions.sink { action in
            if case .startCall(let roomID, _, _) = action {
                startedRooms.append(roomID)
            }
        }
        let action = CXAnswerCallAction(call: firstCallUUID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)
        await Task.yield()
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!replacement:example.com")
            .updatingRTCNotificationID("$replacement"))
        await testClock.advance(by: .seconds(1))

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == action.uuid }.count == 1)
        #expect(startedRooms.isEmpty)
        #expect(service.incomingCallRoomIDPublisher.value == "!replacement:example.com")
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func staleEndActionCannotTearDownReplacementOrClearItsGeneration() async throws {
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!first:example.com")
            .updatingRTCNotificationID("$first"))
        let firstCallUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)
        let replacementRoomID = "!replacement:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        let replacementIncomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let acceptedReplacementIdentity = try #require(await service.acceptIncomingCall(roomID: replacementRoomID,
                                                                                        isVoiceCall: false,
                                                                                        incomingCallIdentity: replacementIncomingCallIdentity))
        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        await service.setupCallSession(roomID: replacementRoomID,
                                       roomDisplayName: "Replacement",
                                       incomingCallIdentity: acceptedReplacementIdentity,
                                       generation: generation)
        let action = CXEndCallAction(call: firstCallUUID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == action.uuid }.count == 1)
        #expect(service.ongoingCallRoomIDPublisher.value == replacementRoomID)
        service.tearDownCallSession(generation: generation)
        #expect(service.ongoingCallRoomIDPublisher.value == nil)
        withExtendedLifetime(provider) { }
    }

    @Test
    func staleMuteActionCannotAlterReplacementMicrophone() async throws {
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID("!first:example.com")
            .updatingRTCNotificationID("$first"))
        let staleCallUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)

        let replacementRoomID = "!replacement:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(replacementRoomID)
            .updatingRTCNotificationID("$replacement"))
        let replacementIncomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let acceptedReplacementIdentity = try #require(await service.acceptIncomingCall(roomID: replacementRoomID,
                                                                                        isVoiceCall: false,
                                                                                        incomingCallIdentity: replacementIncomingCallIdentity))
        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        await service.setupCallSession(roomID: replacementRoomID,
                                       roomDisplayName: "Replacement",
                                       incomingCallIdentity: acceptedReplacementIdentity,
                                       generation: generation)

        var audioActions = [(enabled: Bool, roomID: String)]()
        let cancellable = service.actions.sink { action in
            if case .setAudioEnabled(let enabled, let roomID) = action {
                audioActions.append((enabled, roomID))
            }
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let staleAction = CXSetMutedCallAction(call: staleCallUUID, muted: true)

        service.provider(provider, perform: staleAction)

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == staleAction.uuid }.count == 1)
        #expect(audioActions.isEmpty)
        #expect(service.ongoingCallRoomIDPublisher.value == replacementRoomID)

        let matchingAction = CXSetMutedCallAction(call: acceptedReplacementIdentity.callKitID, muted: true)
        service.provider(provider, perform: matchingAction)

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == matchingAction.uuid }.count == 1)
        #expect(audioActions.count == 1)
        #expect(audioActions.first?.enabled == false)
        #expect(audioActions.first?.roomID == replacementRoomID)
        withExtendedLifetime((cancellable, provider)) { }
    }

    @Test
    func matchingEndActionTearsDownOnlyItsCall() async throws {
        let roomID = "!current:example.com"
        await receiveIncomingPush(PKPushPayloadMock()
            .updatingExpiration(currentDate, lifetime: 30)
            .updatingRoomID(roomID)
            .updatingRTCNotificationID("$current"))
        let callUUID = try #require(callProvider.reportNewIncomingCallWithUpdateCompletionReceivedArguments?.uuid)
        let incomingCallIdentity = try #require(service.incomingCallIdentityPublisher.value)
        let acceptedIncomingCallIdentity = try #require(await service.acceptIncomingCall(roomID: roomID,
                                                                                         isVoiceCall: false,
                                                                                         incomingCallIdentity: incomingCallIdentity))
        let generation = ElementCallSessionGeneration()
        service.registerCallSession(generation: generation)
        await service.setupCallSession(roomID: roomID,
                                       roomDisplayName: "Current",
                                       incomingCallIdentity: acceptedIncomingCallIdentity,
                                       generation: generation)
        let action = CXEndCallAction(call: callUUID)
        let provider = CXProvider(configuration: CXProviderConfiguration())

        service.provider(provider, perform: action)

        #expect(callKitActionRecorder.fulfilledActionIDs.filter { $0 == action.uuid }.count == 1)
        #expect(service.ongoingCallRoomIDPublisher.value == nil)
        withExtendedLifetime(provider) { }
    }
    
    @Test
    func lifetimeIsCapped() async {
        await confirmation { confirmation in
            callProvider.reportCallWithEndedAtReasonClosure = { _, _, reason in
                if reason == .unanswered {
                    confirmation()
                } else {
                    Issue.record("Call should have ended as unanswered")
                }
            }
            
            #expect(!callProvider.reportNewIncomingCallWithUpdateCompletionCalled)
            
            let pushPayload = PKPushPayloadMock().updatingExpiration(currentDate, lifetime: 300)
            
            service.pushRegistry(pushRegistry,
                                 didReceiveIncomingPushWith: pushPayload,
                                 for: .voIP) { }

            await Task.yield()
            // Advance past the max timeout but below the 300
            await testClock.advance(by: .seconds(100))
        }
    }

    private func receiveIncomingPush(_ payload: PKPushPayloadMock) async {
        await confirmation { confirmation in
            service.pushRegistry(pushRegistry, didReceiveIncomingPushWith: payload, for: .voIP) {
                confirmation()
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            guard !condition() else { return }
            await Task.yield()
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}

private class PKPushPayloadMock: PKPushPayload {
    var dict: [AnyHashable: Any] = [:]
    
    override init() {
        dict[ElementCallServiceNotificationKey.roomID.rawValue] = "!room:example.com"
        dict[ElementCallServiceNotificationKey.roomDisplayName.rawValue] = "welcome"
        dict[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] = "$000"
        dict[ElementCallServiceNotificationKey.expirationDate.rawValue] = Date(timeIntervalSince1970: 10)
    }
    
    override var dictionaryPayload: [AnyHashable: Any] {
        dict
    }
    
    func updatingExpiration(_ from: Date, lifetime: TimeInterval) -> Self {
        dict[ElementCallServiceNotificationKey.expirationDate.rawValue] = from.addingTimeInterval(lifetime)
        return self
    }
    
    func updateIsVoice(_ isVoice: Bool) -> Self {
        dict[ElementCallServiceNotificationKey.isVoiceCall.rawValue] = isVoice
        return self
    }

    func updatingRoomID(_ roomID: String) -> Self {
        dict[ElementCallServiceNotificationKey.roomID.rawValue] = roomID
        return self
    }

    func updatingRTCNotificationID(_ eventID: String) -> Self {
        dict[ElementCallServiceNotificationKey.rtcNotifyEventID.rawValue] = eventID
        return self
    }

    func removing(_ key: String) -> Self {
        dict[key] = nil
        return self
    }

    func updatingValue(_ value: Any, for key: String) -> Self {
        dict[key] = value
        return self
    }
}

@MainActor
private final class SuspendedIncomingCallRoomLookup {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasRequest: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ElementCallServiceTestError: Error {
    case callKitReportFailed
}

@MainActor
private final class CallKitActionRecorder {
    private(set) var fulfilledActionIDs = [UUID]()

    func fulfill(_ action: CXAction) {
        fulfilledActionIDs.append(action.uuid)
    }
}
