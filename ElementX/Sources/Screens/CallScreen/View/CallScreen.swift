//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import EmbeddedElementCall
import SFSafeSymbols
import SwiftUI
import WebKit

struct CallScreen: View {
    @ObservedObject var context: CallScreenViewModel.Context

    static func junchatElementCallBootstrapScript(language: String = Bundle.junchatElementCallLanguage) -> String {
        CallView.Coordinator.junchatLiveKitBootstrapScript(language: language)
    }

    var body: some View {
        ElementNavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar { toolbar }
        }
        .alert(item: $context.alertInfo)
    }

    @ViewBuilder
    var content: some View {
        if context.viewState.url == nil {
            ProgressView()
        } else {
            CallView(url: context.viewState.url, viewModelContext: context)
                // This URL is stable, forces view reloads if this representable is ever reused for another url
                .id(context.viewState.url)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { context.send(viewAction: .navigateBack) } label: {
                Image(systemSymbol: .chevronBackward)
                    .fontWeight(.semibold)
            }
        }
    }
}

private struct CallView: UIViewRepresentable {
    /// The top-level view this representable displays. It wraps the web view when picture in picture isn't running.
    typealias WebViewWrapper = UIView

    let url: URL?
    let viewModelContext: CallScreenViewModel.Context

    func makeUIView(context: Context) -> WebViewWrapper {
        context.coordinator.webViewWrapper
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModelContext: viewModelContext)
    }

    func updateUIView(_ callWebView: WebViewWrapper, context: Context) {
        if let url {
            context.coordinator.load(url)
        }
    }

    @MainActor
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, AVPictureInPictureControllerDelegate {
        private weak var viewModelContext: CallScreenViewModel.Context?
        private let certificateValidator: CertificateValidatorHookProtocol

        private var webView: WKWebView!
        private var pictureInPictureController: AVPictureInPictureController?
        private let pictureInPictureViewController: AVPictureInPictureVideoCallViewController
        private var routePickerView: AVRoutePickerView!

        /// The view to be shown in the app. This will contain the web view when picture in picture isn't running.
        let webViewWrapper = WebViewWrapper(frame: .zero)

        private var url: URL!

        fileprivate static func junchatLiveKitBootstrapScript(language: String = Bundle.junchatElementCallLanguage) -> String {
            """
        (() => {
            const junchatLanguage = "\(language)";
            const junchatConfig = {
                livekit: {
                    livekit_service_url: "https://junchat.yyzs120.cn/livekit/jwt"
                },
                matrix_rtc_session: {
                    wait_for_key_rotation_ms: 5000,
                    delayed_leave_event_restart_ms: 20000,
                    delayed_leave_event_delay_ms: 120000
                }
            };
            const junchatTranslations = {
                "zh-Hans": {
                    common: {
                        back: "返回",
                        next: "下一步",
                        preferences: "偏好",
                        reaction: "回应",
                        reactions: "回应",
                        reconnecting: "正在重新连接……"
                    },
                    handset: {
                        overlay_back_button: "返回扬声器模式",
                        overlay_description: "仅在使用 App 时生效",
                        overlay_title: "听筒模式"
                    },
                    settings: {
                        audio_tab: {
                            effect_volume_description: "调整回应和举手效果的播放音量。",
                            effect_volume_label: "音效音量"
                        },
                        background_blur_header: "背景",
                        background_blur_label: "模糊视频背景",
                        blur_not_supported_by_browser: "（此设备不支持背景模糊。）",
                        devices: {
                            camera: "摄像头",
                            camera_numbered: "摄像头 {{n}}",
                            change_device_button: "切换音频设备",
                            default: "默认",
                            default_named: "默认 <2>({{name}})</2>",
                            handset: "听筒",
                            loudspeaker: "扬声器",
                            microphone: "麦克风",
                            microphone_numbered: "麦克风 {{n}}",
                            speaker: "扬声器",
                            speaker_numbered: "扬声器 {{n}}"
                        },
                        preferences_tab: {
                            developer_mode_label: "开发者模式",
                            developer_mode_label_description: "启用开发者模式并显示开发者设置标签。",
                            introduction: "你可以在这里配置更多选项，改善通话体验。",
                            reactions_play_sound_description: "通话中有人发送回应时播放音效。",
                            reactions_play_sound_label: "播放回应音效",
                            reactions_show_description: "通话中有人发送回应时显示动画。",
                            reactions_show_label: "显示回应",
                            show_hand_raised_timer_description: "参与者举手时显示计时器。",
                            show_hand_raised_timer_label: "显示举手时长"
                        }
                    },
                    video_tile: {
                        always_show: "始终显示",
                        call_ended: "通话已结束",
                        calling: "正在呼叫……",
                        camera_starting: "视频加载中……",
                        collapse: "收起",
                        expand: "展开",
                        muted_for_me: "已为我静音",
                        screen_share_volume: "屏幕共享音量",
                        waiting_for_media: "正在等待媒体……"
                    }
                },
                "zh-Hant": {
                    common: {
                        analytics: "分析",
                        back: "返回",
                        next: "下一步",
                        options: "選項",
                        preferences: "偏好",
                        reaction: "回應",
                        reactions: "回應",
                        reconnecting: "正在重新連線…"
                    },
                    handset: {
                        overlay_back_button: "返回揚聲器模式",
                        overlay_description: "僅在使用 App 時生效",
                        overlay_title: "聽筒模式"
                    },
                    settings: {
                        audio_tab: {
                            effect_volume_description: "調整回應和舉手效果的播放音量。",
                            effect_volume_label: "音效音量"
                        },
                        background_blur_header: "背景",
                        background_blur_label: "模糊視訊背景",
                        blur_not_supported_by_browser: "（此裝置不支援背景模糊。）",
                        devices: {
                            camera: "相機",
                            camera_numbered: "相機 {{n}}",
                            change_device_button: "切換語音裝置",
                            default: "預設",
                            default_named: "預設 <2>({{name}})</2>",
                            handset: "聽筒",
                            loudspeaker: "揚聲器",
                            microphone: "麥克風",
                            microphone_numbered: "麥克風 {{n}}",
                            speaker: "揚聲器",
                            speaker_numbered: "揚聲器 {{n}}"
                        },
                        preferences_tab: {
                            developer_mode_label: "開發者模式",
                            developer_mode_label_description: "啟用開發者模式並顯示開發者設定分頁。",
                            introduction: "你可以在這裡設定更多選項，改善通話體驗。",
                            reactions_play_sound_description: "通話中有人傳送回應時播放音效。",
                            reactions_play_sound_label: "播放回應音效",
                            reactions_show_description: "通話中有人傳送回應時顯示動畫。",
                            reactions_show_label: "顯示回應",
                            show_hand_raised_timer_description: "參與者舉手時顯示計時器。",
                            show_hand_raised_timer_label: "顯示舉手時長"
                        }
                    },
                    video_tile: {
                        always_show: "一律顯示",
                        call_ended: "通話已結束",
                        calling: "正在呼叫…",
                        camera_starting: "視訊載入中…",
                        collapse: "收起",
                        expand: "展開",
                        mute_for_me: "為我靜音",
                        muted_for_me: "已為我靜音",
                        screen_share_volume: "螢幕分享音量",
                        volume: "音量",
                        waiting_for_media: "正在等待媒體…"
                    }
                }
            };
            const junchatTextReplacements = {
                "zh-Hans": {
                    "Calling...": "正在呼叫...",
                    "Calling…": "正在呼叫…",
                    "Handset Mode": "听筒模式",
                    "Only works while using app": "仅在使用 App 时生效",
                    "Back to Speaker Mode": "返回扬声器模式",
                    "Audio": "音频",
                    "Video": "视频",
                    "Feedback": "反馈",
                    "Change audio device": "切换音频设备",
                    "Speaker": "扬声器",
                    "Loudspeaker": "扬声器",
                    "Handset": "听筒",
                    "Microphone": "麦克风",
                    "Camera": "摄像头",
                    "Sound effect volume": "音效音量",
                    "Adjust the volume at which reactions and hand raised effects play.": "调整回应和举手效果的播放音量。",
                    "Preferences": "偏好"
                },
                "zh-Hant": {
                    "Calling...": "正在呼叫...",
                    "Calling…": "正在呼叫…",
                    "Handset Mode": "聽筒模式",
                    "Only works while using app": "僅在使用 App 時生效",
                    "Back to Speaker Mode": "返回揚聲器模式",
                    "Audio": "語音",
                    "Video": "視訊",
                    "Feedback": "回饋",
                    "Change audio device": "切換語音裝置",
                    "Speaker": "揚聲器",
                    "Loudspeaker": "揚聲器",
                    "Handset": "聽筒",
                    "Microphone": "麥克風",
                    "Camera": "相機",
                    "Sound effect volume": "音效音量",
                    "Adjust the volume at which reactions and hand raised effects play.": "調整回應和舉手效果的播放音量。",
                    "Preferences": "偏好"
                }
            };

            const deepMerge = (target, source) => {
                Object.entries(source).forEach(([key, value]) => {
                    if (value && typeof value === "object" && !Array.isArray(value)) {
                        target[key] = deepMerge(target[key] && typeof target[key] === "object" ? target[key] : {}, value);
                    } else {
                        target[key] = value;
                    }
                });
                return target;
            };

            const installJunchatSdpDiagnostics = () => {
                if (window.__junchatSdpDiagnosticsPatched) {
                    return;
                }
                if (typeof RTCPeerConnection === "undefined") {
                    window.setTimeout(installJunchatSdpDiagnostics, 250);
                    return;
                }

                window.__junchatSdpDiagnosticsPatched = true;
                const normalizeJunchatRemoteSdp = (description) => {
                    const sdp = description && description.sdp;
                    if (!sdp || typeof sdp !== "string") {
                        return description;
                    }

                    const normalizedSdp = sdp
                        .split(/\\r?\\n/)
                        .map((line) => {
                            if (!line.startsWith("a=fmtp:111 ")) {
                                return line;
                            }

                            const params = line
                                .slice("a=fmtp:111 ".length)
                                .split(";")
                                .map((value) => value.trim())
                                .filter((value) => value.length > 0 && value.toLowerCase() !== "usedtx=1");
                            return "a=fmtp:111 " + params.join(";");
                        })
                        .join("\\r\\n");

                    if (normalizedSdp === sdp) {
                        return description;
                    }

                    console.warn("[JunchatSDP] normalized remote SDP opus DTX parameters");
                    return {
                        type: description.type,
                        sdp: normalizedSdp
                    };
                };

                const summarizeSdp = (description) => {
                    const sdp = typeof description === "string" ? description : description && description.sdp;
                    if (!sdp) {
                        return "no-sdp";
                    }

                    const lines = sdp.split(/\\r?\\n/);
                    const media = [];
                    const payloadMap = new Map();
                    let currentMid = "unknown";
                    for (const line of lines) {
                        if (line.startsWith("a=mid:")) {
                            currentMid = line.slice(6);
                        } else if (line.startsWith("m=")) {
                            media.push(line);
                        } else if (line.startsWith("a=rtpmap:") || line.startsWith("a=fmtp:")) {
                            const payload = line.slice(line.indexOf(":") + 1).split(/[ \\t]/)[0];
                            if (!payloadMap.has(payload)) {
                                payloadMap.set(payload, []);
                            }
                            payloadMap.get(payload).push(currentMid + " " + line);
                        }
                    }

                    const duplicatePayloads = Array.from(payloadMap.entries())
                        .filter(([, values]) => values.length > 1)
                        .map(([payload, values]) => payload + " => " + values.join(" || "));

                    return JSON.stringify({
                        type: description && description.type,
                        media,
                        duplicatePayloads
                    });
                };

                const originalSetRemoteDescription = RTCPeerConnection.prototype.setRemoteDescription;
                if (typeof originalSetRemoteDescription === "function") {
                    RTCPeerConnection.prototype.setRemoteDescription = function(description) {
                        const patchedDescription = normalizeJunchatRemoteSdp(description);
                        console.log("[JunchatSDP] setRemoteDescription " + summarizeSdp(patchedDescription));
                        return originalSetRemoteDescription.call(this, patchedDescription).catch((error) => {
                            console.error("[JunchatSDP] setRemoteDescription failed " + summarizeSdp(patchedDescription), error);
                            throw error;
                        });
                    };
                }
            };

            const mergeJunchatConfig = (config) => ({
                ...config,
                livekit: {
                    ...(config && config.livekit ? config.livekit : {}),
                    ...junchatConfig.livekit
                },
                matrix_rtc_session: {
                    ...(config && config.matrix_rtc_session ? config.matrix_rtc_session : {}),
                    ...junchatConfig.matrix_rtc_session
                }
            });

            const replaceJunchatVisibleText = () => {
                const root = document.body || document.documentElement;
                if (!root || !window.NodeFilter) {
                    return;
                }

                const replacements = junchatTextReplacements[junchatLanguage] || junchatTextReplacements["zh-Hans"];
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                const nodes = [];
                while (walker.nextNode()) {
                    nodes.push(walker.currentNode);
                }

                nodes.forEach((node) => {
                    const value = node.nodeValue;
                    if (!value) {
                        return;
                    }

                    const trimmed = value.trim();
                    const replacement = replacements[trimmed] || replacements[trimmed.replace(/\\s+/g, " ")];
                    if (!replacement || replacement === trimmed) {
                        return;
                    }

                    node.nodeValue = value.replace(trimmed, replacement);
                });

                document.querySelectorAll("[aria-label], [title]").forEach((element) => {
                    ["aria-label", "title"].forEach((attribute) => {
                        const value = element.getAttribute(attribute);
                        if (!value) {
                            return;
                        }
                        const replacement = replacements[value.trim()] || replacements[value.trim().replace(/\\s+/g, " ")];
                        if (replacement && replacement !== value) {
                            element.setAttribute(attribute, replacement);
                        }
                    });
                });
            };

            const startJunchatTextObserver = () => {
                replaceJunchatVisibleText();
                const root = document.body || document.documentElement;
                if (!root || typeof MutationObserver === "undefined") {
                    return;
                }

                new MutationObserver(replaceJunchatVisibleText).observe(root, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                window.setInterval(replaceJunchatVisibleText, 1000);
            };

            const installJunchatCallConnectedToneBridge = () => {
                if (window.__junchatCallConnectedTonePatched) {
                    return;
                }
                if (typeof RTCPeerConnection === "undefined") {
                    window.setTimeout(installJunchatCallConnectedToneBridge, 250);
                    return;
                }

                window.__junchatCallConnectedTonePatched = true;
                let hasReportedConnected = false;
                const reportCallConnected = () => {
                    if (hasReportedConnected) {
                        return;
                    }

                    hasReportedConnected = true;
                    try {
                        window.webkit.messageHandlers.widgetAction.postMessage(JSON.stringify({
                            api: "junchat",
                            action: "call_connected"
                        }));
                    } catch (error) {
                        console.warn("Failed to report Junchat call connected event", error);
                    }
                };

                const originalAddEventListener = RTCPeerConnection.prototype.addEventListener;
                if (typeof originalAddEventListener === "function") {
                    RTCPeerConnection.prototype.addEventListener = function(type, listener, options) {
                        if (type !== "track" || typeof listener !== "function") {
                            return originalAddEventListener.call(this, type, listener, options);
                        }

                        const wrappedListener = function(event) {
                            reportCallConnected();
                            return listener.apply(this, arguments);
                        };
                        return originalAddEventListener.call(this, type, wrappedListener, options);
                    };
                }

                const onTrackDescriptor = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, "ontrack");
                if (onTrackDescriptor && onTrackDescriptor.configurable) {
                    Object.defineProperty(RTCPeerConnection.prototype, "ontrack", {
                        configurable: true,
                        enumerable: onTrackDescriptor.enumerable,
                        get: function() {
                            return onTrackDescriptor.get ? onTrackDescriptor.get.call(this) : this.__junchatOnTrack;
                        },
                        set: function(listener) {
                            const wrappedListener = typeof listener === "function" ? function(event) {
                                reportCallConnected();
                                return listener.apply(this, arguments);
                            } : listener;

                            if (onTrackDescriptor.set) {
                                onTrackDescriptor.set.call(this, wrappedListener);
                            } else {
                                this.__junchatOnTrack = wrappedListener;
                            }
                        }
                    });
                }
            };

            try {
                localStorage.setItem("matrix-setting-custom-livekit-url", JSON.stringify(junchatConfig.livekit.livekit_service_url));
                localStorage.setItem("i18nextLng", junchatLanguage);
            } catch (error) {
                console.warn("Failed to persist Junchat LiveKit transport", error);
            }

            try {
                Object.defineProperty(window.navigator, "language", { get: () => junchatLanguage, configurable: true });
                Object.defineProperty(window.navigator, "languages", { get: () => [junchatLanguage], configurable: true });
                Object.defineProperty(Navigator.prototype, "language", { get: () => junchatLanguage, configurable: true });
                Object.defineProperty(Navigator.prototype, "languages", { get: () => [junchatLanguage], configurable: true });
                document.documentElement.lang = junchatLanguage;
            } catch (error) {
                console.warn("Failed to set Junchat Element Call language", error);
            }

            if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", startJunchatTextObserver, { once: true });
            } else {
                startJunchatTextObserver();
            }
            installJunchatSdpDiagnostics();
            installJunchatCallConnectedToneBridge();

            if (!window.__junchatLiveKitConfigPatched && typeof window.fetch === "function") {
                window.__junchatLiveKitConfigPatched = true;
                const originalFetch = window.fetch.bind(window);
                window.fetch = async (input, init) => {
                    const response = await originalFetch(input, init);

                    try {
                        const requestURL = typeof input === "string" ? input : input && input.url;
                        const resolvedURL = new URL(requestURL || response.url || "", window.location.href);
                        const isConfigRequest = resolvedURL.pathname.endsWith("/config.json") || requestURL === "config.json";
                        const translationLocale = resolvedURL.pathname.includes("/zh-Hant-app-") ? "zh-Hant" :
                            resolvedURL.pathname.includes("/zh-Hans-app-") ? "zh-Hans" :
                            resolvedURL.pathname.includes("/en-app-") ? junchatLanguage : null;

                        if (!isConfigRequest && !translationLocale) {
                            return response;
                        }

                        const config = await response.clone().json();
                        const headers = new Headers(response.headers);
                        headers.set("content-type", "application/json");

                        const body = isConfigRequest ? mergeJunchatConfig(config) : deepMerge(config, junchatTranslations[translationLocale]);

                        return new Response(JSON.stringify(body), {
                            status: response.status,
                            statusText: response.statusText,
                            headers
                        });
                    } catch (error) {
                        console.warn("Failed to inject Junchat Element Call config", error);
                        return response;
                    }
                };
            }
        })();
        """
        }

        init(viewModelContext: CallScreenViewModel.Context) {
            self.viewModelContext = viewModelContext
            certificateValidator = viewModelContext.viewState.certificateValidator
            pictureInPictureViewController = AVPictureInPictureVideoCallViewController()
            pictureInPictureViewController.preferredContentSize = CGSize(width: 1920, height: 1080)

            super.init()

            DispatchQueue.main.async { // Avoid `Publishing changes from within view update` warnings
                viewModelContext.javaScriptEvaluator = self.evaluateJavaScript
                viewModelContext.requestPictureInPictureHandler = self.requestPictureInPicture
            }

            let configuration = WKWebViewConfiguration()

            let userContentController = WKUserContentController()
            CallScreenJavaScriptMessageName.allCases.forEach {
                userContentController.add(WKScriptMessageHandlerWrapper(self), name: $0.rawValue)
            }

            // Required to allow a webview that uses file URL to load its own assets
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            configuration.userContentController = userContentController
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true

            let liveKitBootstrapScript = WKUserScript(source: Self.junchatLiveKitBootstrapScript(),
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: false)
            configuration.userContentController.addUserScript(liveKitBootstrapScript)

            if let script = viewModelContext.viewState.script {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
                configuration.userContentController.addUserScript(userScript)
            }

            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.uiDelegate = self
            webView.navigationDelegate = self
            webView.isInspectable = true

            webView.customUserAgent = UserAgentBuilder.makeASCIIUserAgent()

            // https://stackoverflow.com/a/77963877/730924
            webView.allowsLinkPreview = true

            // Try matching Element Call colors
            webView.isOpaque = false
            webView.backgroundColor = .compound.bgCanvasDefault
            webView.scrollView.backgroundColor = .compound.bgCanvasDefault

            // This button is always hidden and is only used to be programmaticaly tapped
            routePickerView = AVRoutePickerView(frame: .zero)
            routePickerView.isHidden = true
            routePickerView.isUserInteractionEnabled = false
            webView.addSubview(routePickerView)

            webViewWrapper.addMatchedSubview(webView)

	            if AVPictureInPictureController.isPictureInPictureSupported() {
	                let pictureInPictureController = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: webViewWrapper,
	                                                                                                   contentViewController: pictureInPictureViewController))
	                pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = true
	                pictureInPictureController.delegate = self
	                self.pictureInPictureController = pictureInPictureController
	                viewModelContext.send(viewAction: .pictureInPictureIsAvailable(pictureInPictureController))
	            }
        }

        func load(_ url: URL) {
            self.url = url
            // The only file URL we allow is the one coming from our own local ElementCall bundle, so it's okay to allow read permission only to our local EC bundle
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: EmbeddedElementCall.bundle.bundleURL)
            } else {
                let request = URLRequest(url: url)
                webView.load(request)
            }
        }

        func evaluateJavaScript(_ script: String) async throws -> Any? {
            // After testing different scenarios it seems that when using async/await version of these
            // methods wkwebView expects JavaScript to return with a value (something other than Void),
            // if there is no value returning from the JavaScript that you evaluate you will have a crash.
            try await withCheckedThrowingContinuation { [weak self] continuaton in
                self?.webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        continuaton.resume(throwing: error)
                    } else {
                        continuaton.resume(returning: result)
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let handlerID = CallScreenJavaScriptMessageName(rawValue: message.name) else {
                return
            }

            switch handlerID {
            case .widgetAction:
                guard let message = message.body as? String else { return }
                viewModelContext?.send(viewAction: .widgetAction(message: message))
            case .showNativeOutputDevicePicker:
                DispatchQueue.main.async {
                    self.tapRoutePickerView()
                }
            case .onOutputDeviceSelect:
                guard let deviceID = message.body as? String else { return }
                viewModelContext?.send(viewAction: .outputDeviceSelected(deviceID: deviceID))
            case .onBackButtonPressed:
                viewModelContext?.send(viewAction: .navigateBack)
            case .forwardLogs:
                guard let body = message.body as? [String: String],
                      let level = body["level"],
                      let logMessage = body["message"] else { return }

                switch level {
                case "log", "debug":
                    MXLog.debug("[ElementCall]: \(logMessage)")
                case "info":
                    MXLog.info("[ElementCall]: \(logMessage)")
                case "warn":
                    MXLog.warning("[ElementCall]: \(logMessage)")
                case "error":
                    MXLog.error("[ElementCall]: \(logMessage)")
                default:
                    break
                }
            }
        }

        /// This function is called by the webview output routing button
        /// it allows to open the OS output selector using the hidden button.
        private func tapRoutePickerView() {
            guard let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton else {
                return
            }

            button.sendActions(for: .touchUpInside)
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            // Allow if the origin is local, otherwise don't allow permissions for domains different than what the call was started on
            guard origin.protocol == "file" || origin.host == url.host else {
                return .deny
            }

            viewModelContext?.send(viewAction: .mediaCapturePermissionGranted)
            return .grant
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            await certificateValidator.respondTo(challenge)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let navigationURL = navigationAction.request.url {
                // Do not allow navigation to a different URL scheme.
                if navigationURL.scheme != url.scheme {
                    return .cancel
                }

                // Allow any content from the main URL.
                if navigationURL.host == url.host {
                    return .allow
                }
            }

            // Additionally allow any embedded content such as captchas.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                return .allow
            }

            // Otherwise the request is invalid.
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            viewModelContext?.send(viewAction: .urlChanged(webView.url))
        }

        // MARK: - Picture in Picture

        func requestPictureInPicture() async -> Result<Void, CallScreenError> {
            guard let pictureInPictureController,
                  pictureInPictureController.isPictureInPicturePossible,
                  case .success(true) = await webViewCanEnterPictureInPicture() else {
                return .failure(.pictureInPictureNotAvailable)
            }

            pictureInPictureController.startPictureInPicture()
            return .success(())
        }

        func stopPictureInPicture() {
            pictureInPictureController?.stopPictureInPicture()
        }

        nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // We move the view via the delegate so it works when you background the app without calling requestPictureInPicture
                pictureInPictureViewController.view.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.enablePip()")
            }
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // Double check that the controller is definitely showing a page that supports picture in picture.
                // This is necessary as it doesn't get checked when backgrounding the app or tapping a notification.
                guard case .success(true) = await webViewCanEnterPictureInPicture() else {
                    MXLog.error("Picture in picture started on a webpage that doesn't support it. Ending the call.")
                    viewModelContext?.send(viewAction: .endCall)
                    return
                }
            }
        }

        nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { await viewModelContext?.send(viewAction: .pictureInPictureWillStop) }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                webViewWrapper.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.disablePip()")
            }
        }

        /// Whether the web view can do picture in picture or not (e.g. it is showing an error or the page didn't load).
        private func webViewCanEnterPictureInPicture() async -> Result<Bool, CallScreenError> {
            do {
                guard let canEnterPictureInPicture = try await evaluateJavaScript("controls.canEnterPip()") as? Bool else {
                    MXLog.error("canEnterPip returned an unexpected value, skipping picture in picture.")
                    return .failure(.pictureInPictureNotAvailable)
                }
                MXLog.info("canEnterPip returned \(canEnterPictureInPicture)")
                return .success(canEnterPictureInPicture)
            } catch {
                MXLog.error("Error checking canEnterPip: \(error)")
                return .failure(.pictureInPictureNotAvailable)
            }
        }
    }

    /// Avoids retain loops between the configuration and webView coordinator
    private class WKScriptMessageHandlerWrapper: NSObject, WKScriptMessageHandler {
        private weak var coordinator: Coordinator?

        init(_ coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.userContentController(userContentController, didReceive: message)
        }
    }
}

// MARK: - Previews

struct CallScreen_Previews: PreviewProvider {
    static let viewModel = {
        let clientProxy = ClientProxyMock()
        clientProxy.deviceID = "call-device-id"

        let roomProxy = JoinedRoomProxyMock()

        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.underlyingMessagePublisher = .init()
        widgetDriver.underlyingActions = PassthroughSubject<ElementCallWidgetDriverAction, Never>().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)

        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        return CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                   configuration: .init(roomProxy: roomProxy,
                                                        clientProxy: clientProxy,
                                                        clientID: "io.element.elementx",
                                                        elementCallBaseURL: "https://call.element.io",
                                                        elementCallBaseURLOverride: nil,
                                                        voiceOnly: false,
                                                        colorScheme: .light),
                                   allowPictureInPicture: false,
                                   appHooks: AppHooks(),
                                   appSettings: ServiceLocator.shared.settings,
                                   analyticsService: ServiceLocator.shared.analytics)
    }()

    static var previews: some View {
        CallScreen(context: viewModel.context)
    }
}
