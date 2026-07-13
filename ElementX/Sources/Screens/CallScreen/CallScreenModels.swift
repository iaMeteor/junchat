//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum CallScreenViewModelAction {
    case pictureInPictureStarted
    case pictureInPictureStopped
    case dismiss
}

struct CallScreenViewState: BindableState {
    let script: String?
    var url: URL?
    
    let certificateValidator: CertificateValidatorHookProtocol
    
    var bindings = Bindings()
}

struct Bindings {
    var javaScriptEvaluator: ((String) async throws -> Any)?
    var requestPictureInPictureHandler: (() async -> Result<Void, CallScreenError>)?
    var stopPictureInPictureHandler: (() -> Void)?
    
    var alertInfo: AlertInfo<UUID>?
}

enum CallScreenViewAction {
    case urlChanged(URL?)
    case pictureInPictureStarted
    case navigateBack
    case pictureInPictureWillStop
    case endCall
    case mediaCapturePermissionGranted
    case outputDeviceSelected(deviceID: String)
    case widgetAction(message: String)
}

enum CallScreenError: Error {
    case pictureInPictureNotAvailable
}

/// Identifies each event handler used by the CallScreen webview
///
/// The names of the enum need to always match the name of the handlers on the webview.
enum CallScreenJavaScriptMessageName: String, CaseIterable {
    /// Widget actions's handler.
    case widgetAction
    /// Used to show the native AVRoutePickerView.
    case showNativeOutputDevicePicker
    /// Used to determine if the webview has selected the earpiece or not.
    case onOutputDeviceSelect
    /// Used to handle the webview back button
    case onBackButtonPressed
    /// Forward logs to the native side for debugging purposes.
    case forwardLogs
    
    private var postMessageScript: String {
        switch self {
        case .widgetAction:
            """
            window.addEventListener(
                "message",
                (event) => {
                    let message = {data: event.data, origin: event.origin};
                    if (message.data.response && message.data.api == "toWidget"
                    || !message.data.response && message.data.api == "fromWidget") {
                        window.webkit.messageHandlers.\(rawValue).postMessage(JSON.stringify(message.data));
                    } else {
                        console.log("-- skipped event handling by the client because it is send from the client itself.");
                    }
                },
                false,
            );
            """
        case .showNativeOutputDevicePicker:
            """
            window.controls.\(rawValue) = () => {
                window.webkit.messageHandlers.\(rawValue).postMessage("");
            };
            """
        case .onOutputDeviceSelect:
            """
            window.controls.\(rawValue) = (id) => {
                window.webkit.messageHandlers.\(rawValue).postMessage(id);
            };
            """
        case .onBackButtonPressed:
            """
            window.controls.\(rawValue) = () => {
                window.webkit.messageHandlers.\(rawValue).postMessage("");
            }
            """
        case .forwardLogs:
            """
            (function() {
                function forwardLog(level, args) {
                    const message = Array.from(args).map(a => {
                        try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                        catch(e) { return String(a); }
                    }).join(' ');
                    window.webkit.messageHandlers.\(rawValue).postMessage({ level: level, message: message });
                }
                ['log', 'debug', 'info', 'warn', 'error'].forEach(function(level) {
                    const original = console[level].bind(console);
                    console[level] = function(...args) {
                        original(...args);
                        forwardLog(level, args);
                    };
                });
            })();
            """
        }
    }
    
    static var allCasesInjectionScript: String {
        allCases.map(\.postMessageScript).joined(separator: "\n")
    }
}

struct DecodedWidgetMessage: Decodable {
    private static let decoder = JSONDecoder()
    private static let contentLoadedAction = "content_loaded"
    private static let fromWidget = "fromWidget"
    private static let junchatAPI = "junchat"
    private static let junchatCallConnectedAction = "call_connected"
    
    let action: String?
    let api: String?
    
    static func decode(message: String) throws -> DecodedWidgetMessage? {
        guard let data = message.data(using: .utf8) else {
            return nil
        }
        return try decoder.decode(DecodedWidgetMessage.self, from: data)
    }
    
    var hasLoaded: Bool {
        action == Self.contentLoadedAction && api == Self.fromWidget
    }

    var isJunchatCallConnected: Bool {
        action == Self.junchatCallConnectedAction && api == Self.junchatAPI
    }
}

enum JunchatCallMemberWidgetMessageFilter {
    enum ToWidgetResult {
        case forward(String)
        case acknowledge(String)
    }

    enum FromWidgetResult {
        case forward
        case acknowledge(String)
    }

    private static let toWidgetAPI = "toWidget"
    private static let sendEventAction = "send_event"
    private static let updateStateAction = "update_state"
    private static let callMemberTypes = ["org.matrix.msc3401.call.member", "m.call.member"]

    static func fromWidgetResult(for message: String, ownUserID: String, deviceID: String) -> FromWidgetResult {
        .forward
    }

    static func toWidgetResult(for message: String, ownUserID: String, deviceID: String) -> ToWidgetResult {
        guard var object = parseJSONObject(message),
              object["api"] as? String == toWidgetAPI,
              let action = object["action"] as? String,
              let data = object["data"] as? [String: Any] else {
            return .forward(message)
        }

        if action == sendEventAction, isOwnEmptyCallMemberEvent(data, ownUserID: ownUserID, deviceID: deviceID) {
            return acknowledgeOrForward(object: object, fallback: message)
        }

        var mutableData = data
        guard action == updateStateAction,
              let state = mutableData["state"] as? [[String: Any]] else {
            return .forward(message)
        }

        let filteredState = state.filter { !isOwnEmptyCallMemberEvent($0, ownUserID: ownUserID, deviceID: deviceID) }
        guard filteredState.count != state.count else {
            return .forward(message)
        }

        if filteredState.isEmpty {
            return acknowledgeOrForward(object: object, fallback: message)
        }

        mutableData["state"] = filteredState
        object["data"] = mutableData
        return .forward(jsonString(from: object) ?? message)
    }

    private static func acknowledgeOrForward(object: [String: Any], fallback: String) -> ToWidgetResult {
        guard let response = successResponseJSON(for: object) else {
            return .forward(fallback)
        }

        return .acknowledge(response)
    }

    private static func isOwnEmptyCallMemberEvent(_ event: [String: Any], ownUserID: String, deviceID: String) -> Bool {
        guard let type = event["type"] as? String,
              callMemberTypes.contains(type),
              let content = event["content"] as? [String: Any],
              content.isEmpty else {
            return false
        }

        let senderMatches = (event["sender"] as? String).map { $0 == ownUserID } ?? true
        guard senderMatches else {
            return false
        }

        guard let stateKey = event["state_key"] as? String else {
            return false
        }

        return stateKey == ownUserID ||
            stateKey == "_\(ownUserID)_\(deviceID)_m.call" ||
            stateKey == "\(ownUserID)_\(deviceID)_m.call"
    }

    private static func successResponseJSON(for object: [String: Any]) -> String? {
        var response = object
        response["response"] = [String: Any]()
        return jsonString(from: response)
    }

    private static func parseJSONObject(_ message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }
}
