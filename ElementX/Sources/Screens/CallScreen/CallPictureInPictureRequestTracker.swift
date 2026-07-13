//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

@MainActor
final class CallPictureInPictureRequestTracker {
    enum BeginResult {
        case awaitingDelegate
        case unavailable
    }

    typealias RequestResult = Result<Void, CallScreenError>

    private struct Attempt {
        let id: UUID
        var waiters = [UUID: CheckedContinuation<RequestResult, Never>]()
        var beginTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private enum State {
        case idle
        case starting(Attempt)
        case timedOut(UUID)
        case active
        case invalidated
    }

    private let timeout: Duration
    private var state = State.idle

    init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    func request(begin: @escaping @MainActor () async -> BeginResult) async -> RequestResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.pictureInPictureNotAvailable))
                    return
                }

                switch state {
                case .idle:
                    var attempt = Attempt(id: UUID())
                    attempt.waiters[waiterID] = continuation
                    state = .starting(attempt)
                    startAttempt(id: attempt.id, begin: begin)
                case .starting(var attempt):
                    attempt.waiters[waiterID] = continuation
                    state = .starting(attempt)
                case .timedOut:
                    continuation.resume(returning: .failure(.pictureInPictureNotAvailable))
                case .active:
                    continuation.resume(returning: .success(()))
                case .invalidated:
                    continuation.resume(returning: .failure(.pictureInPictureNotAvailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    func willStart() {
        guard case .idle = state else { return }

        let attempt = Attempt(id: UUID())
        state = .starting(attempt)
        scheduleTimeout(for: attempt.id)
    }

    func didStart() {
        switch state {
        case .starting(let attempt):
            completeAttempt(id: attempt.id, with: .success(()), nextState: .active)
        case .timedOut:
            state = .active
        case .idle, .active, .invalidated:
            break
        }
    }

    func didFailToStart() {
        switch state {
        case .starting(let attempt):
            completeAttempt(id: attempt.id,
                            with: .failure(.pictureInPictureNotAvailable),
                            nextState: .idle)
        case .timedOut:
            state = .idle
        case .idle, .active, .invalidated:
            break
        }
    }

    func stopped() {
        switch state {
        case .starting(let attempt):
            completeAttempt(id: attempt.id,
                            with: .failure(.pictureInPictureNotAvailable),
                            nextState: .idle)
        case .active:
            state = .idle
        case .timedOut:
            state = .idle
        case .idle, .invalidated:
            break
        }
    }

    func invalidate() {
        switch state {
        case .starting(let attempt):
            completeAttempt(id: attempt.id,
                            with: .failure(.pictureInPictureNotAvailable),
                            nextState: .invalidated)
        case .idle, .timedOut, .active:
            state = .invalidated
        case .invalidated:
            break
        }
    }

    private func startAttempt(id: UUID,
                              begin: @escaping @MainActor () async -> BeginResult) {
        let beginTask = Task { @MainActor [weak self] in
            let result = await begin()
            guard !Task.isCancelled else { return }
            self?.finishBegin(result, attemptID: id)
        }
        let timeoutTask = makeTimeoutTask(for: id)

        guard case .starting(var attempt) = state, attempt.id == id else {
            beginTask.cancel()
            timeoutTask.cancel()
            return
        }
        attempt.beginTask = beginTask
        attempt.timeoutTask = timeoutTask
        state = .starting(attempt)
    }

    private func scheduleTimeout(for attemptID: UUID) {
        let timeoutTask = makeTimeoutTask(for: attemptID)
        guard case .starting(var attempt) = state, attempt.id == attemptID else {
            timeoutTask.cancel()
            return
        }
        attempt.timeoutTask = timeoutTask
        state = .starting(attempt)
    }

    private func makeTimeoutTask(for attemptID: UUID) -> Task<Void, Never> {
        Task { @MainActor [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeOutAttempt(id: attemptID)
        }
    }

    private func finishBegin(_ result: BeginResult, attemptID: UUID) {
        guard case .starting(var attempt) = state, attempt.id == attemptID else { return }

        switch result {
        case .awaitingDelegate:
            attempt.beginTask = nil
            state = .starting(attempt)
        case .unavailable:
            completeAttempt(id: attemptID,
                            with: .failure(.pictureInPictureNotAvailable),
                            nextState: .idle)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard case .starting(var attempt) = state,
              let continuation = attempt.waiters.removeValue(forKey: id) else {
            return
        }

        state = .starting(attempt)
        continuation.resume(returning: .failure(.pictureInPictureNotAvailable))
    }

    private func timeOutAttempt(id: UUID) {
        guard case .starting(let attempt) = state, attempt.id == id else { return }

        if attempt.beginTask != nil {
            completeAttempt(id: id,
                            with: .failure(.pictureInPictureNotAvailable),
                            nextState: .idle)
            return
        }

        state = .timedOut(id)
        attempt.waiters.values.forEach { $0.resume(returning: .failure(.pictureInPictureNotAvailable)) }
    }

    private func completeAttempt(id: UUID,
                                 with result: RequestResult,
                                 nextState: State) {
        guard case .starting(let attempt) = state, attempt.id == id else { return }

        state = nextState
        attempt.beginTask?.cancel()
        attempt.timeoutTask?.cancel()
        attempt.waiters.values.forEach { $0.resume(returning: result) }
    }
}

@MainActor
final class CallPictureInPictureDelegateEventProcessor<Event: Sendable> {
    private nonisolated let continuation: AsyncStream<Event>.Continuation
    private let stream: AsyncStream<Event>
    private var processingTask: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.stream = stream
        self.continuation = continuation
    }

    convenience init(handler: @escaping @MainActor (Event) async -> Void) {
        self.init()
        start(handler: handler)
    }

    func start(handler: @escaping @MainActor (Event) async -> Void) {
        guard processingTask == nil else { return }

        processingTask = Task { @MainActor in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await handler(event)
            }
        }
    }

    nonisolated func send(_ event: Event) {
        continuation.yield(event)
    }

    func invalidate() {
        continuation.finish()
        processingTask?.cancel()
        processingTask = nil
    }

    deinit {
        continuation.finish()
        processingTask?.cancel()
    }
}
