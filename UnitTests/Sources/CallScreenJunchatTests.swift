//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
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
    func elementCallBootstrapUsesInjectedLiveKitEndpoint() throws {
        let canaryURL = try #require(URL(string: "https://canary.junchat.yyzs120.cn/livekit/jwt"))

        let script = CallScreen.junchatElementCallBootstrapScript(language: "zh-Hans", liveKitJWTURL: canaryURL)

        #expect(script.contains("livekit_service_url: \"\(canaryURL.absoluteString)\""))
        #expect(!script.contains("livekit_service_url: \"https://junchat.yyzs120.cn/livekit/jwt\""))
    }

    @Test
    func elementCallBootstrapReportsRemoteMediaTrackForConnectedTone() {
        let script = CallScreen.junchatElementCallBootstrapScript(language: "zh-Hans")

        #expect(script.contains("__junchatCallConnectedTonePatched"))
        #expect(script.contains("RTCPeerConnection"))
        #expect(script.contains("track"))
        #expect(script.contains("call_connected"))
        #expect(script.contains("api: \"junchat\""))
        #expect(script.contains("window.webkit.messageHandlers.widgetAction.postMessage"))
    }

    @Test
    func decodedWidgetMessageRecognizesJunchatCallConnectedEvent() throws {
        let message = try #require(try DecodedWidgetMessage.decode(message: #"{"api":"junchat","action":"call_connected"}"#))

        #expect(message.isJunchatCallConnected)
        #expect(!message.hasLoaded)
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
    func callEndedActionDismissesAndPlaysEndedToneOnce() async throws {
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

        viewModel.actions.sink { action in
            if case .dismiss = action {
                dismissCount += 1
            }
        }
        .store(in: &cancellables)

        widgetActions.send(.callEnded)
        widgetActions.send(.callEnded)
        try await Task.sleep(for: .milliseconds(100))

        #expect(endedTonePlayCount == 1)
        #expect(dismissCount == 1)
        #expect(elementCallService.tearDownCallSessionCallsCount == 1)
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
}

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
