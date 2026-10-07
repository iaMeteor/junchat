//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct CallDiagnosticsCollectorTests {
    private let sessionID = "ade7a7ad-a151-4b1e-9368-58c0d6a0c862"

    @Test
    func acceptsContractFieldsIncludingEncryptionAndSafeCounters() throws {
        var object = fixture()
        object["stage"] = "encryption"
        object["code"] = "encryption_failed"
        object["attempt"] = 1000
        object["elapsed_ms"] = 86_400_000
        object["state"] = "connected"
        object["track_id_hash"] = String(repeating: "a", count: 64)
        object["client_track_id_hash"] = String(repeating: "b", count: 64)
        object["participant_id_hash"] = String(repeating: "c", count: 64)
        object["rtt_ms"] = 60000
        for key in ["packets_sent", "packets_received", "packets_lost", "bytes_sent", "bytes_received"] {
            object[key] = Int64(9_007_199_254_740_991)
        }
        let event = try #require(parse(object))
        #expect(event.stage == .encryption)
        #expect(event.code == .encryptionFailed)
        #expect(event.bytesReceived == 9_007_199_254_740_991)
        let data = try #require(CallDiagnosticEnvelope(appVersion: "2.0.1-beta", build: "58", events: [event]).encoded())
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(envelope.keys) == ["schema", "platform", "app_version", "build", "events"])
        #expect(envelope["schema"] as? String == "junchat.call-diagnostics.v1")
        #expect(envelope["platform"] as? String == "ios")
        #expect(envelope["app_version"] as? String == "2.0.1-beta")
    }

    @Test(arguments: ["message", "error", "stack", "sdp", "url", "address", "headers", "access_token", "user_id", "device_id", "room_id", "key"])
    func rejectsUncontractedFields(_ key: String) {
        var object = fixture()
        object[key] = "private-message-or-credential"
        #expect(parse(object) == nil)
    }

    @Test
    func rejectsMalformedMissingNullAndOutOfRangeValues() {
        let invalid: [(String, Any)] = [
            ("session_id", "@someone:example.org"), ("session_id", sessionID + "\n"),
            ("sequence", 0), ("sequence", 1_000_001), ("sequence", 1.5), ("sequence", true), ("sequence", "1"),
            ("occurred_at", "2026-10-07T12:00:00+08:00"), ("occurred_at", "2026-02-30T12:00:00Z"), ("occurred_at", "yesterday"),
            ("component", "ios"), ("component", "web"), ("stage", "private-description"), ("status", "bad"), ("code", "raw-error"), ("source", "private-device"),
            ("attempt", -1), ("attempt", 1001), ("elapsed_ms", 86_400_001), ("state", "private-state"),
            ("rtt_ms", 60001), ("packets_sent", -1), ("bytes_received", Int64(9_007_199_254_740_992)),
            ("track_id_hash", String(repeating: "A", count: 64)), ("track_id_hash", "TR_AM_private"),
            ("client_track_id_hash", NSNull()), ("participant_id_hash", String(repeating: "c", count: 63))
        ]
        for (key, value) in invalid {
            var object = fixture()
            object[key] = value
            #expect(parse(object) == nil, "Accepted invalid \(key)")
        }
        for key in fixture().keys {
            var object = fixture()
            object.removeValue(forKey: key)
            #expect(parse(object) == nil, "Accepted missing \(key)")
        }
        #expect(CallDiagnosticEvent.fromConsole(CallDiagnosticEvent.consolePrefix + "{", level: "info") == nil)
        #expect(CallDiagnosticEvent.fromConsole(CallDiagnosticEvent.consolePrefix + "[]", level: "info") == nil)
        #expect(CallDiagnosticEvent.fromConsole(CallDiagnosticEvent.consolePrefix + "null", level: "info") == nil)
    }

    @Test
    func boundsConsoleParsingAndDoesNotAcceptOtherLevelsOrPrefixes() throws {
        let line = try console(fixture())
        #expect(CallDiagnosticEvent.fromConsole(line, level: "info") != nil)
        #expect(CallDiagnosticEvent.fromConsole("prefix " + line, level: "info") == nil)
        #expect(CallDiagnosticEvent.fromConsole(line, level: "error") == nil)
        #expect(CallDiagnosticEvent.fromConsole(line, level: "log") == nil)
        #expect(CallDiagnosticEvent.fromConsole(line + String(repeating: " ", count: CallDiagnosticEvent.maximumRecordBytes), level: "info") == nil)
        var object = fixture()
        object["occurred_at"] = "2026-10-07T12:00:00+00:00"
        #expect(parse(object) != nil)
    }

    @Test
    func rejectsInvalidEnvelopesAndDuplicateIDsCaseInsensitively() throws {
        let event = try #require(parse(fixture()))
        var object = fixture()
        object["session_id"] = sessionID.uppercased()
        let duplicate = try #require(parse(object))
        #expect(CallDiagnosticEnvelope(appVersion: "2.0.1", build: "58", events: []).encoded() == nil)
        #expect(CallDiagnosticEnvelope(appVersion: "2.0.1", build: "58", events: [event, duplicate]).encoded() == nil)
        #expect(CallDiagnosticEnvelope(appVersion: "2.0.1", build: "58", events: Array(repeating: event, count: 65)).encoded() == nil)
        for invalid in ["", String(repeating: "a", count: 33), "https://private", "private version", "58\n"] {
            #expect(CallDiagnosticEnvelope(appVersion: invalid, build: "58", events: [event]).encoded() == nil)
            #expect(CallDiagnosticEnvelope(appVersion: "2.0.1", build: invalid, events: [event]).encoded() == nil)
        }
    }

    @Test
    func capsPendingEventsAndBatchesAt64() async throws {
        let uploader = CallDiagnosticsTestUploader()
        let collector = makeCollector(uploader)
        for sequence in 1...300 {
            try collector.record(event(sequence))
        }
        #expect(collector.pendingEventCount == CallDiagnosticsCollector.capacity)
        #expect(collector.droppedEventCount == 44)
        await collector.flush()
        let payloads = await uploader.payloads
        #expect(try payloads.map { try events($0).count } == [64, 64, 64, 64])
        #expect(try payloads.flatMap { try events($0).compactMap { $0["sequence"] as? Int } } == Array(1...256))
        #expect(collector.pendingEventCount == 0)
        collector.invalidate()
    }

    @Test
    func retriesIdenticalPayloadWithBoundedBackoffWithoutReportingErrors() async throws {
        let uploader = CallDiagnosticsTestUploader(results: [.failure(.network), .failure(.rateLimited), .failure(.invalidResponse), .success(())])
        let delays = CallDiagnosticsTestDelays()
        let clock = CallDiagnosticsTestClock()
        let collector = CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { clock.now }, retrySleep: {
            await delays.append($0)
            clock.advance($0)
        })
        try collector.record(event(1))
        await collector.flush()
        let payloads = await uploader.payloads
        #expect(payloads.count == 4)
        #expect(Set(payloads).count == 1)
        #expect(await delays.values == [.seconds(15), .seconds(30), .seconds(60)])
        #expect(collector.pendingEventCount == 0)
        collector.invalidate()
    }

    @Test
    func exhaustedRetriesRetainBatchUntilAfterCooldown() async throws {
        let uploader = CallDiagnosticsTestUploader(results: Array(repeating: .failure(.network), count: 4))
        let clock = CallDiagnosticsTestClock()
        let collector = CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { clock.now }, retrySleep: { clock.advance($0) })
        try collector.record(event(1))
        await collector.flush()
        #expect(await uploader.payloads.count == 4)
        #expect(collector.pendingEventCount == 1)
        #expect(collector.lastUploadFailure == .network)
        try collector.record(event(2))
        await collector.flush()
        #expect(await uploader.payloads.count == 4)
        #expect(collector.pendingEventCount == 2)
        clock.advance(.seconds(60))
        await collector.flush()
        #expect(await uploader.payloads.count == 5)
        let payload = try #require(await uploader.payloads.last)
        #expect(try events(payload).compactMap { $0["sequence"] as? Int } == [1, 2])
        #expect(collector.pendingEventCount == 0)
        #expect(collector.lastUploadFailure == nil)
        collector.invalidate()
    }

    @Test(arguments: [JunchatDiagnosticsUploadError.unauthorized, .sessionUnavailable])
    func authenticationFailureClearsQueueAndRefusesFurtherEvents(_ error: JunchatDiagnosticsUploadError) async throws {
        let uploader = CallDiagnosticsTestUploader(results: [.failure(error)])
        let collector = makeCollector(uploader)
        for sequence in 1...100 {
            try collector.record(event(sequence))
        }
        await collector.flush()
        try collector.record(event(101))
        await collector.flush()
        #expect(await uploader.payloads.count == 1)
        #expect(collector.pendingEventCount == 0)
    }

    @Test
    func serializesOverlappingFlushesAndPreservesNewEventsDuringUpload() async throws {
        let uploader = CallDiagnosticsTestUploader(blockFirst: true)
        let collector = makeCollector(uploader)
        try collector.record(event(1))
        let first = Task { await collector.flush() }
        await uploader.waitForFirstUpload()
        try collector.record(event(2))
        let second = Task { await collector.flush() }
        await uploader.releaseFirst()
        await first.value
        await second.value
        #expect(await uploader.maximumConcurrent == 1)
        let payloads = await uploader.payloads
        #expect(try payloads.flatMap { try events($0).compactMap { $0["sequence"] as? Int } } == [1, 2])
        collector.invalidate()
    }

    @Test
    func failedHeadRetainsNewerEventsAndReportsCapacityDrops() async throws {
        let uploader = CallDiagnosticsTestUploader(results: Array(repeating: .failure(.network), count: 4), blockFirst: true)
        let clock = CallDiagnosticsTestClock()
        let collector = CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { clock.now }, retrySleep: { clock.advance($0) })
        try collector.record(event(1))
        let delivery = Task { await collector.flush() }
        await uploader.waitForFirstUpload()
        for sequence in 2...300 {
            try collector.record(event(sequence))
        }
        await uploader.releaseFirst()
        await delivery.value
        #expect(collector.pendingEventCount == 256)
        #expect(collector.droppedEventCount == 44)
        #expect(await uploader.payloads.count == 4)
        clock.advance(.seconds(60))
        await collector.flush()
        let acknowledgedPayloads = await uploader.payloads.dropFirst(4)
        #expect(try acknowledgedPayloads.flatMap { try events($0).compactMap { $0["sequence"] as? Int } } == Array(1...256))
        #expect(collector.pendingEventCount == 0)
        #expect(collector.droppedEventCount == 44)
        collector.invalidate()
    }

    @Test
    func logoutClearsDelayedAndInFlightQueuesWithoutSendingToNewAccount() async throws {
        let oldUploader = CallDiagnosticsTestUploader(results: [.failure(.network)], blockFirst: true)
        let old = makeCollector(oldUploader)
        try old.record(event(1))
        let inFlight = Task { await old.flush() }
        await oldUploader.waitForFirstUpload()
        try old.record(event(2))
        old.invalidate()
        try old.record(event(3))

        let newUploader = CallDiagnosticsTestUploader()
        let new = makeCollector(newUploader)
        try new.record(event(4))
        await new.flush()
        await oldUploader.releaseFirst()
        await inFlight.value
        #expect(old.pendingEventCount == 0)
        #expect(await oldUploader.payloads.count == 1)
        #expect(try await newUploader.payloads.flatMap { try events($0).compactMap { $0["sequence"] as? Int } } == [4])
        new.invalidate()

        let neverUploaded = CallDiagnosticsTestUploader()
        let delayed = makeCollector(neverUploaded)
        try delayed.record(event(5))
        delayed.invalidate()
        await delayed.flush()
        #expect(await neverUploaded.payloads.isEmpty)
    }

    @Test
    func recorderRejectsReplayedMalformedAndPostCallEvents() async throws {
        let uploader = CallDiagnosticsTestUploader()
        let collector = makeCollector(uploader)
        let recorder = CallDiagnosticRecorder(collector: collector)
        try recorder.consumeConsole(console(fixture(sequence: 2)), level: "info")
        try recorder.consumeConsole(console(fixture(sequence: 2)), level: "info")
        try recorder.consumeConsole(console(fixture(sequence: 1)), level: "info")
        recorder.consumeConsole(CallDiagnosticEvent.consolePrefix + "{\"message\":\"secret\"}", level: "info")
        recorder.record(stage: .permission, status: .failed, code: .permissionDenied, source: .microphone)
        recorder.finish()
        recorder.finish()
        try recorder.consumeConsole(console(fixture(sequence: 3)), level: "info")
        recorder.record(stage: .capture, status: .started)
        await collector.flush()
        let decoded = try await uploader.payloads.flatMap { try events($0) }
        #expect(decoded.count == 3)
        #expect(decoded.filter { $0["component"] as? String == "element_call" }.count == 1)
        let native = decoded.filter { $0["component"] as? String == "ios" }
        #expect(native.compactMap { $0["sequence"] as? Int } == [1, 2])
        #expect(Set(native.compactMap { $0["session_id"] as? String }).count == 1)
        #expect(native.first?["session_id"] as? String != sessionID)
        let payload = try #require(await uploader.payloads.first)
        let text = try #require(String(data: payload, encoding: .utf8))
        #expect(!text.contains("secret"))
        collector.invalidate()
    }

    @Test
    func sessionFactoryPreservesCanaryIsolation() {
        let collector = CallDiagnosticsCollector.forSession(uploader: CallDiagnosticsTestUploader(), appVersion: "2.0.1", build: "58")
        #if JUNCHAT_CANARY
        #expect(collector == nil)
        #else
        #expect(collector != nil)
        #endif
        collector?.invalidate()
        #expect(CallDiagnosticsCollector.forSession(uploader: nil, appVersion: "2.0.1", build: "58") == nil)
    }

    @Test
    func automaticallyBatchesInsteadOfUploadingEveryEvent() async throws {
        let uploader = CallDiagnosticsTestUploader()
        let collector = makeCollector(uploader)
        for sequence in 1...10 {
            try collector.record(event(sequence))
        }
        #expect(await uploader.payloads.isEmpty)
        for _ in 0..<200 {
            if await !uploader.payloads.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let automaticUploadCount = await uploader.payloads.count
        #expect(automaticUploadCount == 1)
        await collector.flush()
        let payloads = await uploader.payloads
        #expect(payloads.count == 1)
        #expect(try events(#require(payloads.first)).count == 10)
        collector.invalidate()
    }

    @Test
    func logoutWhileRetryingCannotResumeDelivery() async throws {
        let uploader = CallDiagnosticsTestUploader(results: [.failure(.network)])
        let retryGate = CallDiagnosticsTestUploader(blockFirst: true)
        let collector = CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { ContinuousClock.now }, retrySleep: { _ in
            _ = await retryGate.upload(Data())
        })
        try collector.record(event(1))
        let delivery = Task { await collector.flush() }
        await retryGate.waitForFirstUpload()
        collector.invalidate()
        await retryGate.releaseFirst()
        await delivery.value
        #expect(await uploader.payloads.count == 1)
        #expect(collector.pendingEventCount == 0)
    }

    @Test
    func missingEndpointRemainsLocallyVisibleWithoutRecursiveUploadsOrRepeatedLogs() async throws {
        let uploader = CallDiagnosticsTestUploader(results: [.failure(.endpointNotFound), .failure(.endpointNotFound)])
        let clock = CallDiagnosticsTestClock()
        var failures: [JunchatDiagnosticsUploadError] = []
        let collector = CallDiagnosticsCollector(uploader: uploader,
                                                 appVersion: "2.0.1",
                                                 build: "58",
                                                 localFailureHandler: { failures.append($0) },
                                                 now: { clock.now },
                                                 retrySleep: { clock.advance($0) })
        try collector.record(event(1))
        await collector.flush()
        #expect(await uploader.payloads.count == 1)
        clock.advance(.seconds(60))
        await collector.flush()
        try collector.record(event(2))
        await collector.flush()
        #expect(collector.lastUploadFailure == .endpointNotFound)
        #expect(failures == [.endpointNotFound])
        #expect(await uploader.payloads.count == 2)
        #expect(collector.pendingEventCount == 2)
        collector.invalidate()
    }

    @Test
    func explicitFlushesAndBackloggedBatchesShareTheRateBudget() async throws {
        let uploader = CallDiagnosticsTestUploader()
        let clock = CallDiagnosticsTestClock()
        let delays = CallDiagnosticsTestDelays()
        let collector = CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { clock.now }, retrySleep: {
            await delays.append($0)
            clock.advance($0)
        })
        for sequence in 1...65 {
            try collector.record(event(sequence))
        }
        await collector.flush()
        try collector.record(event(66))
        await collector.flush()
        #expect(await uploader.payloads.count == 3)
        #expect(await delays.values == [.seconds(15), .seconds(15)])
        collector.invalidate()
    }

    @Test
    func boundsWebSessionTrackingAndAcceptsMonotonicEventsInKnownSessions() throws {
        let uploader = CallDiagnosticsTestUploader()
        let collector = makeCollector(uploader)
        let recorder = CallDiagnosticRecorder(collector: collector)
        try recorder.consumeConsole(console(fixture()), level: "info")
        for _ in 1...70 {
            var object = fixture()
            object["session_id"] = UUID().uuidString
            try recorder.consumeConsole(console(object), level: "info")
        }
        try recorder.consumeConsole(console(fixture(sequence: 2)), level: "info")
        #expect(collector.pendingEventCount == 65)
        collector.invalidate()
    }

    private func makeCollector(_ uploader: CallDiagnosticsTestUploader) -> CallDiagnosticsCollector {
        let clock = CallDiagnosticsTestClock()
        return CallDiagnosticsCollector(uploader: uploader, appVersion: "2.0.1", build: "58", now: { clock.now }, retrySleep: { clock.advance($0) })
    }

    private func fixture(sequence: Int = 1) -> [String: Any] {
        ["session_id": sessionID, "sequence": sequence, "occurred_at": "2026-10-07T12:00:00.123Z",
         "component": "element_call", "stage": "publication", "status": "failed", "code": "publish_timeout", "source": "microphone"]
    }

    private func console(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try CallDiagnosticEvent.consolePrefix + #require(String(data: data, encoding: .utf8))
    }

    private func parse(_ object: [String: Any]) -> CallDiagnosticEvent? {
        guard let line = try? console(object) else { return nil }
        return CallDiagnosticEvent.fromConsole(line, level: "info")
    }

    private func event(_ sequence: Int) throws -> CallDiagnosticEvent {
        try #require(parse(fixture(sequence: sequence)))
    }

    private func events(_ payload: Data) throws -> [[String: Any]] {
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try #require(object["events"] as? [[String: Any]])
    }
}

private final class CallDiagnosticsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(_ duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

private actor CallDiagnosticsTestDelays {
    var values: [Duration] = []
    func append(_ value: Duration) {
        values.append(value)
    }
}

private actor CallDiagnosticsTestUploader: JunchatDiagnosticsUploading {
    private var results: [Result<Void, JunchatDiagnosticsUploadError>]
    private let blockFirst: Bool
    private var blocker: CheckedContinuation<Void, Never>?
    private var firstUploadWaiters: [CheckedContinuation<Void, Never>] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private(set) var payloads: [Data] = []

    init(results: [Result<Void, JunchatDiagnosticsUploadError>] = [], blockFirst: Bool = false) {
        self.results = results
        self.blockFirst = blockFirst
    }

    func upload(_ payload: Data) async -> Result<Void, JunchatDiagnosticsUploadError> {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        payloads.append(payload)
        if blockFirst, payloads.count == 1 {
            await withCheckedContinuation { continuation in
                blocker = continuation
                firstUploadWaiters.forEach { $0.resume() }
                firstUploadWaiters.removeAll()
            }
        }
        return results.isEmpty ? .success(()) : results.removeFirst()
    }

    func waitForFirstUpload() async {
        guard payloads.isEmpty else { return }
        await withCheckedContinuation { firstUploadWaiters.append($0) }
    }

    func releaseFirst() {
        blocker?.resume()
        blocker = nil
    }
}
