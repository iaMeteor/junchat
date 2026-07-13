//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct CallPictureInPictureRequestTrackerTests {
    @Test
    func delegateEventsAreProcessedInArrivalOrder() async {
        var processedEvents = [Int]()
        var releaseFirstEvent: CheckedContinuation<Void, Never>?
        let processor = CallPictureInPictureDelegateEventProcessor<Int> { event in
            if event == 1 {
                await withCheckedContinuation { releaseFirstEvent = $0 }
            }
            processedEvents.append(event)
        }

        processor.send(1)
        processor.send(2)
        await waitUntil { releaseFirstEvent != nil }

        #expect(processedEvents.isEmpty)
        releaseFirstEvent?.resume()
        await waitUntil { processedEvents.count == 2 }
        #expect(processedEvents == [1, 2])
    }

    @Test
    func invalidatingDelegateEventsDropsQueuedWork() async {
        var processedEvents = [Int]()
        var releaseFirstEvent: CheckedContinuation<Void, Never>?
        let processor = CallPictureInPictureDelegateEventProcessor<Int> { event in
            if event == 1 {
                await withCheckedContinuation { releaseFirstEvent = $0 }
            }
            processedEvents.append(event)
        }

        processor.send(1)
        processor.send(2)
        await waitUntil { releaseFirstEvent != nil }
        processor.invalidate()
        releaseFirstEvent?.resume()
        await Task.yield()

        #expect(processedEvents == [1])
    }

    @Test
    func requestWaitsForTheDidStartCallback() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        var hasCompleted = false

        let task = Task { @MainActor in
            let result = await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
            hasCompleted = true
            return result
        }
        await waitUntil { beginCount == 1 }

        #expect(beginCount == 1)
        #expect(!hasCompleted)

        tracker.didStart()

        let result = await task.value
        expectSuccess(result)
        #expect(hasCompleted)
    }

    @Test
    func concurrentRequestsShareOneBeginAndResult() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        var secondRequestEntered = false

        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }
        let secondTask = Task { @MainActor in
            secondRequestEntered = true
            return await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { secondRequestEntered }

        #expect(beginCount == 1)

        tracker.didStart()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        expectSuccess(firstResult)
        expectSuccess(secondResult)
    }

    @Test
    func unavailableBeginFailsTheRequest() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))

        let result = await tracker.request { .unavailable }

        expectUnavailable(result)
    }

    @Test
    func failedStartReleasesEveryWaiter() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        var secondRequestEntered = false
        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }
        let secondTask = Task { @MainActor in
            secondRequestEntered = true
            return await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { secondRequestEntered }

        tracker.didFailToStart()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        #expect(beginCount == 1)
        expectUnavailable(firstResult)
        expectUnavailable(secondResult)
    }

    @Test
    func activeRequestDoesNotBeginAgain() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }
        tracker.didStart()

        let firstResult = await firstTask.value
        let secondResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }

        expectSuccess(firstResult)
        expectSuccess(secondResult)
        #expect(beginCount == 1)
    }

    @Test
    func timedOutDelegateAttemptBlocksAReplacementUntilItFinishes() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .milliseconds(10))
        var beginCount = 0

        let result = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }

        #expect(beginCount == 1)
        expectUnavailable(result)

        let blockedResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }
        expectUnavailable(blockedResult)
        #expect(beginCount == 1)

        tracker.didStart()

        let activeResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }
        expectSuccess(activeResult)
        #expect(beginCount == 1)
    }

    @Test
    func lateFailureAfterTimeoutAllowsANewAttempt() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .milliseconds(10))
        var beginCount = 0

        let timedOutResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }
        expectUnavailable(timedOutResult)

        let blockedResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }
        expectUnavailable(blockedResult)
        #expect(beginCount == 1)

        tracker.didFailToStart()
        let nextTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 2 }
        tracker.didStart()

        let nextResult = await nextTask.value
        expectSuccess(nextResult)
    }

    @Test
    func preflightTimeoutCanStartANewAttempt() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .milliseconds(10))
        var beginCount = 0

        let timedOutResult = await tracker.request {
            beginCount += 1
            try? await Task.sleep(for: .milliseconds(50))
            return .awaitingDelegate
        }
        expectUnavailable(timedOutResult)

        let nextResult = await tracker.request {
            beginCount += 1
            return .unavailable
        }
        expectUnavailable(nextResult)
        #expect(beginCount == 2)
    }

    @Test
    func cancellingTheOnlyWaiterDoesNotPermitASecondStart() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }

        firstTask.cancel()
        let firstResult = await firstTask.value
        expectUnavailable(firstResult)

        let secondTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await Task.yield()
        #expect(beginCount == 1)

        tracker.didStart()
        let secondResult = await secondTask.value
        expectSuccess(secondResult)
    }

    @Test
    func stoppedRequestCanBeginAgain() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }
        tracker.stopped()

        let firstResult = await firstTask.value
        expectUnavailable(firstResult)

        let secondTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 2 }
        tracker.didStart()

        let secondResult = await secondTask.value
        expectSuccess(secondResult)
        #expect(beginCount == 2)
    }

    @Test
    func invalidateReleasesWaitersAndRejectsFutureRequests() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        let task = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }

        tracker.invalidate()

        let pendingResult = await task.value
        let futureResult = await tracker.request {
            beginCount += 1
            return .awaitingDelegate
        }
        expectUnavailable(pendingResult)
        expectUnavailable(futureResult)
        #expect(beginCount == 1)
    }

    @Test
    func cancellingOneWaiterLeavesTheOtherRunning() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        var secondCompleted = false
        var secondRequestEntered = false
        let firstTask = Task { @MainActor in
            await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { beginCount == 1 }
        let secondTask = Task { @MainActor in
            secondRequestEntered = true
            let result = await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
            secondCompleted = true
            return result
        }
        await waitUntil { secondRequestEntered }

        firstTask.cancel()
        let firstResult = await firstTask.value
        await Task.yield()

        expectUnavailable(firstResult)
        #expect(!secondCompleted)
        #expect(beginCount == 1)

        tracker.didStart()
        let secondResult = await secondTask.value
        expectSuccess(secondResult)
    }

    @Test
    func automaticWillStartCoalescesARequest() async {
        let tracker = CallPictureInPictureRequestTracker(timeout: .seconds(1))
        var beginCount = 0
        var requestEntered = false
        tracker.willStart()

        let task = Task { @MainActor in
            requestEntered = true
            return await tracker.request {
                beginCount += 1
                return .awaitingDelegate
            }
        }
        await waitUntil { requestEntered }

        #expect(beginCount == 0)
        tracker.didStart()

        let result = await task.value
        expectSuccess(result)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<20 {
            guard !condition() else { return }
            await Task.yield()
        }
    }

    private func expectSuccess(_ result: Result<Void, CallScreenError>,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .success = result else {
            Issue.record("Expected picture in picture to start.", sourceLocation: sourceLocation)
            return
        }
    }

    private func expectUnavailable(_ result: Result<Void, CallScreenError>,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .failure(.pictureInPictureNotAvailable) = result else {
            Issue.record("Expected picture in picture to be unavailable.", sourceLocation: sourceLocation)
            return
        }
    }
}
