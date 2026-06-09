//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import SwiftUI

struct ElementCallWidgetMessage: Codable {
    struct EmptyResponse: Codable { }

    enum Direction: String, Codable {
        case fromWidget
        case toWidget
    }
    
    enum Action: String, Codable {
        case hangup = "im.vector.hangup"
        case close = "io.element.close"
        case join = "io.element.join"
        case mediaState = "io.element.device_mute"
        case setAlwaysOnScreen = "set_always_on_screen"
    }
    
    struct Data: Codable {
        var audioEnabled: Bool?
        var videoEnabled: Bool?
        
        enum CodingKeys: String, CodingKey {
            case audioEnabled = "audio_enabled"
            case videoEnabled = "video_enabled"
        }
    }
    
    let direction: Direction
    let action: Action
    var data: Data = .init()
    
    let widgetId: String
    var requestId = "widgetapi-\(UUID())"
    var response: EmptyResponse?
    
    init(direction: Direction,
         action: Action,
         data: Data = .init(),
         widgetId: String,
         requestId: String = "widgetapi-\(UUID())",
         response: EmptyResponse? = nil) {
        self.direction = direction
        self.action = action
        self.data = data
        self.widgetId = widgetId
        self.requestId = requestId
        self.response = response
    }
    
    var isCallEndingAction: Bool {
        action == .hangup || action == .close
    }

    var isHostHandledAction: Bool {
        switch action {
        case .hangup, .close, .join, .mediaState, .setAlwaysOnScreen:
            return true
        }
    }

    func successResponseJSON() -> String? {
        var message = self
        message.response = .init()

        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return json
    }
    
    enum CodingKeys: String, CodingKey {
        case direction = "api"
        case action
        case data
        case widgetId
        case requestId
        case response
    }

    enum LegacyCodingKeys: String, CodingKey {
        case widgetId = "widget_id"
        case requestId = "request_id"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        direction = try container.decode(Direction.self, forKey: .direction)
        action = try container.decode(Action.self, forKey: .action)
        data = try container.decodeIfPresent(Data.self, forKey: .data) ?? .init()
        widgetId = try container.decodeIfPresent(String.self, forKey: .widgetId) ?? legacyContainer.decodeIfPresent(String.self, forKey: .widgetId) ?? ""
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId) ?? legacyContainer.decodeIfPresent(String.self, forKey: .requestId) ?? "widgetapi-\(UUID())"
        response = try container.decodeIfPresent(EmptyResponse.self, forKey: .response)
    }
}

final class ElementCallWidgetDriver: WidgetCapabilitiesProvider, ElementCallWidgetDriverProtocol {
    private let room: RoomProtocol
    private let deviceID: String
    
    private var widgetDriver: WidgetDriverAndHandle?
    
    let widgetID = UUID().uuidString
    let messagePublisher = PassthroughSubject<String, Never>()
    
    private let actionsSubject: PassthroughSubject<ElementCallWidgetDriverAction, Never> = .init()
    var actions: AnyPublisher<ElementCallWidgetDriverAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(room: RoomProtocol, deviceID: String) {
        self.room = room
        self.deviceID = deviceID
    }
    
    func start(baseURL: URL,
               clientID: String,
               colorScheme: ColorScheme,
               voiceOnly: Bool,
               rageshakeURL: String?,
               analyticsConfiguration: ElementCallAnalyticsConfiguration?) async -> Result<URL, ElementCallWidgetDriverError> {
        guard let room = room as? Room else {
            return .failure(.roomInvalid)
        }
        
        async let useEncryption = (try? room.latestEncryptionState() == .encrypted) ?? false
        async let intent = room.joinCallIntent(voiceOnly: voiceOnly)
        
        let widgetSettings: WidgetSettings
        do {
            widgetSettings = try await newVirtualElementCallWidget(props: .init(elementCallUrl: baseURL.absoluteString,
                                                                                widgetId: widgetID,
                                                                                parentUrl: nil,
                                                                                fontScale: nil,
                                                                                font: nil,
                                                                                encryption: useEncryption ? .perParticipantKeys : .unencrypted,
                                                                                posthogUserId: nil,
                                                                                posthogApiHost: analyticsConfiguration?.posthogAPIHost,
                                                                                posthogApiKey: analyticsConfiguration?.posthogAPIKey,
                                                                                rageshakeSubmitUrl: rageshakeURL,
                                                                                sentryDsn: analyticsConfiguration?.sentryDSN,
                                                                                
                                                                                sentryEnvironment: nil),
                                                                   config: .init(intent: intent))
        } catch {
            MXLog.error("Failed to build widget settings: \(error)")
            return .failure(.failedBuildingWidgetSettings)
        }
        
        let languageTag = Bundle.junchatElementCallLanguage
        let theme = colorScheme == .light ? "light" : "dark"
        
        let urlString: String
        do {
            urlString = try await generateWebviewUrl(widgetSettings: widgetSettings, room: room,
                                                     props: .init(clientId: clientID,
                                                                  languageTag: languageTag,
                                                                  theme: theme))
        } catch {
            MXLog.error("Failed to generate web view URL: \(error)")
            return .failure(.failedBuildingCallURL)
        }
        
        guard let url = URL(string: urlString) else {
            return .failure(.failedParsingCallURL)
        }
        
        let widgetDriver: WidgetDriverAndHandle
        do {
            widgetDriver = try makeWidgetDriver(settings: widgetSettings)
        } catch {
            MXLog.error("Failed to build widget driver: \(error)")
            return .failure(.failedBuildingWidgetDriver)
        }
        
        self.widgetDriver = widgetDriver
        
        Task.detached { [weak self, widgetDriver, messagePublisher] in
            MXLog.debug("Started message receiving loop")
            
            defer {
                MXLog.debug("Stopped message receiving loop")
            }
            
            while true {
                guard let receivedMessage = await widgetDriver.handle.recv() else {
                    return
                }
                
                messagePublisher.send(receivedMessage)
                MXLog.debug("Received message: \(receivedMessage)")
                
                self?.handleMessageIfNeeded(receivedMessage)
            }
        }
        
        Task.detached { [widgetDriver] in
            MXLog.debug("Started widget driver")
            
            defer {
                MXLog.debug("Stopped widget driver")
            }
            
            await widgetDriver.driver.run(room: room, capabilitiesProvider: self)
        }
        
        return .success(url)
    }
    
    @discardableResult
    func handleMessage(_ message: String) async -> Result<Bool, ElementCallWidgetDriverError> {
        guard let widgetDriver else {
            return .failure(.driverNotSetup)
        }

        if let widgetMessage = decodeHostHandledMessage(message) {
            handleMessageIfNeeded(message)
            if let response = widgetMessage.successResponseJSON() {
                messagePublisher.send(response)
                MXLog.debug("Acknowledged host-handled Element Call message: \(response)")
            } else {
                MXLog.error("Failed to build response for host-handled Element Call message")
            }
            return .success(true)
        }
        
        let result = await widgetDriver.handle.send(msg: message)
        MXLog.debug("Sent message: \(message) with result: \(result)")
        
        handleMessageIfNeeded(message)
        
        return .success(result)
    }
    
    // MARK: - WidgetCapabilitiesProvider
    
    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: room.ownUserId(), ownDeviceId: deviceID)
    }
    
    // MARK: - Private

    private func decodeHostHandledMessage(_ message: String) -> ElementCallWidgetMessage? {
        guard let data = message.data(using: .utf8),
              let widgetMessage = try? JSONDecoder().decode(ElementCallWidgetMessage.self, from: data),
              widgetMessage.direction == .fromWidget,
              widgetMessage.isHostHandledAction else {
            return nil
        }

        return widgetMessage
    }
    
    func handleMessageIfNeeded(_ message: String) {
        guard let data = message.data(using: .utf8) else {
            return
        }
        
        do {
            let widgetMessage = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)
            if widgetMessage.direction == .fromWidget {
                if widgetMessage.isCallEndingAction {
                    actionsSubject.send(.callEnded)
                    return
                }
                
                switch widgetMessage.action {
                case .hangup, .close, .join, .setAlwaysOnScreen:
                    break
                case .mediaState:
                    guard let audioEnabled = widgetMessage.data.audioEnabled,
                          let videoEnabled = widgetMessage.data.videoEnabled else {
                        MXLog.error("Media state change messages should contain info data")
                        return
                    }
                    
                    actionsSubject.send(.mediaStateChanged(audioEnabled: audioEnabled, videoEnabled: videoEnabled))
                }
            }
        } catch {
            // Not all actions are supported
            MXLog.verbose("Failed processing widget message with error: \(error)")
        }
    }
}
