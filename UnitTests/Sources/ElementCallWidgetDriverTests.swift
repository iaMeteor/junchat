//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import SwiftUI
import Testing

struct ElementCallWidgetDriverTests {
    @Test
    func stopCancelsRuntimeTasksReleasesTheSDKSessionAndIsIdempotent() async {
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
            return snapshot.receiveCancelled == 1 &&
                snapshot.runCancelled == 1 &&
                snapshot.handleDeinitialized == 1 &&
                snapshot.driverDeinitialized == 1
        }

        let snapshot = probe.snapshot
        #expect(snapshot.receiveCancelled == 1)
        #expect(snapshot.runCancelled == 1)
        #expect(snapshot.handleDeinitialized == 1)
        #expect(snapshot.driverDeinitialized == 1)
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
                snapshot.receiveCancelled == 1 &&
                snapshot.runCancelled == 1 &&
                snapshot.handleDeinitialized == 1 &&
                snapshot.driverDeinitialized == 1
        }

        #expect(weakDriver == nil)
    }

    @Test
    func stoppingDuringSessionCreationDoesNotStartTheRuntime() async {
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
            return snapshot.handleDeinitialized == 1 && snapshot.driverDeinitialized == 1
        }

        let snapshot = probe.snapshot
        #expect(snapshot.receiveStarted == 0)
        #expect(snapshot.runStarted == 0)
        #expect(snapshot.handleDeinitialized == 1)
        #expect(snapshot.driverDeinitialized == 1)
    }

    private func makeDriver(probe: ElementCallWidgetDriverLifecycleProbe) -> ElementCallWidgetDriver {
        ElementCallWidgetDriver(room: RoomSDKMock(),
                                deviceID: "device-id") {
            .success(makeSession(probe: probe))
        }
    }

    private func makeSession(probe: ElementCallWidgetDriverLifecycleProbe) -> ElementCallWidgetDriver.Session {
        .init(url: .homeDirectory,
              sdkDriver: .init(driver: LifecycleWidgetDriver(probe: probe),
                               handle: LifecycleWidgetDriverHandle(probe: probe)))
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

private final class LifecycleWidgetDriver: WidgetDriverSDKMock, @unchecked Sendable {
    private let probe: ElementCallWidgetDriverLifecycleProbe

    init(probe: ElementCallWidgetDriverLifecycleProbe) {
        self.probe = probe
        super.init()
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("init(unsafeFromHandle:) has not been implemented")
    }

    override func run(room: Room, capabilitiesProvider: WidgetCapabilitiesProvider) async {
        probe.increment(\.runStarted)
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled {
            probe.increment(\.runCancelled)
        }
    }

    deinit {
        probe.increment(\.driverDeinitialized)
    }
}

private final class LifecycleWidgetDriverHandle: WidgetDriverHandleSDKMock, @unchecked Sendable {
    private let probe: ElementCallWidgetDriverLifecycleProbe

    init(probe: ElementCallWidgetDriverLifecycleProbe) {
        self.probe = probe
        super.init()
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("init(unsafeFromHandle:) has not been implemented")
    }

    override func recv() async -> String? {
        probe.increment(\.receiveStarted)
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled {
            probe.increment(\.receiveCancelled)
        }
        return nil
    }

    deinit {
        probe.increment(\.handleDeinitialized)
    }
}

private final class ElementCallWidgetDriverLifecycleProbe: @unchecked Sendable {
    struct Snapshot {
        var receiveStarted = 0
        var receiveCancelled = 0
        var runStarted = 0
        var runCancelled = 0
        var handleDeinitialized = 0
        var driverDeinitialized = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment(_ keyPath: WritableKeyPath<Snapshot, Int>) {
        lock.lock()
        value[keyPath: keyPath] += 1
        lock.unlock()
    }
}
