//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// One collector per authenticated session. Its uploader is never replaced.
@MainActor
final class CallDiagnosticsCollector {
    static let capacity = 256
    private static let uploadInterval: Duration = .seconds(15)
    private let uploader: JunchatDiagnosticsUploading
    private let appVersion: String
    private let build: String
    private let localFailureHandler: (JunchatDiagnosticsUploadError) -> Void
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastUploadAt: ContinuousClock.Instant?
    private var retryNotBefore: ContinuousClock.Instant?
    private var pending: [CallDiagnosticEvent] = []
    private var delayTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var invalidated = false
    private(set) var lastUploadFailure: JunchatDiagnosticsUploadError?
    private(set) var droppedEventCount = 0

    var pendingEventCount: Int {
        pending.count
    }

    static func forSession(uploader: JunchatDiagnosticsUploading?,
                           appVersion: String,
                           build: String,
                           localFailureHandler: @escaping (JunchatDiagnosticsUploadError) -> Void = { _ in }) -> CallDiagnosticsCollector? {
        #if JUNCHAT_CANARY
        return nil
        #else
        guard let uploader else { return nil }
        return CallDiagnosticsCollector(uploader: uploader, appVersion: appVersion, build: build, localFailureHandler: localFailureHandler)
        #endif
    }

    init(uploader: JunchatDiagnosticsUploading,
         appVersion: String,
         build: String,
         localFailureHandler: @escaping (JunchatDiagnosticsUploadError) -> Void = { _ in },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.uploader = uploader
        self.appVersion = appVersion
        self.build = build
        self.localFailureHandler = localFailureHandler
        self.now = now
        self.retrySleep = retrySleep
        invalidated = !CallDiagnosticEvent.isVersion(appVersion) || !CallDiagnosticEvent.isVersion(build)
    }

    func record(_ event: CallDiagnosticEvent) {
        guard !invalidated, event.isValid else { return }
        defer { scheduleDeliveryIfNeeded() }
        guard !pending.contains(where: { $0.sessionID.lowercased() == event.sessionID.lowercased() && $0.sequence == event.sequence }) else { return }
        guard pending.count < Self.capacity else {
            if droppedEventCount < Int.max { droppedEventCount += 1 }
            return
        }
        pending.append(event)
    }

    private var canDeliver: Bool {
        !invalidated && (retryNotBefore.map { now() >= $0 } ?? true)
    }

    private func scheduleDeliveryIfNeeded() {
        guard canDeliver, !pending.isEmpty, delayTask == nil, deliveryTask == nil else { return }
        delayTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.uploadInterval) } catch { return }
            await self?.flush()
        }
    }

    func flush() async {
        delayTask?.cancel()
        delayTask = nil
        guard canDeliver, !pending.isEmpty else { return }
        if deliveryTask == nil {
            deliveryTask = Task { [weak self] in
                guard let self else { return }
                await deliverPending()
                deliveryTask = nil
                scheduleDeliveryIfNeeded()
            }
        }
        await deliveryTask?.value
    }

    func invalidate() {
        invalidated = true
        delayTask?.cancel()
        delayTask = nil
        deliveryTask?.cancel()
        pending.removeAll()
        retryNotBefore = nil
    }

    private func deliverPending() async {
        while !invalidated, !Task.isCancelled, !pending.isEmpty {
            let batch = Array(pending.prefix(64))
            guard let data = CallDiagnosticEnvelope(appVersion: appVersion, build: build, events: batch).encoded() else {
                recordFailure(.invalidResponse)
                retryNotBefore = now().advanced(by: .seconds(60))
                return
            }
            guard await deliverBatch(data), !invalidated, !Task.isCancelled else { return }
            // Only appends are allowed while uploading, so this acknowledged prefix
            // cannot consume newer records. Invalidation above is the sole reset.
            pending.removeFirst(batch.count)
        }
    }

    private func deliverBatch(_ data: Data) async -> Bool {
        var succeeded = false
        defer {
            if !succeeded, !invalidated {
                // Retain unacknowledged records. A later trigger, not this task,
                // may retry after cooldown; never spin on a failing endpoint.
                retryNotBefore = now().advanced(by: .seconds(60))
            }
        }
        for attempt in 0...3 {
            guard await waitForUploadSlot() else { return false }
            let result = await uploader.upload(data)
            guard !invalidated, !Task.isCancelled else { return false }
            guard case .failure(let error) = result else {
                succeeded = true
                lastUploadFailure = nil
                retryNotBefore = nil
                return true
            }
            recordFailure(error)
            if error == .unauthorized || error == .sessionUnavailable {
                invalidate()
                return false
            }
            guard attempt < 3, [.network, .rateLimited, .invalidResponse].contains(error) else { return false }
            // Retries reuse the exact bytes/IDs for idempotent server indexing.
            do { try await retrySleep(.seconds([15, 30, 60][attempt])) } catch { return false }
        }
        return false
    }

    private func waitForUploadSlot() async -> Bool {
        if let lastUploadAt {
            let remaining = now().duration(to: lastUploadAt.advanced(by: Self.uploadInterval))
            if remaining > .zero {
                do { try await retrySleep(remaining) } catch { return false }
            }
        }
        guard !invalidated, !Task.isCancelled else { return false }
        lastUploadAt = now()
        return true
    }

    private func recordFailure(_ error: JunchatDiagnosticsUploadError) {
        guard lastUploadFailure != error else { return }
        lastUploadFailure = error
        localFailureHandler(error)
    }
}

/// Call-scoped sequencing also prevents stale WebViews from reporting after teardown.
@MainActor
final class CallDiagnosticRecorder {
    private let collector: CallDiagnosticsCollector
    private let nativeSessionID = UUID().uuidString.lowercased()
    private var sequence = 0
    private var webSequences: [String: Int] = [:]
    private var ended = false

    init(collector: CallDiagnosticsCollector) {
        self.collector = collector
    }

    func consumeConsole(_ message: String, level: String) {
        guard !ended, let event = CallDiagnosticEvent.fromConsole(message, level: level) else { return }
        let key = event.sessionID.lowercased()
        guard key != nativeSessionID,
              webSequences[key] != nil || webSequences.count < 64,
              event.sequence > webSequences[key, default: 0] else { return }
        webSequences[key] = event.sequence
        collector.record(event)
    }

    func record(stage: CallDiagnosticEvent.Stage,
                status: CallDiagnosticEvent.Status,
                code: CallDiagnosticEvent.Code = .none,
                source: CallDiagnosticEvent.Source = .unknown,
                state: CallDiagnosticEvent.State? = nil,
                attempt: Int? = nil) {
        guard !ended, sequence < 1_000_000 else { return }
        sequence += 1
        collector.record(CallDiagnosticEvent(sessionID: nativeSessionID,
                                             sequence: sequence,
                                             occurredAt: ISO8601DateFormatter().string(from: Date()),
                                             component: .ios,
                                             stage: stage,
                                             status: status,
                                             code: code,
                                             source: source,
                                             attempt: attempt,
                                             state: state))
    }

    func flush() {
        Task { await collector.flush() }
    }

    func finish() {
        guard !ended else { return }
        record(stage: .lifecycle, status: .ended, state: .ended)
        ended = true
        webSequences.removeAll()
        flush()
    }
}
