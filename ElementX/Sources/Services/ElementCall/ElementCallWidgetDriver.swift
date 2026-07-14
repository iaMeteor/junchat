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
import MatrixSDKFFI
import SwiftUI

protocol ElementCallWidgetDriverRuntimeProtocol: AnyObject, Sendable {
    func run() async
    func receive() async -> String?
    func send(message: String) async -> Bool
    func stop()
}

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

final class ElementCallWidgetDriver: ElementCallWidgetDriverProtocol, @unchecked Sendable {
    struct Session {
        let url: URL
        let runtime: ElementCallWidgetDriverRuntimeProtocol
    }

    private struct RuntimeResources {
        let runtime: ElementCallWidgetDriverRuntimeProtocol
        let receiveTask: Task<Void, Never>?
        let runTask: Task<Void, Never>?
    }

    typealias SessionBuilder = () async -> Result<Session, ElementCallWidgetDriverError>

    private let room: RoomProtocol
    private let capabilitiesProvider: ElementCallWidgetCapabilitiesProvider
    private let sessionBuilder: SessionBuilder?

    private let lifecycleLock = NSRecursiveLock()
    private var runtime: ElementCallWidgetDriverRuntimeProtocol?
    private var receiveTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var hasStopped = false
    
    let widgetID = UUID().uuidString
    let messagePublisher = PassthroughSubject<String, Never>()
    
    private let actionsSubject: PassthroughSubject<ElementCallWidgetDriverAction, Never> = .init()
    var actions: AnyPublisher<ElementCallWidgetDriverAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(room: RoomProtocol, deviceID: String, sessionBuilder: SessionBuilder? = nil) {
        self.room = room
        capabilitiesProvider = .init(room: room, deviceID: deviceID)
        self.sessionBuilder = sessionBuilder
    }

    deinit {
        stop()
    }
    
    static func skipLobbyOverride(voiceOnly: Bool, isDirect: Bool) -> Bool? {
        voiceOnly && !isDirect ? true : nil
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

        let sessionResult = if let sessionBuilder {
            await sessionBuilder()
        } else {
            await buildSession(room: room,
                               baseURL: baseURL,
                               clientID: clientID,
                               colorScheme: colorScheme,
                               voiceOnly: voiceOnly,
                               rageshakeURL: rageshakeURL,
                               analyticsConfiguration: analyticsConfiguration)
        }

        guard !Task.isCancelled else {
            if case .success(let session) = sessionResult {
                session.runtime.stop()
            }
            return .failure(.cancelled)
        }

        switch sessionResult {
        case .success(let session):
            return start(session: session)
        case .failure(let error):
            return .failure(error)
        }
    }

    func stop() {
        let resources = lifecycleLock.withLock { () -> RuntimeResources? in
            guard !hasStopped else {
                return nil
            }

            hasStopped = true
            guard let runtime else {
                return nil
            }

            let resources = RuntimeResources(runtime: runtime, receiveTask: receiveTask, runTask: runTask)
            self.runtime = nil
            receiveTask = nil
            runTask = nil
            return resources
        }

        resources?.receiveTask?.cancel()
        resources?.runTask?.cancel()
        resources?.runtime.stop()
    }

    @discardableResult
    func handleMessage(_ message: String) async -> Result<Bool, ElementCallWidgetDriverError> {
        guard let runtime = lifecycleLock.withLock({ hasStopped ? nil : runtime }) else {
            return .failure(.driverNotSetup)
        }

        if let widgetMessage = decodeHostHandledMessage(message) {
            let response = widgetMessage.successResponseJSON()
            guard withActiveRuntime(runtime, {
                handleMessageIfNeeded(message)
                if let response {
                    messagePublisher.send(response)
                }
            }) else {
                return .failure(.cancelled)
            }

            if let response {
                MXLog.debug("Acknowledged host-handled Element Call message: \(CallDiagnostics.jsonSummary(response))")
            } else {
                MXLog.error("Failed to build response for host-handled Element Call message")
            }
            return .success(true)
        }

        let result = await runtime.send(message: message)
        MXLog.debug("Sent widget message: \(CallDiagnostics.jsonSummary(message)) accepted=\(result)")

        guard withActiveRuntime(runtime, { handleMessageIfNeeded(message) }) else {
            return .failure(.cancelled)
        }

        return .success(result)
    }

    // MARK: - Private

    private func buildSession(room: Room,
                              baseURL: URL,
                              clientID: String,
                              colorScheme: ColorScheme,
                              voiceOnly: Bool,
                              rageshakeURL: String?,
                              analyticsConfiguration: ElementCallAnalyticsConfiguration?) async -> Result<Session, ElementCallWidgetDriverError> {
        async let useEncryption = (try? room.latestEncryptionState() == .encrypted) ?? false
        async let intent = room.joinCallIntent(voiceOnly: voiceOnly)
        async let isDirect = room.isDirect()

        let widgetSettings: WidgetSettings
        do {
            let skipLobby = await Self.skipLobbyOverride(voiceOnly: voiceOnly, isDirect: isDirect)
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
                                                                   config: .init(intent: intent,
                                                                                 skipLobby: skipLobby))
        } catch {
            MXLog.error("Failed to build widget settings: \(CallDiagnostics.errorSummary(error))")
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
            MXLog.error("Failed to generate web view URL: \(CallDiagnostics.errorSummary(error))")
            return .failure(.failedBuildingCallURL)
        }
        
        guard let url = URL(string: urlString) else {
            return .failure(.failedParsingCallURL)
        }

        let sdkDriver: WidgetDriverAndHandle
        do {
            sdkDriver = try makeWidgetDriver(settings: widgetSettings)
        } catch {
            MXLog.error("Failed to build widget driver: \(CallDiagnostics.errorSummary(error))")
            return .failure(.failedBuildingWidgetDriver)
        }

        let runtime = MatrixElementCallWidgetDriverRuntime(sdkDriver: sdkDriver,
                                                           room: room,
                                                           capabilitiesProvider: capabilitiesProvider)
        return .success(.init(url: url, runtime: runtime))
    }

    private func start(session: Session) -> Result<URL, ElementCallWidgetDriverError> {
        let result: Result<URL, ElementCallWidgetDriverError> = lifecycleLock.withLock {
            guard !hasStopped, !Task.isCancelled else {
                return .failure(.cancelled)
            }

            let runtime = session.runtime
            self.runtime = runtime
            receiveTask = Task.detached { [weak self, runtime] in
                MXLog.debug("Started message receiving loop")

                defer {
                    MXLog.debug("Stopped message receiving loop")
                }

                while !Task.isCancelled {
                    guard let receivedMessage = await runtime.receive() else {
                        return
                    }

                    guard self?.publishReceivedMessage(receivedMessage, from: runtime) == true else {
                        return
                    }

                    MXLog.debug("Received widget message: \(CallDiagnostics.jsonSummary(receivedMessage))")
                }
            }

            runTask = Task.detached { [runtime] in
                MXLog.debug("Started widget driver")

                defer {
                    MXLog.debug("Stopped widget driver")
                }

                await runtime.run()
            }

            return .success(session.url)
        }

        if case .failure = result {
            session.runtime.stop()
        }
        return result
    }

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
                    sendActionIfActive(.callEnded)
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
                    
                    sendActionIfActive(.mediaStateChanged(audioEnabled: audioEnabled, videoEnabled: videoEnabled))
                }
            }
        } catch {
            // Not all actions are supported
            MXLog.verbose("Failed processing widget message: \(CallDiagnostics.errorSummary(error))")
        }
    }

    private func publishReceivedMessage(_ message: String, from runtime: ElementCallWidgetDriverRuntimeProtocol) -> Bool {
        withActiveRuntime(runtime) {
            messagePublisher.send(message)
            handleMessageIfNeeded(message)
        }
    }

    private func sendActionIfActive(_ action: ElementCallWidgetDriverAction) {
        lifecycleLock.withLock {
            guard !hasStopped else { return }
            actionsSubject.send(action)
        }
    }

    private func withActiveRuntime(_ expectedRuntime: ElementCallWidgetDriverRuntimeProtocol,
                                   _ operation: () -> Void) -> Bool {
        lifecycleLock.withLock {
            guard !hasStopped, runtime === expectedRuntime else {
                return false
            }
            operation()
            return true
        }
    }
}

struct ElementCallRustFutureOperations: @unchecked Sendable {
    let poll: (UInt64, UInt64) -> Void
    let cancel: (UInt64) -> Void
    let free: (UInt64) -> Void
}

struct ElementCallRustFuture: @unchecked Sendable {
    let handle: UInt64
    let operations: ElementCallRustFutureOperations

    func cancelAndFree() {
        operations.cancel(handle)
        operations.free(handle)
    }
}

final class ElementCallRustFutureRegistry: @unchecked Sendable {
    // UniFFI owns one callback per poll. Keep the future alive until that callback
    // consumes its retained continuation and any concurrent cancel call returns.

    private struct PendingFuture {
        let future: ElementCallRustFuture
        var isPolling = false
        var isCancellationRequested = false
        var isCancelCallInFlight = false
    }

    private struct CancellationRequest {
        let token: UUID
        let future: ElementCallRustFuture
    }

    private let lock = NSLock()
    private var pendingFutures = [UUID: PendingFuture]()
    private var hasStopped = false

    var canCreateFuture: Bool {
        lock.withLock { !hasStopped }
    }

    func register(_ handle: UInt64, operations: ElementCallRustFutureOperations) -> UUID? {
        let token = UUID()
        let future = ElementCallRustFuture(handle: handle, operations: operations)
        let didRegister = lock.withLock {
            guard !hasStopped else { return false }
            pendingFutures[token] = PendingFuture(future: future)
            return true
        }

        guard didRegister else {
            future.cancelAndFree()
            return nil
        }
        return token
    }

    func waitUntilReady(_ token: UUID) async -> Bool {
        await withTaskCancellationHandler {
            if Task.isCancelled {
                requestCancellation(token)
                return false
            }

            while await poll(token) != 0 {
                if Task.isCancelled {
                    requestCancellation(token)
                    return false
                }
            }

            return !Task.isCancelled && isActive(token)
        } onCancel: { [weak self] in
            self?.requestCancellation(token)
        }
    }

    func complete<T>(_ token: UUID, operation: (ElementCallRustFuture) -> T) -> T? {
        guard let future = lock.withLock({ () -> ElementCallRustFuture? in
            guard let pendingFuture = pendingFutures[token],
                  !pendingFuture.isCancellationRequested else {
                return nil
            }
            pendingFutures[token] = nil
            return pendingFuture.future
        }) else {
            return nil
        }

        let result = operation(future)
        future.operations.free(future.handle)
        return result
    }

    func stop() {
        let cancellationRequests = lock.withLock {
            guard !hasStopped else { return [CancellationRequest]() }
            hasStopped = true
            return Array(pendingFutures.keys).compactMap { beginCancellationLocked($0) }
        }

        cancellationRequests.forEach(performCancellation)
    }

    private func poll(_ token: UUID) async -> Int8 {
        let result = await withCheckedContinuation { continuation in
            let continuationBox = ElementCallRustFutureContinuation(continuation)
            let didPoll = lock.withLock {
                guard var pendingFuture = pendingFutures[token],
                      !pendingFuture.isCancellationRequested else { return false }
                pendingFuture.isPolling = true
                pendingFutures[token] = pendingFuture
                let pointer = Unmanaged.passRetained(continuationBox).toOpaque()
                pendingFuture.future.operations.poll(pendingFuture.future.handle,
                                                     UInt64(UInt(bitPattern: pointer)))
                return true
            }

            if !didPoll {
                continuationBox.resume(returning: 0)
            }
        }
        finishPoll(token)
        return result
    }

    private func isActive(_ token: UUID) -> Bool {
        lock.withLock {
            guard let pendingFuture = pendingFutures[token] else { return false }
            return !pendingFuture.isCancellationRequested
        }
    }

    private func requestCancellation(_ token: UUID) {
        guard let cancellationRequest = lock.withLock({ beginCancellationLocked(token) }) else { return }
        performCancellation(cancellationRequest)
    }

    private func beginCancellationLocked(_ token: UUID) -> CancellationRequest? {
        guard var pendingFuture = pendingFutures[token],
              !pendingFuture.isCancellationRequested else {
            return nil
        }

        pendingFuture.isCancellationRequested = true
        pendingFuture.isCancelCallInFlight = true
        pendingFutures[token] = pendingFuture
        return CancellationRequest(token: token, future: pendingFuture.future)
    }

    private func performCancellation(_ request: CancellationRequest) {
        request.future.operations.cancel(request.future.handle)

        let futureToFree = lock.withLock { () -> ElementCallRustFuture? in
            guard var pendingFuture = pendingFutures[request.token] else { return nil }
            pendingFuture.isCancelCallInFlight = false
            guard !pendingFuture.isPolling else {
                pendingFutures[request.token] = pendingFuture
                return nil
            }
            pendingFutures[request.token] = nil
            return pendingFuture.future
        }
        free(futureToFree)
    }

    private func finishPoll(_ token: UUID) {
        let futureToFree = lock.withLock { () -> ElementCallRustFuture? in
            guard var pendingFuture = pendingFutures[token] else { return nil }
            pendingFuture.isPolling = false
            guard pendingFuture.isCancellationRequested,
                  !pendingFuture.isCancelCallInFlight else {
                pendingFutures[token] = pendingFuture
                return nil
            }
            pendingFutures[token] = nil
            return pendingFuture.future
        }
        free(futureToFree)
    }

    private func free(_ future: ElementCallRustFuture?) {
        guard let future else { return }
        future.operations.free(future.handle)
    }
}

private final class MatrixElementCallWidgetDriverRuntime: ElementCallWidgetDriverRuntimeProtocol, @unchecked Sendable {
    private enum FutureKind {
        case run
        case receive
        case send

        var operations: ElementCallRustFutureOperations {
            .init(poll: { handle, callbackData in
                      poll(handle: handle, callbackData: callbackData)
                  },
                  cancel: { handle in cancel(handle: handle) },
                  free: { handle in free(handle: handle) })
        }

        func poll(handle: UInt64, callbackData: UInt64) {
            switch self {
            case .run:
                ffi_matrix_sdk_ffi_rust_future_poll_void(handle, elementCallRustFutureCallback, callbackData)
            case .receive:
                ffi_matrix_sdk_ffi_rust_future_poll_rust_buffer(handle, elementCallRustFutureCallback, callbackData)
            case .send:
                ffi_matrix_sdk_ffi_rust_future_poll_i8(handle, elementCallRustFutureCallback, callbackData)
            }
        }

        func cancel(handle: UInt64) {
            switch self {
            case .run:
                ffi_matrix_sdk_ffi_rust_future_cancel_void(handle)
            case .receive:
                ffi_matrix_sdk_ffi_rust_future_cancel_rust_buffer(handle)
            case .send:
                ffi_matrix_sdk_ffi_rust_future_cancel_i8(handle)
            }
        }

        func free(handle: UInt64) {
            switch self {
            case .run:
                ffi_matrix_sdk_ffi_rust_future_free_void(handle)
            case .receive:
                ffi_matrix_sdk_ffi_rust_future_free_rust_buffer(handle)
            case .send:
                ffi_matrix_sdk_ffi_rust_future_free_i8(handle)
            }
        }
    }

    private let driver: WidgetDriver
    private let handle: WidgetDriverHandle
    private let room: Room
    private let capabilitiesProvider: WidgetCapabilitiesProvider
    private let futureRegistry = ElementCallRustFutureRegistry()

    init(sdkDriver: WidgetDriverAndHandle,
         room: Room,
         capabilitiesProvider: WidgetCapabilitiesProvider) {
        driver = sdkDriver.driver
        handle = sdkDriver.handle
        self.room = room
        self.capabilitiesProvider = capabilitiesProvider

        // The generated wrappers do this immediately before creating each Rust future.
        uniffiEnsureMatrixSdkFfiInitialized()
    }

    deinit {
        stop()
    }

    func run() async {
        guard beginFutureCreation() else { return }

        let futureHandle = uniffi_matrix_sdk_ffi_fn_method_widgetdriver_run(driver.uniffiCloneHandle(),
                                                                            FfiConverterTypeRoom_lower(room),
                                                                            FfiConverterCallbackInterfaceWidgetCapabilitiesProvider_lower(capabilitiesProvider))
        guard let token = futureRegistry.register(futureHandle, operations: FutureKind.run.operations),
              await futureRegistry.waitUntilReady(token) else {
            return
        }

        guard let status = futureRegistry.complete(token, operation: { pendingFuture in
            var status = Self.emptyCallStatus
            ffi_matrix_sdk_ffi_rust_future_complete_void(pendingFuture.handle, &status)
            return status
        }) else {
            return
        }
        _ = check(status, operation: "run")
    }

    func receive() async -> String? {
        guard beginFutureCreation() else { return nil }

        let futureHandle = uniffi_matrix_sdk_ffi_fn_method_widgetdriverhandle_recv(handle.uniffiCloneHandle())
        guard let token = futureRegistry.register(futureHandle, operations: FutureKind.receive.operations),
              await futureRegistry.waitUntilReady(token) else {
            return nil
        }

        guard let completion = futureRegistry.complete(token, operation: { pendingFuture in
            var status = Self.emptyCallStatus
            let buffer = ffi_matrix_sdk_ffi_rust_future_complete_rust_buffer(pendingFuture.handle, &status)
            return (buffer, status)
        }) else {
            return nil
        }

        guard check(completion.1, operation: "receive") else {
            release(completion.0)
            return nil
        }
        return decodeOptionalString(completion.0)
    }

    func send(message: String) async -> Bool {
        guard beginFutureCreation(), let messageBuffer = encode(message) else { return false }

        let futureHandle = uniffi_matrix_sdk_ffi_fn_method_widgetdriverhandle_send(handle.uniffiCloneHandle(), messageBuffer)
        guard let token = futureRegistry.register(futureHandle, operations: FutureKind.send.operations),
              await futureRegistry.waitUntilReady(token) else {
            return false
        }

        guard let completion = futureRegistry.complete(token, operation: { pendingFuture in
            var status = Self.emptyCallStatus
            let result = ffi_matrix_sdk_ffi_rust_future_complete_i8(pendingFuture.handle, &status)
            return (result, status)
        }) else {
            return false
        }
        return check(completion.1, operation: "send") && completion.0 != 0
    }

    func stop() {
        futureRegistry.stop()
    }

    private func beginFutureCreation() -> Bool {
        !Task.isCancelled && futureRegistry.canCreateFuture
    }

    private func check(_ status: RustCallStatus, operation: String) -> Bool {
        guard status.code == 0 else {
            release(status.errorBuf)
            if status.code != 3 {
                MXLog.error("Element Call SDK runtime \(operation) failed with status \(status.code)")
            }
            return false
        }
        return true
    }

    private func encode(_ value: String) -> RustBuffer? {
        let bytes = Array(value.utf8)
        guard bytes.count <= Int32.max else {
            MXLog.error("Element Call widget message exceeded the SDK size limit")
            return nil
        }

        var status = Self.emptyCallStatus
        let buffer = bytes.withUnsafeBufferPointer { bytes in
            ffi_matrix_sdk_ffi_rustbuffer_from_bytes(.init(len: Int32(bytes.count), data: bytes.baseAddress), &status)
        }
        guard check(status, operation: "message encoding") else {
            release(buffer)
            return nil
        }
        return buffer
    }

    private func decodeOptionalString(_ buffer: RustBuffer) -> String? {
        defer { release(buffer) }

        guard buffer.len <= Int.max,
              let data = buffer.data else {
            MXLog.error("Element Call SDK returned an invalid widget message buffer")
            return nil
        }

        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(buffer.len)))
        guard let tag = bytes.first else {
            MXLog.error("Element Call SDK returned an empty widget message buffer")
            return nil
        }

        switch tag {
        case 0:
            guard bytes.count == 1 else { return invalidWidgetMessageBuffer() }
            return nil
        case 1:
            guard bytes.count >= 5 else { return invalidWidgetMessageBuffer() }
            let length = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(length) == bytes.count - 5 else { return invalidWidgetMessageBuffer() }
            guard let value = String(bytes: bytes[5...], encoding: .utf8) else {
                return invalidWidgetMessageBuffer()
            }
            return value
        default:
            return invalidWidgetMessageBuffer()
        }
    }

    private func invalidWidgetMessageBuffer<T>() -> T? {
        MXLog.error("Element Call SDK returned an invalid widget message buffer")
        return nil
    }

    private func release(_ buffer: RustBuffer) {
        guard buffer.data != nil || buffer.capacity > 0 else { return }
        var status = Self.emptyCallStatus
        ffi_matrix_sdk_ffi_rustbuffer_free(buffer, &status)
        if status.code != 0 {
            MXLog.error("Failed releasing an Element Call SDK buffer with status \(status.code)")
        }
    }

    private static var emptyCallStatus: RustCallStatus {
        .init(code: 0, errorBuf: .init(capacity: 0, len: 0, data: nil))
    }
}

private final class ElementCallRustFutureContinuation: @unchecked Sendable {
    private let continuation: CheckedContinuation<Int8, Never>

    init(_ continuation: CheckedContinuation<Int8, Never>) {
        self.continuation = continuation
    }

    func resume(returning result: Int8) {
        continuation.resume(returning: result)
    }
}

let elementCallRustFutureCallback: UniffiRustFutureContinuationCallback = { callbackData, result in
    guard let pointer = UnsafeRawPointer(bitPattern: UInt(callbackData)) else { return }
    Unmanaged<ElementCallRustFutureContinuation>.fromOpaque(pointer).takeRetainedValue().resume(returning: result)
}

private final class ElementCallWidgetCapabilitiesProvider: WidgetCapabilitiesProvider, @unchecked Sendable {
    private let room: RoomProtocol
    private let deviceID: String

    init(room: RoomProtocol, deviceID: String) {
        self.room = room
        self.deviceID = deviceID
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: room.ownUserId(), ownDeviceId: deviceID)
    }
}
