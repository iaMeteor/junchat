//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import SwiftUI
import Testing

struct ElementCallWidgetDriverTests {
    @Test
    func stopTerminatesCancellationInsensitiveRuntimeAndIsIdempotent() async {
        let probe = ElementCallWidgetDriverLifecycleProbe()
        let driver = makeDriver(probe: probe)

        await expectSuccess(start(driver))
        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.receiveStarted == 1 && snapshot.runStarted == 1
        }

        driver.stop()
        driver.stop()

        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.receiveFinished == 1 &&
                snapshot.runFinished == 1 &&
                snapshot.runtimeStops == 1 &&
                snapshot.runtimeDeinitialized == 1
        }

        let snapshot = probe.snapshot
        #expect(snapshot.receiveFinished == 1)
        #expect(snapshot.runFinished == 1)
        #expect(snapshot.runtimeStops == 1)
        #expect(snapshot.runtimeDeinitialized == 1)
    }

    @Test
    func deinitializingTheDriverStopsItsRuntime() async throws {
        let probe = ElementCallWidgetDriverLifecycleProbe()
        var driver: ElementCallWidgetDriver? = makeDriver(probe: probe)
        weak let weakDriver = driver

        try await expectSuccess(start(#require(driver)))
        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.receiveStarted == 1 && snapshot.runStarted == 1
        }

        driver = nil

        await waitUntil {
            let snapshot = probe.snapshot
            return weakDriver == nil &&
                snapshot.receiveFinished == 1 &&
                snapshot.runFinished == 1 &&
                snapshot.runtimeStops == 1 &&
                snapshot.runtimeDeinitialized == 1
        }

        #expect(weakDriver == nil)
    }

    @Test
    func stoppingDuringSessionCreationStopsTheLateRuntimeWithoutStartingTasks() async {
        let probe = ElementCallWidgetDriverLifecycleProbe()
        let sessionBuilder = SuspendedElementCallWidgetSessionBuilder()
        let driver = ElementCallWidgetDriver(room: RoomSDKMock(),
                                             deviceID: "device-id") {
            await sessionBuilder.build()
        }
        let startTask = Task { await start(driver) }

        await waitUntil { await sessionBuilder.hasRequest }
        driver.stop()
        await sessionBuilder.resume(returning: makeSession(probe: probe))

        guard case .failure(.cancelled) = await startTask.value else {
            Issue.record("Expected the stopped driver start to be cancelled.")
            return
        }

        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.runtimeDeinitialized == 1
        }

        let snapshot = probe.snapshot
        #expect(snapshot.receiveStarted == 0)
        #expect(snapshot.runStarted == 0)
        #expect(snapshot.runtimeStops == 1)
        #expect(snapshot.runtimeDeinitialized == 1)
    }

    @Test
    func stopSuppressesLateRuntimeAndDirectActionEmissions() async {
        let probe = ElementCallWidgetDriverLifecycleProbe()
        let message = mediaStateMessage()
        let driver = makeDriver(probe: probe, receiveMessageOnStop: message)
        let messageCancellable = driver.messagePublisher.sink { _ in probe.increment(\.messageEmissions) }
        let actionCancellable = driver.actions.sink { _ in probe.increment(\.actionEmissions) }

        await expectSuccess(start(driver))
        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.receiveStarted == 1 && snapshot.runStarted == 1
        }

        driver.stop()
        driver.handleMessageIfNeeded(message)

        await waitUntil {
            let snapshot = probe.snapshot
            return snapshot.receiveFinished == 1 && snapshot.runFinished == 1
        }

        #expect(probe.snapshot.messageEmissions == 0)
        #expect(probe.snapshot.actionEmissions == 0)
        withExtendedLifetime((messageCancellable, actionCancellable)) { }
    }

    @Test
    func inFlightMessageHandlingDoesNotCompleteAfterStop() async {
        let probe = ElementCallWidgetDriverLifecycleProbe()
        let driver = makeDriver(probe: probe)

        await expectSuccess(start(driver))
        let handleTask = Task {
            await driver.handleMessage(#"{"api":"fromWidget","action":"future.action"}"#)
        }
        await waitUntil { probe.snapshot.sendStarted == 1 }

        driver.stop()

        guard case .failure(.cancelled) = await handleTask.value else {
            Issue.record("Expected in-flight message handling to be cancelled after stop.")
            return
        }
        #expect(probe.snapshot.sendFinished == 1)
    }

    private func makeDriver(probe: ElementCallWidgetDriverLifecycleProbe,
                            receiveMessageOnStop: String? = nil) -> ElementCallWidgetDriver {
        ElementCallWidgetDriver(room: RoomSDKMock(),
                                deviceID: "device-id") {
            .success(makeSession(probe: probe, receiveMessageOnStop: receiveMessageOnStop))
        }
    }

    private func makeSession(probe: ElementCallWidgetDriverLifecycleProbe,
                             receiveMessageOnStop: String? = nil) -> ElementCallWidgetDriver.Session {
        .init(url: .homeDirectory,
              runtime: CancellationInsensitiveWidgetRuntime(probe: probe,
                                                            receiveMessageOnStop: receiveMessageOnStop))
    }

    private func mediaStateMessage() -> String {
        #"{"api":"fromWidget","action":"io.element.device_mute","data":{"audio_enabled":true,"video_enabled":false},"widgetId":"widget-id","requestId":"request-id"}"#
    }

    private func start(_ driver: ElementCallWidgetDriver) async -> Result<URL, ElementCallWidgetDriverError> {
        await driver.start(baseURL: .homeDirectory,
                           clientID: "io.element.test",
                           colorScheme: .dark,
                           voiceOnly: true,
                           rageshakeURL: nil,
                           analyticsConfiguration: nil)
    }

    private func expectSuccess(_ result: Result<URL, ElementCallWidgetDriverError>,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .success(.homeDirectory) = result else {
            Issue.record("Expected the widget driver to start.", sourceLocation: sourceLocation)
            return
        }
    }

    private func waitUntil(_ condition: () async -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            guard await !condition() else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition(), sourceLocation: sourceLocation)
    }
}

private actor SuspendedElementCallWidgetSessionBuilder {
    private var continuation: CheckedContinuation<Result<ElementCallWidgetDriver.Session, ElementCallWidgetDriverError>, Never>?

    var hasRequest: Bool {
        continuation != nil
    }

    func build() async -> Result<ElementCallWidgetDriver.Session, ElementCallWidgetDriverError> {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning session: ElementCallWidgetDriver.Session) {
        continuation?.resume(returning: .success(session))
        continuation = nil
    }
}

private final class CancellationInsensitiveWidgetRuntime: ElementCallWidgetDriverRuntimeProtocol, @unchecked Sendable {
    private let probe: ElementCallWidgetDriverLifecycleProbe
    private let receiveMessageOnStop: String?
    private let runWait = CancellationInsensitiveWait()
    private let receiveWait = CancellationInsensitiveWait()
    private let sendWait = CancellationInsensitiveWait()

    init(probe: ElementCallWidgetDriverLifecycleProbe, receiveMessageOnStop: String?) {
        self.probe = probe
        self.receiveMessageOnStop = receiveMessageOnStop
    }

    func run() async {
        probe.increment(\.runStarted)
        await runWait.wait()
        probe.increment(\.runFinished)
    }

    func receive() async -> String? {
        probe.increment(\.receiveStarted)
        await receiveWait.wait()
        probe.increment(\.receiveFinished)
        return receiveMessageOnStop
    }

    func send(message: String) async -> Bool {
        probe.increment(\.sendStarted)
        await sendWait.wait()
        probe.increment(\.sendFinished)
        return false
    }

    func stop() {
        probe.increment(\.runtimeStops)
        runWait.resume()
        receiveWait.resume()
        sendWait.resume()
    }

    deinit {
        probe.increment(\.runtimeDeinitialized)
    }
}

private final class CancellationInsensitiveWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasResumed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if hasResumed {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            hasResumed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class ElementCallWidgetDriverLifecycleProbe: @unchecked Sendable {
    struct Snapshot {
        var receiveStarted = 0
        var receiveFinished = 0
        var runStarted = 0
        var runFinished = 0
        var sendStarted = 0
        var sendFinished = 0
        var runtimeStops = 0
        var runtimeDeinitialized = 0
        var messageEmissions = 0
        var actionEmissions = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { value }
    }

    func increment(_ keyPath: WritableKeyPath<Snapshot, Int>) {
        lock.withLock { value[keyPath: keyPath] += 1 }
    }
}
