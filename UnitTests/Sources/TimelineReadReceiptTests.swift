//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Clocks
import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

@MainActor
struct TimelineReadReceiptTests {
    init() {
        AppSettings.resetAllSettings()
    }

    @Test(arguments: [true, false])
    func visibleEventSendsSelectedReceiptType(sharePresence: Bool) async throws {
        let timeline = try makeTimeline()
        let recorder = ReadReceiptRecorder()
        timeline.sendReadReceiptForTypeClosure = { await recorder.send(eventID: $0, type: $1) }
        ServiceLocator.shared.settings.sharePresence = sharePresence
        let controller = makeController(timeline: timeline)

        await controller.sendReadReceipt(for: itemID)

        #expect(await recorder.types == [sharePresence ? .read : .readPrivate, .fullyRead])
        #expect(await recorder.eventIDs == ["visible", "visible"])
        #expect(!timeline.markAsReadReceiptTypeCalled)
    }

    @Test
    func virtualAndLocalOnlyItemsDoNotSendReceipts() async throws {
        let timeline = try makeTimeline()
        let controller = makeController(timeline: timeline)

        await controller.sendReadReceipt(for: .virtual(uniqueID: .init("virtual")))
        await controller.sendReadReceipt(for: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("local")))

        #expect(!timeline.sendReadReceiptForTypeCalled)
    }

    @Test
    func transientFailureRetriesAndDeduplicatesInFlightVisibleEvent() async throws {
        let clock = TestClock<Duration>()
        let timeline = try makeTimeline()
        let controller = makeController(timeline: timeline, clock: clock)
        timeline.sendReadReceiptForTypeReturnValue = .failure(.sdkError(URLError(.notConnectedToInternet)))
        let task = Task { await controller.sendReadReceipt(for: itemID) }
        defer { task.cancel() }

        await clock.advance()
        #expect(timeline.sendReadReceiptForTypeCallsCount == 1)
        #expect(timeline.sendReadReceiptForTypeReceivedArguments?.eventID == "visible")
        await controller.sendReadReceipt(for: itemID)
        #expect(timeline.sendReadReceiptForTypeCallsCount == 1)

        timeline.sendReadReceiptForTypeReturnValue = .success(())
        await clock.advance(by: .seconds(1))
        await task.value
        await clock.run()

        #expect(timeline.sendReadReceiptForTypeCallsCount == 3)
        #expect(timeline.sendReadReceiptForTypeReceivedArguments?.eventID == "visible")
        #expect(timeline.sendReadReceiptForTypeReceivedArguments?.type == .fullyRead)
        #expect(!timeline.markAsReadReceiptTypeCalled)
    }

    @Test
    func persistentFailureStopsAfterThreeAttemptsAndAllowsLaterRequest() async throws {
        let clock = TestClock<Duration>()
        let timeline = try makeTimeline()
        let controller = makeController(timeline: timeline, clock: clock)
        timeline.sendReadReceiptForTypeReturnValue = .failure(.sdkError(URLError(.notConnectedToInternet)))
        let task = Task { await controller.sendReadReceipt(for: itemID) }
        defer { task.cancel() }

        await clock.advance()
        #expect(timeline.sendReadReceiptForTypeCallsCount == 1)
        await clock.advance(by: .seconds(1))
        #expect(timeline.sendReadReceiptForTypeCallsCount == 2)
        await clock.advance(by: .seconds(1))
        #expect(timeline.sendReadReceiptForTypeCallsCount == 2)
        await clock.advance(by: .seconds(1))
        await task.value
        await clock.run()
        #expect(timeline.sendReadReceiptForTypeCallsCount == 3)
        #expect(timeline.sendReadReceiptForTypeReceivedArguments?.type != .fullyRead)

        timeline.sendReadReceiptForTypeReturnValue = .success(())
        await controller.sendReadReceipt(for: itemID)
        #expect(timeline.sendReadReceiptForTypeCallsCount == 5)
    }

    @Test
    func cancellationStopsRetryAndReleasesInFlightRequest() async throws {
        let clock = TestClock<Duration>()
        let timeline = try makeTimeline()
        let controller = makeController(timeline: timeline, clock: clock)
        timeline.sendReadReceiptForTypeReturnValue = .failure(.sdkError(URLError(.notConnectedToInternet)))
        let task = Task { await controller.sendReadReceipt(for: itemID) }

        await clock.advance()
        #expect(timeline.sendReadReceiptForTypeCallsCount == 1)
        task.cancel()
        await task.value
        await clock.run()
        #expect(timeline.sendReadReceiptForTypeCallsCount == 1)

        timeline.sendReadReceiptForTypeReturnValue = .success(())
        await controller.sendReadReceipt(for: itemID)
        #expect(timeline.sendReadReceiptForTypeCallsCount == 3)
    }

    @Test
    func fullyReadFailureRetriesOnlyMarkerOnObservedEvent() async throws {
        let clock = TestClock<Duration>()
        let timeline = try makeTimeline()
        let recorder = ReadReceiptRecorder(fullyReadFailures: 1)
        let completedMarkerAttempts = PassthroughSubject<Void, Never>()
        let initialMarkerAttempt = deferFulfillment(completedMarkerAttempts) { _ in true }
        timeline.sendReadReceiptForTypeClosure = { eventID, type in
            let result = await recorder.send(eventID: eventID, type: type)
            if type == .fullyRead {
                completedMarkerAttempts.send(())
            }
            return result
        }
        ServiceLocator.shared.settings.sharePresence = true
        let controller = makeController(timeline: timeline, clock: clock)
        let task = Task { await controller.sendReadReceipt(for: itemID) }
        defer { task.cancel() }

        try await initialMarkerAttempt.fulfill()
        #expect(await recorder.types == [.read, .fullyRead])
        await controller.sendReadReceipt(for: itemID)
        #expect(await recorder.types == [.read, .fullyRead])
        await clock.advance(by: .seconds(1))
        await task.value

        #expect(await recorder.types == [.read, .fullyRead, .fullyRead])
        #expect(await recorder.eventIDs == ["visible", "visible", "visible"])
        #expect(!timeline.markAsReadReceiptTypeCalled)
    }

    @Test
    func fullyReadFailureIsBoundedAndCancellationStopsMarkerRetry() async throws {
        let clock = TestClock<Duration>()
        let timeline = try makeTimeline()
        let recorder = ReadReceiptRecorder(fullyReadFailures: 10)
        let completedMarkerAttempts = PassthroughSubject<Void, Never>()
        let initialMarkerAttempt = deferFulfillment(completedMarkerAttempts) { _ in true }
        timeline.sendReadReceiptForTypeClosure = { eventID, type in
            let result = await recorder.send(eventID: eventID, type: type)
            if type == .fullyRead {
                completedMarkerAttempts.send(())
            }
            return result
        }
        ServiceLocator.shared.settings.sharePresence = true
        let controller = makeController(timeline: timeline, clock: clock)
        let task = Task { await controller.sendReadReceipt(for: itemID) }
        defer { task.cancel() }

        try await initialMarkerAttempt.fulfill()
        let secondMarkerAttempt = deferFulfillment(completedMarkerAttempts) { _ in true }
        await clock.advance(by: .seconds(1))
        try await secondMarkerAttempt.fulfill()
        await clock.advance(by: .seconds(2))
        await task.value
        #expect(await recorder.types == [.read, .fullyRead, .fullyRead, .fullyRead])

        let markerAttemptBeforeCancellation = deferFulfillment(completedMarkerAttempts) { _ in true }
        let cancelledTask = Task { await controller.sendReadReceipt(for: itemID) }
        defer { cancelledTask.cancel() }
        try await markerAttemptBeforeCancellation.fulfill()
        cancelledTask.cancel()
        await cancelledTask.value
        await clock.run()
        #expect(await recorder.types == [.read, .fullyRead, .fullyRead, .fullyRead, .read, .fullyRead])
    }

    @Test
    func alreadyCancelledRequestDoesNotSend() async throws {
        let timeline = try makeTimeline()
        let controller = makeController(timeline: timeline)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.sendReadReceipt(for: itemID)
        }

        await task.value

        #expect(!timeline.sendReadReceiptForTypeCalled)
    }

    @Test
    func retryKeepsOriginalProviderEventAndReceiptTypeAfterFocusChanges() async throws {
        let clock = TestClock<Duration>()
        let originalTimeline = try makeTimeline()
        let replacementTimeline = try makeTimeline(kind: .detached)
        let room = JoinedRoomProxyMock(.init(name: ""))
        room.timeline = originalTimeline
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(replacementTimeline)
        ServiceLocator.shared.settings.sharePresence = true
        let controller = makeController(timeline: originalTimeline, room: room, clock: clock)
        let recorder = ReadReceiptRecorder(readFailures: 1)
        let completedReadAttempts = PassthroughSubject<Void, Never>()
        let initialReadAttempt = deferFulfillment(completedReadAttempts) { _ in true }
        originalTimeline.sendReadReceiptForTypeClosure = { eventID, type in
            let result = await recorder.send(eventID: eventID, type: type)
            completedReadAttempts.send(())
            return result
        }
        let task = Task { await controller.sendReadReceipt(for: itemID) }
        defer { task.cancel() }

        try await initialReadAttempt.fulfill()
        #expect(originalTimeline.sendReadReceiptForTypeCallsCount == 1)
        #expect(originalTimeline.sendReadReceiptForTypeReceivedArguments?.eventID == "visible")
        #expect(originalTimeline.sendReadReceiptForTypeReceivedArguments?.type == .read)
        let token = try #require(controller.providerMutationToken(ensuringProviderIsConfigured: true))
        guard case .success = await controller.focusOnEvent("other", timelineSize: 10, using: token) else {
            Issue.record("Could not switch the timeline provider")
            return
        }
        // The same event in the new provider is not suppressed by the old provider's pending request.
        await controller.sendReadReceipt(for: itemID)
        ServiceLocator.shared.settings.sharePresence = false
        await clock.advance(by: .seconds(1))
        await task.value

        #expect(await recorder.types == [.read, .read, .fullyRead])
        #expect(await recorder.eventIDs == ["visible", "visible", "visible"])
        #expect(replacementTimeline.sendReadReceiptForTypeCallsCount == 2)
        #expect(!originalTimeline.markAsReadReceiptTypeCalled)
        #expect(!replacementTimeline.markAsReadReceiptTypeCalled)
        #expect(!room.markAsReadReceiptTypeCalled)
    }

    private var itemID: TimelineItemIdentifier {
        .event(uniqueID: .init("visible"), eventOrTransactionID: .eventID("visible"))
    }

    private func makeTimeline(kind: TimelineKind = .live) throws -> TimelineProxyMock {
        let timeline = TimelineProxyMock(.init())
        let provider = try #require(timeline.timelineItemProvider as? TimelineItemProviderMock)
        provider.kind = kind
        provider.underlyingUpdatePublisher = Empty().eraseToAnyPublisher()
        return timeline
    }

    private func makeController(timeline: TimelineProxyMock,
                                room: JoinedRoomProxyMock? = nil,
                                clock: any Clock<Duration> = ContinuousClock()) -> TimelineController {
        let room = room ?? JoinedRoomProxyMock(.init(name: ""))
        room.timeline = timeline
        return TimelineController(roomProxy: room,
                                  timelineProxy: timeline,
                                  initialFocussedEventID: nil,
                                  timelineItemFactory: ReadReceiptTimelineItemFactory(),
                                  mediaProvider: MediaProviderMock(),
                                  appSettings: ServiceLocator.shared.settings,
                                  readReceiptRetryClock: clock)
    }
}

actor ReadReceiptRecorder {
    private(set) var types = [ReceiptType]()
    private(set) var eventIDs = [String]()
    private var readFailures: Int
    private var fullyReadFailures: Int

    init(readFailures: Int = 0, fullyReadFailures: Int = 0) {
        self.readFailures = readFailures
        self.fullyReadFailures = fullyReadFailures
    }

    func send(eventID: String, type: ReceiptType) -> Result<Void, TimelineProxyError> {
        types.append(type)
        eventIDs.append(eventID)
        if type == .fullyRead, fullyReadFailures > 0 {
            fullyReadFailures -= 1
            return .failure(.sdkError(URLError(.notConnectedToInternet)))
        }
        if type != .fullyRead, readFailures > 0 {
            readFailures -= 1
            return .failure(.sdkError(URLError(.notConnectedToInternet)))
        }
        return .success(())
    }
}

private struct ReadReceiptTimelineItemFactory: RoomTimelineItemFactoryProtocol {
    func buildTimelineItem(for eventItemProxy: EventTimelineItemProxy, isDM: Bool) -> RoomTimelineItemProtocol? {
        nil
    }

    func buildTimelineItemReply(_ details: InReplyToDetails) -> TimelineItemReply {
        fatalError("Not used by read receipt tests.")
    }
}
