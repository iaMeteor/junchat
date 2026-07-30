//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import CryptoKit
@testable import ElementX
import Foundation
import Testing
import UIKit

struct CallScreenJunchatTests {
    @Test
    func elementCallLanguageFollowsJunchatChineseOnlyPolicy() {
        Bundle.overrideLocalizations = ["en-US"]
        #expect(Bundle.junchatElementCallLanguage == "zh-Hans")

        Bundle.overrideLocalizations = ["zh-HK"]
        #expect(Bundle.junchatElementCallLanguage == "zh-Hant")

        Bundle.overrideLocalizations = nil
    }

    @Test
    func elementCallBootstrapLocalizesMissingCallStrings() {
        let script = CallScreen.junchatElementCallBootstrapScript(language: "zh-Hans")

        #expect(script.contains("resolvedURL.pathname.includes(\"/en-app-\") ? junchatLanguage"))
        #expect(script.contains("MutationObserver"))
        #expect(script.contains("\"Handset Mode\": \"听筒模式\""))
        #expect(script.contains("\"Only works while using app\": \"仅在使用 App 时生效\""))
        #expect(script.contains("\"Back to Speaker Mode\": \"返回扬声器模式\""))
        #expect(script.contains("\"Calling...\": \"正在呼叫...\""))
        #expect(script.contains("delayed_leave_event_restart_ms: 20000"))
        #expect(script.contains("delayed_leave_event_delay_ms: 120000"))
        #expect(script.contains("overlay_title: \"听筒模式\""))
        #expect(script.contains("overlay_description: \"仅在使用 App 时生效\""))
        #expect(script.contains("overlay_back_button: \"返回扬声器模式\""))
        #expect(script.contains("calling: \"正在呼叫"))
        #expect(script.contains("change_device_button: \"切换音频设备\""))
        #expect(script.contains("loudspeaker: \"扬声器\""))
    }

    @Test
    func elementCallBootstrapLeavesLiveKitDiscoveryToElementCall() {
        let script = CallScreen.junchatElementCallBootstrapScript(language: "zh-Hans")

        #expect(!script.contains("livekit_service_url"))
        #expect(!script.contains("junchatConfig.livekit"))
        #expect(script.contains("delete sanitizedConfig.livekit"))
        #expect(script.contains("localStorage.removeItem(\"matrix-setting-custom-livekit-url\")"))
        #expect(script.contains("matrix_rtc_session"))
    }

    @Test
    func elementCallBootstrapReportsRemoteMediaTrackForConnectedTone() {
        let script = CallScreen.junchatElementCallBootstrapScript(language: "zh-Hans")

        #expect(script.contains("__junchatCallConnectedTonePatched"))
        #expect(script.contains("RTCPeerConnection"))
        #expect(script.contains("track"))
        #expect(script.contains("call_connected"))
        #expect(script.contains("api: \"junchat\""))
        #expect(script.contains("version: 1"))
        #expect(script.contains("window.webkit.messageHandlers.widgetAction.postMessage"))
    }

    @Test
    func canonicalCallConnectedFixtureIsByteIdenticalAndRecognized() throws {
        let fixtureURL = try #require(Bundle(for: CallScreenJunchatFixtureToken.self)
            .url(forResource: "junchat-call-connected-v1", withExtension: "json"))
        let data = try Data(contentsOf: fixtureURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        #expect(checksum == "44e10d7adebb6b1f6ecb7f5d619b57bcc211e32a77ddd9d36f8136769089d127")

        let rawMessage = try #require(String(data: data, encoding: .utf8))
        let message = try #require(try DecodedWidgetMessage.decode(message: rawMessage))

        #expect(message.isJunchatCallConnected)
        #expect(!message.hasLoaded)
    }

    @Test(arguments: [
        #"{"api":"junchat","action":"call_connected"}"#,
        #"{"api":"junchat","action":"call_connected","version":1}"#
    ])
    func decodedWidgetMessageAcceptsLegacyAndVersionOneCallConnectedEvents(_ rawMessage: String) throws {
        let message = try #require(try DecodedWidgetMessage.decode(message: rawMessage))

        #expect(message.isJunchatCallConnected)
    }

    @Test(arguments: [
        #"{"api":"junchat","action":"call_connected","version":null}"#,
        #"{"api":"junchat","action":"call_connected","version":"1"}"#,
        #"{"api":"junchat","action":"call_connected","version":1.5}"#,
        #"{"api":"junchat","action":"call_connected","version":{}}"#,
        #"{"api":"junchat","action":"call_connected","version":2}"#
    ])
    func decodedWidgetMessageRejectsUnsupportedPrivateCallConnectedVersions(_ rawMessage: String) throws {
        let message = try #require(try DecodedWidgetMessage.decode(message: rawMessage))

        #expect(!message.isJunchatCallConnected)
    }

    @Test
    func callMemberFilterForwardsOwnEmptyMemberFromWidget() {
        let message = callMemberMessage(api: "fromWidget",
                                        action: "send_event",
                                        requestID: "leave-own",
                                        sender: "@alice:junchat.yyzs120.cn",
                                        stateKey: "_@alice:junchat.yyzs120.cn_IOSDEVICE_m.call",
                                        content: "{}")

        guard case .forward = JunchatCallMemberWidgetMessageFilter.fromWidgetResult(for: message,
                                                                                    ownUserID: "@alice:junchat.yyzs120.cn",
                                                                                    deviceID: "IOSDEVICE") else {
            Issue.record("Own leave events from Element Call must reach the server so peers see the call end.")
            return
        }
    }

    @Test
    func callMemberFilterForwardsOwnDelayedEmptyMemberFromWidget() {
        let message = callMemberMessage(api: "fromWidget",
                                        action: "send_event",
                                        requestID: "delayed-leave-own",
                                        sender: "@alice:junchat.yyzs120.cn",
                                        stateKey: "_@alice:junchat.yyzs120.cn_IOSDEVICE_m.call",
                                        content: "{}",
                                        extraData: #","delay":18000"#)

        guard case .forward = JunchatCallMemberWidgetMessageFilter.fromWidgetResult(for: message,
                                                                                    ownUserID: "@alice:junchat.yyzs120.cn",
                                                                                    deviceID: "IOSDEVICE") else {
            Issue.record("Delayed leave scheduling must reach the server so Element Call receives a delay_id.")
            return
        }
    }

    @Test
    func callMemberFilterKeepsRemoteEmptyMemberFromWidget() {
        let message = callMemberMessage(api: "fromWidget",
                                        action: "send_event",
                                        requestID: "remote-leave",
                                        sender: "@bob:junchat.yyzs120.cn",
                                        stateKey: "_@bob:junchat.yyzs120.cn_ANDROID_m.call",
                                        content: "{}")

        guard case .forward = JunchatCallMemberWidgetMessageFilter.fromWidgetResult(for: message,
                                                                                    ownUserID: "@alice:junchat.yyzs120.cn",
                                                                                    deviceID: "IOSDEVICE") else {
            Issue.record("Remote leave events must still reach Element Call.")
            return
        }
    }

    @Test
    func callMemberFilterRemovesOnlyOwnEmptyMemberFromMixedStateUpdates() throws {
        let ownLeaveEvent = callMemberEvent(sender: "@alice:junchat.yyzs120.cn",
                                            stateKey: "_@alice:junchat.yyzs120.cn_IOSDEVICE_m.call",
                                            content: "{}")
        let remoteLeaveEvent = callMemberEvent(sender: "@bob:junchat.yyzs120.cn",
                                               stateKey: "_@bob:junchat.yyzs120.cn_ANDROID_m.call",
                                               content: "{}")
        let message = """
        {"api":"toWidget","widgetId":"widget","requestId":"mixed-state","action":"update_state","data":{"state":[\(ownLeaveEvent),\(remoteLeaveEvent)]}}
        """

        guard case .forward(let filteredMessage) = JunchatCallMemberWidgetMessageFilter.toWidgetResult(for: message,
                                                                                                       ownUserID: "@alice:junchat.yyzs120.cn",
                                                                                                       deviceID: "IOSDEVICE") else {
            Issue.record("Expected a mixed state update to be forwarded after filtering.")
            return
        }

        let object = try jsonObject(filteredMessage)
        let data = try #require(object["data"] as? [String: Any])
        let state = try #require(data["state"] as? [[String: Any]])
        #expect(state.count == 1)
        #expect(state.first?["sender"] as? String == "@bob:junchat.yyzs120.cn")
    }

    @Test
    func callMemberFilterAcknowledgesOwnOnlyStateUpdateToWidget() throws {
        let ownLeaveEvent = callMemberEvent(sender: "@alice:junchat.yyzs120.cn",
                                            stateKey: "_@alice:junchat.yyzs120.cn_IOSDEVICE_m.call",
                                            content: "{}")
        let message = """
        {"api":"toWidget","widgetId":"widget","requestId":"own-state","action":"update_state","data":{"state":[\(ownLeaveEvent)]}}
        """

        guard case .acknowledge(let response) = JunchatCallMemberWidgetMessageFilter.toWidgetResult(for: message,
                                                                                                    ownUserID: "@alice:junchat.yyzs120.cn",
                                                                                                    deviceID: "IOSDEVICE") else {
            Issue.record("Expected an own-only state update to be acknowledged locally.")
            return
        }

        let responseObject = try jsonObject(response)
        #expect(responseObject["api"] as? String == "toWidget")
        #expect(responseObject["requestId"] as? String == "own-state")
        #expect(responseObject["response"] is [String: Any])
    }

    @Test
    func voiceCallKeepsProximityOffUntilRemoteMediaIsConnected() {
        #expect(!CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: true,
                                                                      selectedOutput: .nativeEarpiece,
                                                                      remoteMediaConnected: false))
        #expect(CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: true,
                                                                     selectedOutput: .nativeEarpiece,
                                                                     remoteMediaConnected: true))
    }

    @Test
    func speakerAndVideoCallsNeverEnableProximityMonitoring() {
        #expect(!CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: true,
                                                                      selectedOutput: .nativeSpeaker,
                                                                      remoteMediaConnected: true))
        #expect(!CallAudioRoutePolicy.shouldEnableProximityMonitoring(voiceOnly: false,
                                                                      selectedOutput: .nativeEarpiece,
                                                                      remoteMediaConnected: true))
    }

    @Test
    func voiceCallsApplyInitialNativeEarpieceForBuiltInRoutes() {
        #expect(CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                         selectedOutput: .nativeEarpiece,
                                                                         hasAppliedInitialVoiceOutputDevice: false,
                                                                         forcePreferInitialEarpiece: false,
                                                                         portType: .builtInSpeaker))
        #expect(CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                         selectedOutput: .nativeEarpiece,
                                                                         hasAppliedInitialVoiceOutputDevice: false,
                                                                         forcePreferInitialEarpiece: false,
                                                                         portType: .builtInReceiver))
    }

    @Test
    func initialNativeEarpiecePolicyHonorsUserAndExternalRoutes() {
        #expect(!CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                          selectedOutput: .nativeSpeaker,
                                                                          hasAppliedInitialVoiceOutputDevice: false,
                                                                          forcePreferInitialEarpiece: true,
                                                                          portType: .builtInSpeaker))
        #expect(!CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: false,
                                                                          selectedOutput: .nativeEarpiece,
                                                                          hasAppliedInitialVoiceOutputDevice: false,
                                                                          forcePreferInitialEarpiece: true,
                                                                          portType: .builtInSpeaker))
        #expect(!CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                          selectedOutput: .nativeEarpiece,
                                                                          hasAppliedInitialVoiceOutputDevice: false,
                                                                          forcePreferInitialEarpiece: true,
                                                                          portType: .headphones))
        #expect(!CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                          selectedOutput: .nativeEarpiece,
                                                                          hasAppliedInitialVoiceOutputDevice: true,
                                                                          forcePreferInitialEarpiece: false,
                                                                          portType: .builtInReceiver))
        #expect(CallAudioRoutePolicy.shouldApplyInitialVoiceOutputDevice(voiceOnly: true,
                                                                         selectedOutput: .nativeEarpiece,
                                                                         hasAppliedInitialVoiceOutputDevice: true,
                                                                         forcePreferInitialEarpiece: true,
                                                                         portType: .builtInReceiver))
    }

    @Test
    @MainActor
    func callEndedActionAndSubsequentStopCleanUpOnce() async throws {
        let widgetActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>()
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = widgetActions.eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let elementCallService = ElementCallServiceMock(.init())
        let appSettings = AppSettings()
        let analytics = AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings)
        var endedTonePlayCount = 0
        var dismissCount = 0
        var pictureInPictureStopCount = 0
        var cancellables = Set<AnyCancellable>()

        let viewModel = CallScreenViewModel(elementCallService: elementCallService,
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: analytics,
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { endedTonePlayCount += 1 })
        viewModel.context.stopPictureInPictureHandler = { pictureInPictureStopCount += 1 }

        viewModel.actions.sink { action in
            if case .dismiss = action {
                dismissCount += 1
            }
        }
        .store(in: &cancellables)

        widgetActions.send(.callEnded)
        widgetActions.send(.callEnded)
        try await Task.sleep(for: .milliseconds(100))
        viewModel.stop()

        #expect(endedTonePlayCount == 1)
        #expect(dismissCount == 1)
        #expect(pictureInPictureStopCount == 1)
        #expect(elementCallService.registerCallSessionGenerationCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationReceivedGeneration == elementCallService.registerCallSessionGenerationReceivedGeneration)
    }

    @Test
    @MainActor
    func endCallWaitsForElementCallHangupAcknowledgementBeforeTearingDown() async throws {
        let fixture = makeLifecycleViewModel()
        let viewModel = fixture.viewModel
        let widgetDriver = fixture.widgetDriver
        let elementCallService = fixture.elementCallService
        var events = [String]()
        var hangupJavaScript: String?
        var cancellables = Set<AnyCancellable>()

        widgetDriver.stopClosure = { events.append("widgetStopped") }
        widgetDriver.handleMessageClosure = { _ in
            events.append("acknowledgementForwarded")
            return .success(true)
        }
        elementCallService.tearDownCallSessionGenerationClosure = { _ in events.append("serviceTornDown") }
        viewModel.context.javaScriptEvaluator = { script in
            guard script.contains(#""action":"im.vector.hangup""#) else { return "ignored" }
            events.append("hangupEvaluated")
            hangupJavaScript = script
            return "scheduled"
        }
        viewModel.actions.sink { action in
            if case .dismiss = action {
                events.append("dismissed")
            }
        }
        .store(in: &cancellables)

        viewModel.process(viewAction: .endCall)
        await waitUntil { hangupJavaScript != nil }

        #expect(widgetDriver.stopCallsCount == 0)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 0)
        #expect(!events.contains("dismissed"))

        let request = try hangupRequest(from: #require(hangupJavaScript))
        #expect(request["api"] as? String == "toWidget")
        let requestID = try #require(request["requestId"] as? String)
        viewModel.process(viewAction: .widgetAction(message: hangupAcknowledgement(requestID: requestID)))
        await waitUntil { events.contains("acknowledgementForwarded") }

        #expect(widgetDriver.stopCallsCount == 0)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 0)
        #expect(!events.contains("dismissed"))

        fixture.widgetActions.send(.callEnded)
        await waitUntil { events.contains("dismissed") }

        #expect(events == ["hangupEvaluated", "acknowledgementForwarded", "widgetStopped", "serviceTornDown", "dismissed"])
    }

    @Test
    @MainActor
    func acknowledgedHangupWithoutCallCloseUsesBoundedFallback() async throws {
        let fixture = makeLifecycleViewModel(callCloseTimeout: .milliseconds(20))
        let viewModel = fixture.viewModel
        let widgetDriver = fixture.widgetDriver
        let elementCallService = fixture.elementCallService
        var hangupJavaScript: String?

        viewModel.context.javaScriptEvaluator = { script in
            guard script.contains(#""action":"im.vector.hangup""#) else { return "ignored" }
            hangupJavaScript = script
            return "scheduled"
        }

        viewModel.process(viewAction: .endCall)
        await waitUntil { hangupJavaScript != nil }
        let requestID = try hangupRequestID(from: #require(hangupJavaScript))
        viewModel.process(viewAction: .widgetAction(message: hangupAcknowledgement(requestID: requestID)))
        await waitUntil { widgetDriver.handleMessageCallsCount == 1 }

        #expect(widgetDriver.stopCallsCount == 0)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 0)

        try await Task.sleep(for: .milliseconds(50))

        #expect(widgetDriver.stopCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
    }

    @Test
    @MainActor
    func missingElementCallHangupAcknowledgementTimesOutWithoutRepeatingTeardown() async throws {
        let fixture = makeLifecycleViewModel(hangupDeliveryTimeout: .milliseconds(20))
        let viewModel = fixture.viewModel
        let widgetDriver = fixture.widgetDriver
        let elementCallService = fixture.elementCallService
        var hangupJavaScript: String?
        var dismissCount = 0
        var cancellables = Set<AnyCancellable>()

        viewModel.context.javaScriptEvaluator = { script in
            guard script.contains(#""action":"im.vector.hangup""#) else { return "ignored" }
            hangupJavaScript = script
            return "scheduled"
        }
        viewModel.actions.sink { action in
            if case .dismiss = action {
                dismissCount += 1
            }
        }
        .store(in: &cancellables)

        viewModel.process(viewAction: .endCall)
        await waitUntil { hangupJavaScript != nil }

        #expect(widgetDriver.stopCallsCount == 0)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 0)

        try await Task.sleep(for: .milliseconds(50))
        #expect(widgetDriver.stopCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
        #expect(dismissCount == 1)

        let requestID = try hangupRequestID(from: #require(hangupJavaScript))
        viewModel.process(viewAction: .widgetAction(message: hangupAcknowledgement(requestID: requestID)))
        try await Task.sleep(for: .milliseconds(50))

        #expect(widgetDriver.stopCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
        #expect(dismissCount == 1)
    }

    @Test
    @MainActor
    func rejectedHangupAcknowledgementForwardingFallsBackToTeardown() async throws {
        let fixture = makeLifecycleViewModel()
        let viewModel = fixture.viewModel
        let widgetDriver = fixture.widgetDriver
        let elementCallService = fixture.elementCallService
        var hangupJavaScript: String?

        widgetDriver.handleMessageReturnValue = .failure(.driverNotSetup)
        viewModel.context.javaScriptEvaluator = { script in
            guard script.contains(#""action":"im.vector.hangup""#) else { return "ignored" }
            hangupJavaScript = script
            return "scheduled"
        }

        viewModel.process(viewAction: .endCall)
        await waitUntil { hangupJavaScript != nil }
        let requestID = try hangupRequestID(from: #require(hangupJavaScript))
        viewModel.process(viewAction: .widgetAction(message: hangupAcknowledgement(requestID: requestID)))
        await waitUntil { elementCallService.tearDownCallSessionGenerationCallsCount == 1 }

        #expect(widgetDriver.handleMessageCallsCount == 1)
        #expect(widgetDriver.stopCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
    }

    @Test
    @MainActor
    func failedHangupInjectionFallsBackToBoundedTeardown() async {
        let fixture = makeLifecycleViewModel()
        let viewModel = fixture.viewModel
        let widgetDriver = fixture.widgetDriver
        let elementCallService = fixture.elementCallService

        viewModel.context.javaScriptEvaluator = { script in
            guard script.contains(#""action":"im.vector.hangup""#) else { return "ignored" }
            throw CallScreenJunchatTestError.javaScriptEvaluationFailed
        }

        viewModel.process(viewAction: .endCall)
        await waitUntil { elementCallService.tearDownCallSessionGenerationCallsCount == 1 }

        #expect(widgetDriver.stopCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
    }

    @Test
    @MainActor
    func stoppingDuringWidgetSetupDoesNotCreateAnOngoingCall() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        var releaseStart: CheckedContinuation<Result<URL, ElementCallWidgetDriverError>, Never>?
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationClosure = { _, _, _, _, _, _ in
            await withCheckedContinuation { releaseStart = $0 }
        }

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver
        let elementCallService = ElementCallServiceMock(.init())
        let appSettings = AppSettings()
        let viewModel = CallScreenViewModel(elementCallService: elementCallService,
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: ClientProxyMock(.init(deviceID: "device-id")),
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { })

        for _ in 0..<20 where releaseStart == nil {
            await Task.yield()
        }
        #expect(releaseStart != nil)

        viewModel.stop()
        releaseStart?.resume(returning: .success(URL.userDirectory))
        try await Task.sleep(for: .milliseconds(50))

        #expect(elementCallService.registerCallSessionGenerationCallsCount == 1)
        #expect(elementCallService.setupCallSessionRoomIDRoomDisplayNameIncomingCallIdentityGenerationCallsCount == 0)
        #expect(elementCallService.tearDownCallSessionGenerationCallsCount == 1)
        #expect(elementCallService.tearDownCallSessionGenerationReceivedGeneration == elementCallService.registerCallSessionGenerationReceivedGeneration)
        #expect(viewModel.context.viewState.url == nil)
        #expect(widgetDriver.stopCallsCount == 1)
    }

    @Test
    @MainActor
    func outboundCallStartsRingbackAndStopsWhenRemoteMediaConnects() async throws {
        let widgetActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>()
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = widgetActions.eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let appSettings = AppSettings()
        let analytics = AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings)
        let ringbackTonePlayer = CallRingbackTonePlayerMock()

        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark,
                                                                 playConnectedTone: true),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: analytics,
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { },
                                            callRingbackTonePlayer: ringbackTonePlayer)

        _ = viewModel
        try await Task.sleep(for: .milliseconds(100))
        #expect(ringbackTonePlayer.startCallCount == 1)
        #expect(ringbackTonePlayer.stopCallCount == 0)

        viewModel.process(viewAction: .widgetAction(message: #"{"api":"junchat","action":"call_connected"}"#))
        try await Task.sleep(for: .milliseconds(100))

        #expect(ringbackTonePlayer.startCallCount == 1)
        #expect(ringbackTonePlayer.stopCallCount == 1)

        for (index, message) in [
            #"{"api":"junchat","action":"call_connected","version":null}"#,
            #"{"api":"junchat","action":"call_connected","version":"1"}"#,
            #"{"api":"junchat","action":"call_connected","version":1.5}"#,
            #"{"api":"junchat","action":"call_connected","version":{}}"#,
            #"{"api":"junchat","action":"call_connected","version":2}"#
        ].enumerated() {
            viewModel.process(viewAction: .widgetAction(message: message))
            await waitUntil { widgetDriver.handleMessageCallsCount == index + 1 }
        }

        #expect(widgetDriver.handleMessageCallsCount == 5)
    }

    @Test
    @MainActor
    func voiceCallRoutesToNativeEarpieceWhenMediaCaptureIsGranted() {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let audioSession = AudioSessionMock()
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: AppSettings(),
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: AppSettings()),
                                            callAudioSessionController: .init(audioSession: audioSession),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { })

        viewModel.process(viewAction: .mediaCapturePermissionGranted)

        #expect(audioSession.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
    }

    @Test
    @MainActor
    func remoteMediaConnectedReassertsSelectedNativeEarpieceRoute() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let audioSession = AudioSessionMock()
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: AppSettings(),
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: AppSettings()),
                                            callAudioSessionController: .init(audioSession: audioSession),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { })

        viewModel.process(viewAction: .mediaCapturePermissionGranted)
        let overrideCountAfterMediaCapture = audioSession.overrideOutputAudioPortCallsCount

        viewModel.process(viewAction: .widgetAction(message: #"{"api":"junchat","action":"call_connected"}"#))
        try await Task.sleep(for: .milliseconds(100))

        #expect(audioSession.overrideOutputAudioPortCallsCount > overrideCountAfterMediaCapture)
        #expect(audioSession.overrideOutputAudioPortReceivedPortOverride == AVAudioSession.PortOverride.none)
    }

    @Test
    @MainActor
    func becomingActiveReassertsCurrentAudioEnabledStateToElementCall() async throws {
        let widgetActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>()
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = widgetActions.eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: AppSettings(),
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: AppSettings()),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { })

        var evaluatedJavaScript = [String]()
        viewModel.context.javaScriptEvaluator = { script in
            evaluatedJavaScript.append(script)
            return "ok"
        }

        widgetActions.send(.mediaStateChanged(audioEnabled: false, videoEnabled: true))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(evaluatedJavaScript.contains {
            $0.contains(#""action":"io.element.device_mute""#) &&
                $0.contains(#""audio_enabled":false"#)
        })
    }

    @Test
    @MainActor
    func remoteMediaConnectedRetriesPictureInPictureWhileAppIsInactive() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: true,
                                            appHooks: AppHooks(),
                                            appSettings: AppSettings(),
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: AppSettings()),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { },
                                            applicationStateProvider: { .background })

        var pictureInPictureRequests = 0
        viewModel.context.requestPictureInPictureHandler = {
            pictureInPictureRequests += 1
            return .success(())
        }

        viewModel.process(viewAction: .widgetAction(message: #"{"api":"junchat","action":"call_connected"}"#))
        try await Task.sleep(for: .milliseconds(600))

        #expect(pictureInPictureRequests > 0)
    }

    @Test
    @MainActor
    func pictureInPictureRecoveryResumesAsURLAndRequestHandlerBecomeReady() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        var releaseStart: CheckedContinuation<Result<URL, ElementCallWidgetDriverError>, Never>?
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationClosure = { _, _, _, _, _, _ in
            await withCheckedContinuation { releaseStart = $0 }
        }

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver
        let appSettings = AppSettings()
        let callMediaCoordinator = CallMediaCoordinator(voiceOnly: true,
                                                        playConnectedTone: false,
                                                        audioSessionController: .init(audioSession: AudioSessionMock()),
                                                        connectedTonePlayer: { },
                                                        ringbackTonePlayer: CallRingbackTonePlayerMock(),
                                                        setProximityMonitoringEnabled: { _ in },
                                                        allowsPictureInPicture: true,
                                                        applicationStateProvider: { .background },
                                                        pictureInPictureRetryDelay: .milliseconds(1),
                                                        pictureInPictureMaxAttempts: 1,
                                                        pictureInPictureMaxReadinessWaits: 1)
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: ClientProxyMock(.init(deviceID: "device-id")),
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: true,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { },
                                            callMediaCoordinator: callMediaCoordinator)

        await waitUntil { releaseStart != nil }
        callMediaCoordinator.schedulePictureInPictureRecovery(reason: .remoteMediaConnected)
        try await Task.sleep(for: .milliseconds(20))

        releaseStart?.resume(returning: .success(.userDirectory))
        await waitUntil { viewModel.context.viewState.url != nil }

        var pictureInPictureRequests = 0
        viewModel.context.requestPictureInPictureHandler = {
            pictureInPictureRequests += 1
            return .success(())
        }
        viewModel.process(viewAction: .pictureInPictureReadinessChanged)
        await waitUntil { pictureInPictureRequests == 1 }

        #expect(pictureInPictureRequests == 1)
        viewModel.stop()
    }

    @Test
    @MainActor
    func transientPictureInPictureReadinessDoesNotConsumeTheAttemptBudget() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(.userDirectory)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver
        let appSettings = AppSettings()
        let callMediaCoordinator = CallMediaCoordinator(voiceOnly: true,
                                                        playConnectedTone: false,
                                                        audioSessionController: .init(audioSession: AudioSessionMock()),
                                                        connectedTonePlayer: { },
                                                        ringbackTonePlayer: CallRingbackTonePlayerMock(),
                                                        setProximityMonitoringEnabled: { _ in },
                                                        allowsPictureInPicture: true,
                                                        applicationStateProvider: { .background },
                                                        pictureInPictureRetryDelay: .milliseconds(1),
                                                        pictureInPictureMaxAttempts: 1,
                                                        pictureInPictureMaxReadinessWaits: 2)
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: ClientProxyMock(.init(deviceID: "device-id")),
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: .homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: true,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { },
                                            callMediaCoordinator: callMediaCoordinator)
        await waitUntil { viewModel.context.viewState.url != nil }

        var isReady = false
        var requests = 0
        viewModel.context.requestPictureInPictureHandler = {
            requests += 1
            return isReady ? .success(()) : .failure(.pictureInPictureNotReady)
        }

        callMediaCoordinator.schedulePictureInPictureRecovery(reason: .remoteMediaConnected)
        await waitUntil { requests == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(requests == 2)

        isReady = true
        viewModel.process(viewAction: .pictureInPictureReadinessChanged)
        await waitUntil { requests == 3 }

        #expect(requests == 3)
        viewModel.stop()
    }

    @Test
    @MainActor
    func failedBackNavigationPictureInPictureKeepsCallVisible() async throws {
        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = Empty().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        let clientProxy = ClientProxyMock(.init(deviceID: "device-id"))
        let viewModel = CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: clientProxy,
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: true,
                                            appHooks: AppHooks(),
                                            appSettings: AppSettings(),
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: AppSettings()),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { })
        var dismissCount = 0
        var minimizedCount = 0
        var cancellables = Set<AnyCancellable>()
        viewModel.actions.sink { action in
            switch action {
            case .dismiss:
                dismissCount += 1
            case .pictureInPictureStarted:
                minimizedCount += 1
            case .pictureInPictureStopped:
                break
            }
        }
        .store(in: &cancellables)
        viewModel.context.requestPictureInPictureHandler = {
            .failure(.pictureInPictureNotAvailable)
        }
        try await Task.sleep(for: .milliseconds(50))

        viewModel.process(viewAction: .navigateBack)
        try await Task.sleep(for: .milliseconds(50))

        #expect(dismissCount == 0)
        #expect(minimizedCount == 0)

        viewModel.process(viewAction: .pictureInPictureStarted)
        #expect(minimizedCount == 1)
    }

    @Test
    func widgetHangupMessagesAreCallEndingActions() throws {
        let data = Data(#"{"api":"fromWidget","action":"im.vector.hangup","widget_id":"widget"}"#.utf8)
        let message = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)

        #expect(message.isCallEndingAction)
    }

    @Test
    func widgetCloseMessagesAreCallEndingActions() throws {
        let data = Data(#"{"api":"fromWidget","action":"io.element.close","widget_id":"widget"}"#.utf8)
        let message = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)

        #expect(message.isCallEndingAction)
    }

    @Test
    func widgetJoinMessagesAreHostHandledAndAcknowledged() throws {
        let data = Data(#"{"api":"fromWidget","widgetId":"widget","requestId":"join-request","action":"io.element.join","data":{}}"#.utf8)
        let message = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)

        #expect(message.isHostHandledAction)
        #expect(!message.isCallEndingAction)

        let response = try #require(message.successResponseJSON())
        let responseData = Data(response.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])

        #expect(object["api"] as? String == "fromWidget")
        #expect(object["action"] as? String == "io.element.join")
        #expect(object["requestId"] as? String == "join-request")
        #expect(object["response"] is [String: Any])
    }

    @Test
    func widgetAlwaysOnScreenMessagesAreHostHandledAndAcknowledged() throws {
        let data = Data(#"{"api":"fromWidget","widgetId":"widget","requestId":"always-on","action":"set_always_on_screen","data":{"value":true}}"#.utf8)
        let message = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)

        #expect(message.isHostHandledAction)

        let response = try #require(message.successResponseJSON())
        #expect(response.contains(#""action":"set_always_on_screen""#))
        #expect(response.contains(#""requestId":"always-on""#))
        #expect(response.contains(#""response":{}"#))
    }

    @Test
    func voiceCallsDefaultToNativeEarpieceWhenBuiltInSpeakerIsCurrentRoute() {
        let javaScript = CallScreenViewModel.junchatAudioOutputJavaScript(portType: .builtInSpeaker,
                                                                          uid: "Speaker",
                                                                          portName: "iPhone Speaker",
                                                                          preferInitialEarpiece: true)

        #expect(javaScript.contains("window.controls.setAvailableAudioDevices"))
        #expect(javaScript.contains("isSpeaker: true"))
        #expect(javaScript.contains("forEarpiece: true"))
        #expect(!javaScript.contains("isEarpiece: true"))
        #expect(javaScript.contains("window.controls.setAudioDevice(\"earpiece-id\")"))
    }

    @Test
    func voiceCallsDefaultToNativeEarpieceWhenBuiltInReceiverIsCurrentRoute() {
        let javaScript = CallScreenViewModel.junchatAudioOutputJavaScript(portType: .builtInReceiver,
                                                                          uid: "Receiver",
                                                                          portName: "iPhone Receiver",
                                                                          preferInitialEarpiece: true)

        #expect(javaScript.contains("window.controls.setAvailableAudioDevices"))
        #expect(javaScript.contains("isSpeaker: true"))
        #expect(javaScript.contains("forEarpiece: true"))
        #expect(!javaScript.contains("isEarpiece: true"))
        #expect(javaScript.contains("window.controls.setAudioDevice(\"earpiece-id\")"))
    }

    @Test
    func nonVoiceCallsKeepTheCurrentSpeakerSelection() {
        let javaScript = CallScreenViewModel.junchatAudioOutputJavaScript(portType: .builtInSpeaker,
                                                                          uid: "Speaker",
                                                                          portName: "iPhone Speaker",
                                                                          preferInitialEarpiece: false)

        #expect(javaScript.contains("window.controls.setAvailableAudioDevices"))
        #expect(javaScript.contains("forEarpiece: true"))
        #expect(!javaScript.contains("isEarpiece: true"))
        #expect(!javaScript.contains("window.controls.setAudioDevice(\"earpiece-id\")"))
    }

    @Test
    func nonBuiltInRoutesDoNotOfferNativeEarpiece() {
        let javaScript = CallScreenViewModel.junchatAudioOutputJavaScript(portType: .headphones,
                                                                          uid: "Headphones",
                                                                          portName: "Headphones",
                                                                          preferInitialEarpiece: true)

        #expect(javaScript.contains("id: \"dummy\""))
        #expect(!javaScript.contains("isEarpiece: true"))
        #expect(!javaScript.contains("window.controls.setAudioDevice(\"earpiece-id\")"))
    }

    private func callMemberMessage(api: String, action: String, requestID: String, sender: String, stateKey: String, content: String, extraData: String = "") -> String {
        """
        {"api":"\(api)","widgetId":"widget","requestId":"\(requestID)","action":"\(action)","data":\(callMemberEvent(sender: sender, stateKey: stateKey, content: content, extraData: extraData))}
        """
    }

    private func callMemberEvent(sender: String, stateKey: String, content: String, extraData: String = "") -> String {
        """
        {"content":\(content),"event_id":"$event","origin_server_ts":1780907472684,"room_id":"!room:junchat.yyzs120.cn","sender":"\(sender)","state_key":"\(stateKey)","type":"org.matrix.msc3401.call.member"\(extraData)}
        """
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        let data = try #require(string.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hangupRequestID(from javaScript: String) throws -> String {
        let object = try hangupRequest(from: javaScript)
        return try #require(object["requestId"] as? String)
    }

    private func hangupRequest(from javaScript: String) throws -> [String: Any] {
        let jsonStart = try #require(javaScript.firstIndex(of: "{"))
        let jsonEnd = try #require(javaScript.lastIndex(of: "}"))
        return try jsonObject(String(javaScript[jsonStart...jsonEnd]))
    }

    private func hangupAcknowledgement(requestID: String) -> String {
        #"{"api":"toWidget","widgetId":"widget","requestId":"\#(requestID)","action":"im.vector.hangup","response":{}}"#
    }

    @MainActor
    private struct LifecycleViewModelFixture {
        let viewModel: CallScreenViewModel
        let widgetDriver: ElementCallWidgetDriverMock
        let elementCallService: ElementCallServiceMock
        let widgetActions: PassthroughSubject<ElementCallWidgetDriverAction, Never>
    }

    @MainActor
    private func makeLifecycleViewModel(hangupDeliveryTimeout: Duration = .seconds(1),
                                        callCloseTimeout: Duration = .seconds(2)) -> LifecycleViewModelFixture {
        let widgetDriver = ElementCallWidgetDriverMock()
        let widgetActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>()
        widgetDriver.underlyingWidgetID = "widget"
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = widgetActions.eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)
        widgetDriver.handleMessageReturnValue = .success(true)

        let roomProxy = JoinedRoomProxyMock(.init(id: "room-id", name: "Call Room"))
        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver
        let elementCallService = ElementCallServiceMock(.init())
        let appSettings = AppSettings()
        let viewModel = CallScreenViewModel(elementCallService: elementCallService,
                                            configuration: .init(roomProxy: roomProxy,
                                                                 clientProxy: ClientProxyMock(.init(deviceID: "device-id")),
                                                                 clientID: "com.heyujk.junchat",
                                                                 elementCallBaseURL: URL.homeDirectory,
                                                                 elementCallBaseURLOverride: nil,
                                                                 voiceOnly: true,
                                                                 colorScheme: .dark),
                                            allowPictureInPicture: false,
                                            appHooks: AppHooks(),
                                            appSettings: appSettings,
                                            analyticsService: AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings),
                                            callConnectedTonePlayer: { },
                                            callEndedTonePlayer: { },
                                            hangupDeliveryTimeout: hangupDeliveryTimeout,
                                            callCloseTimeout: callCloseTimeout)
        return .init(viewModel: viewModel,
                     widgetDriver: widgetDriver,
                     elementCallService: elementCallService,
                     widgetActions: widgetActions)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            guard !condition() else { return }
            await Task.yield()
        }

        #expect(condition(), sourceLocation: sourceLocation)
    }
}

extension CallScreenJunchatTests {
    @Test
    func callWebViewMessageTrustAcceptsMatchingHTTPSMainFrame() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example/room?id=one"))
        let frameURL = try #require(URL(string: "https://call.junchat.example/room/active?id=two"))

        #expect(CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                              frameURL: frameURL,
                                                              securityOrigin: .init(scheme: "https",
                                                                                    host: "call.junchat.example",
                                                                                    port: 443)),
                                                        callURL: callURL))
    }

    @Test
    func callWebViewMessageTrustRejectsChildFrame() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example/room"))

        #expect(!CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: false,
                                                               frameURL: callURL,
                                                               securityOrigin: .init(scheme: "https",
                                                                                     host: "call.junchat.example",
                                                                                     port: 443)),
                                                         callURL: callURL))
    }

    @Test
    func callWebViewMessageTrustRejectsSecurityOriginBoundaryMismatch() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example/room"))

        for (scheme, host, port) in [
            ("http", "call.junchat.example", 80),
            ("https", "embedded.junchat.example", 443),
            ("https", "call.junchat.example", 8443)
        ] {
            #expect(!CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                                   frameURL: callURL,
                                                                   securityOrigin: .init(scheme: scheme,
                                                                                         host: host,
                                                                                         port: port)),
                                                             callURL: callURL))
        }
    }

    @Test
    func callWebViewMessageTrustRejectsFrameURLBoundaryMismatch() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example/room"))

        for frameURLString in [
            "http://call.junchat.example/room",
            "https://embedded.junchat.example/room",
            "https://call.junchat.example:8443/room"
        ] {
            let frameURL = try #require(URL(string: frameURLString))
            #expect(!CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                                   frameURL: frameURL,
                                                                   securityOrigin: .init(scheme: "https",
                                                                                         host: "call.junchat.example",
                                                                                         port: 443)),
                                                             callURL: callURL))
        }
    }

    @Test
    func callWebViewMessageTrustTreatsImplicitAndExplicitDefaultPortsAsTheSameOrigin() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example/room"))
        let frameURL = try #require(URL(string: "https://call.junchat.example:443/room"))

        #expect(CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                              frameURL: frameURL,
                                                              securityOrigin: .init(scheme: "https",
                                                                                    host: "call.junchat.example",
                                                                                    port: 0)),
                                                        callURL: callURL))
    }

    @Test
    func callWebViewMessageTrustAcceptsMatchingNonDefaultPort() throws {
        let callURL = try #require(URL(string: "https://call.junchat.example:8443/room"))

        #expect(CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                              frameURL: callURL,
                                                              securityOrigin: .init(scheme: "https",
                                                                                    host: "call.junchat.example",
                                                                                    port: 8443)),
                                                        callURL: callURL))
    }

    @Test
    func callWebViewMessageTrustAcceptsExactLocalBundleFile() {
        let callURL = URL(fileURLWithPath: "/Applications/JunChat.app/ElementCall/index.html")
        let frameURL = callURL.appending(queryItems: [.init(name: "room", value: "one")])

        #expect(CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                              frameURL: frameURL,
                                                              securityOrigin: .init(scheme: "file",
                                                                                    host: "",
                                                                                    port: 0)),
                                                        callURL: callURL))
    }

    @Test
    func callWebViewMessageTrustRejectsDifferentLocalBundleFile() {
        let callURL = URL(fileURLWithPath: "/Applications/JunChat.app/ElementCall/index.html")
        let frameURL = URL(fileURLWithPath: "/Applications/JunChat.app/ElementCall/embedded.html")

        #expect(!CallWebViewMessageTrustPolicy.isTrusted(.init(isMainFrame: true,
                                                               frameURL: frameURL,
                                                               securityOrigin: .init(scheme: "file",
                                                                                     host: "",
                                                                                     port: 0)),
                                                         callURL: callURL))
    }
}

private enum CallScreenJunchatTestError: Error {
    case javaScriptEvaluationFailed
}

private final class CallScreenJunchatFixtureToken { }

struct RoomScreenCallInvitationTests {
    @Test
    @MainActor
    func ongoingJoinableCallShowsNativeInvitationOverlay() {
        var viewState = RoomScreenViewState(roomAvatar: .room(id: "room", name: "测试用户", avatarURL: nil),
                                            hasOngoingCall: true,
                                            isDirectOneToOneRoom: true,
                                            hasSuccessor: false)
        viewState.isCallingEnabled = true
        viewState.canJoinCall = true
        viewState.isParticipatingInOngoingCall = false

        #expect(viewState.shouldShowActiveCallInvitation)
        #expect(!viewState.shouldShowCallButton)
    }

    @Test
    @MainActor
    func dismissedCallInvitationStaysHiddenWhileCallIsActive() {
        var viewState = RoomScreenViewState(roomAvatar: .room(id: "room", name: "测试用户", avatarURL: nil),
                                            hasOngoingCall: true,
                                            isDirectOneToOneRoom: true,
                                            hasSuccessor: false)
        viewState.isCallingEnabled = true
        viewState.canJoinCall = true
        viewState.hasDismissedActiveCallInvitation = true

        #expect(!viewState.shouldShowActiveCallInvitation)
    }

    @Test
    @MainActor
    func inactiveCallStillShowsStartCallButton() {
        var viewState = RoomScreenViewState(roomAvatar: .room(id: "room", name: "测试用户", avatarURL: nil),
                                            hasOngoingCall: false,
                                            isDirectOneToOneRoom: true,
                                            hasSuccessor: false)
        viewState.isCallingEnabled = true
        viewState.canJoinCall = true

        #expect(!viewState.shouldShowActiveCallInvitation)
        #expect(viewState.shouldShowCallButton)
    }
}

private final class CallRingbackTonePlayerMock: CallRingbackTonePlaying {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}
