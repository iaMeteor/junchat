//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import QuickLook
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
struct TimelineMediaPreviewViewModelTests {
    var viewModel: TimelineMediaPreviewViewModel!
    var context: TimelineMediaPreviewViewModel.Context {
        viewModel.context
    }

    var mediaProvider: MediaProviderMock!
    var photoLibraryManager: PhotoLibraryManagerMock!
    var timelineController: MockTimelineController!
    var timelineViewModel: TimelineViewModel!
    
    @Test
    mutating func loadingItem() async throws {
        // Given a fresh view model.
        setupViewModel()
        #expect(!mediaProvider.loadFileFromSourceFilenameCalled)
        #expect(context.viewState.currentItem == .media(context.viewState.dataSource.previewItems[0]))
        #expect(context.viewState.currentItemActions != nil)
        
        // When the preview controller sets the current item.
        try await loadInitialItem()
        
        // Then the view model should load the item and update its view state.
        #expect(mediaProvider.loadFileFromSourceFilenameCalled)
        #expect(context.viewState.currentItem == .media(context.viewState.dataSource.previewItems[0]))
        #expect(context.viewState.currentItemActions != nil)
    }
    
    @Test
    mutating func loadingItemFailure() async throws {
        // Given a fresh view model.
        setupViewModel()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        
        #expect(!mediaProvider.loadFileFromSourceFilenameCalled)
        #expect(mediaItem == context.viewState.dataSource.previewItems[0])
        #expect(mediaItem.downloadError == nil)
        
        // When the preview controller sets an item that fails to load.
        mediaProvider.loadFileFromSourceFilenameClosure = { _, _ in .failure(.failedRetrievingFile) }
        let failure = deferFailure(viewModel.state.previewControllerDriver, timeout: .seconds(1)) { $0.isItemLoaded }
        context.send(viewAction: .updateCurrentItem(.media(context.viewState.dataSource.previewItems[0])))
        try await failure.fulfill()
        
        // Then the view model should load the item and update its view state.
        #expect(mediaProvider.loadFileFromSourceFilenameCalled)
        #expect(mediaItem == context.viewState.dataSource.previewItems[0])
        #expect(mediaItem.downloadError != nil)
    }
    
    @Test
    mutating func swipingBetweenItems() async throws {
        // Given a view model with a loaded item.
        try await loadingItem()
        
        // When swiping to another item.
        let deferred = deferFulfillment(viewModel.state.previewControllerDriver) { $0.isItemLoaded }
        context.send(viewAction: .updateCurrentItem(.media(context.viewState.dataSource.previewItems[1])))
        try await deferred.fulfill()
        
        // Then the view model should load the item and update its view state.
        #expect(mediaProvider.loadFileFromSourceFilenameCallsCount == 2)
        #expect(context.viewState.currentItem == .media(context.viewState.dataSource.previewItems[1]))
        
        // When swiping back to the first item.
        let failure = deferFailure(viewModel.state.previewControllerDriver, timeout: .seconds(1)) { $0.isItemLoaded }
        context.send(viewAction: .updateCurrentItem(.media(context.viewState.dataSource.previewItems[0])))
        try await failure.fulfill()
        
        // Then the view model should not need to load the item, but should still update its view state.
        #expect(mediaProvider.loadFileFromSourceFilenameCallsCount == 2)
        #expect(context.viewState.currentItem == .media(context.viewState.dataSource.previewItems[0]))
    }
    
    @Test
    mutating func loadingMoreItems() async throws {
        // Given a view model with a loaded item.
        try await loadingItem()
        #expect(timelineController.paginateBackwardsCallCount == 0)
        
        // When swiping to a "loading more" item and there are more media items to load.
        timelineController.paginationState = .init(backward: .idle, forward: .endReached)
        timelineController.backPaginationResponses.append(RoomTimelineItemFixtures.mediaChunk)
        let failure = deferFailure(viewModel.state.previewControllerDriver, timeout: .seconds(1)) { $0.isItemLoaded }
        context.send(viewAction: .updateCurrentItem(.loading(.paginatingBackwards)))
        try await failure.fulfill()
        
        // Then there should no longer be a media preview and instead of loading any media, a pagination request should be made.
        #expect(mediaProvider.loadFileFromSourceFilenameCallsCount == 1)
        #expect(context.viewState.currentItem == .loading(.paginatingBackwards)) // Note: This item only changes when the preview controller handles the new items.
        #expect(timelineController.paginateBackwardsCallCount == 1)
    }
    
    @Test
    mutating func pagination() async throws {
        // Given a view model with a loaded item.
        try await loadingItem()
        #expect(context.viewState.dataSource.previewItems.count == 3)
        
        // When more items are added via a back pagination.
        let deferred = deferFulfillment(context.viewState.dataSource.previewItemsPaginationPublisher) { _ in true }
        timelineController.backPaginationResponses.append(makeItems())
        _ = await timelineController.paginateBackwards(requestSize: 20)
        try await deferred.fulfill()
        
        // And the preview controller attempts to update the current item (now at a new index in the array but it hasn't changed in the data source).
        mediaProvider.loadFileFromSourceFilenameClosure = { _, _ in .failure(.failedRetrievingFile) }
        let failure = deferFailure(viewModel.state.previewControllerDriver, timeout: .seconds(1)) { $0.isItemLoaded }
        context.send(viewAction: .updateCurrentItem(.media(context.viewState.dataSource.previewItems[3])))
        try await failure.fulfill()
        
        // Then the current item shouldn't need to be reloaded.
        #expect(context.viewState.dataSource.previewItems.count == 6)
        #expect(mediaProvider.loadFileFromSourceFilenameCallsCount == 1)
    }
    
    @Test
    mutating func viewInRoomTimeline() async throws {
        // Given a view model with a loaded item.
        try await loadingItem()
        
        // When choosing to view the current item in the timeline.
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item.")
            return
        }
        
        let deferred = deferFulfillment(viewModel.actions) { $0 == .viewInRoomTimeline(mediaItem.timelineItem.id) }
        context.send(viewAction: .menuAction(.viewInRoomTimeline, item: mediaItem))
        
        // Then the action should be sent upwards to make this happen.
        try await deferred.fulfill()
    }
    
    @Test
    mutating func redactConfirmation() async throws {
        // Given a view model with a loaded item.
        try await loadingItem()
        #expect(context.redactConfirmationItem == nil)
        #expect(!timelineController.redactCalled)
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item.")
            return
        }
        
        // When choosing to show the item details.
        let deferredDriver = deferFulfillment(context.viewState.previewControllerDriver) { $0.isShowItemDetails }
        context.send(viewAction: .showItemDetails(mediaItem))
        
        // Then the details sheet should be presented.
        let action = try await deferredDriver.fulfill()
        guard case let .showItemDetails(mediaDetailsItem) = action else {
            Issue.record("The action should include the media item.")
            return
        }
        #expect(.media(mediaDetailsItem) == context.viewState.currentItem)
        
        // When choosing to redact the item.
        context.send(viewAction: .menuAction(.redact, item: mediaItem))
        
        // Then the confirmation sheet should be presented.
        #expect(context.redactConfirmationItem == mediaItem)
        #expect(!timelineController.redactCalled)
        
        // When confirming the redaction.
        let deferred = deferFulfillment(viewModel.actions) { $0 == .dismiss }
        context.send(viewAction: .redactConfirmation(item: mediaItem))
        
        // Then the item should be redacted and the view should be dismissed.
        try await deferred.fulfill()
        #expect(timelineController.redactCalled)
    }

    @Test
    mutating func forwardingHoldsTheSourceProviderUntilPreparationCompletes() async throws {
        setupViewModel()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item.")
            return
        }
        let contentGate = MediaPreviewForwardingContentGate()
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == mediaItem.timelineItem.id }
        let forwarded = deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == [mediaItem.timelineItem.id]
        }

        context.send(viewAction: .menuAction(.forward(itemID: mediaItem.timelineItem.id), item: mediaItem))
        try await contentRequested.fulfill()
        await timelineViewModel.focusOnEvent(eventID: "newer-focus")
        let focusOnEventCallCount = timelineController.focusOnEventCallCount
        contentGate.resume()
        try await forwarded.fulfill()

        #expect(focusOnEventCallCount == 0)
    }

    @Test
    mutating func forwardingRejectsContentExtractedBeforeAnEdit() async throws {
        try await assertForwardingIsInvalidated { item in
            Self.makeImageItem(id: item.id, caption: "Edited after forwarding started")
        }
    }

    @Test
    mutating func forwardingRejectsContentExtractedBeforeRedaction() async throws {
        try await assertForwardingIsInvalidated { item in
            RedactedRoomTimelineItem(id: item.id,
                                     body: "Message deleted",
                                     timestamp: item.timestamp,
                                     isOutgoing: item.isOutgoing,
                                     isEditable: false,
                                     canBeRepliedTo: false,
                                     sender: item.sender)
        }
    }

    @Test
    mutating func newerForwardingRequestWaitsForCancelledExtractionToReleaseItsLease() async throws {
        setupViewModel()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item.")
            return
        }
        let contentGate = MediaPreviewForwardingContentGate()
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        var forwardingActionCount = 0
        let cancellable = viewModel.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }

        let firstContentRequested = deferFulfillment(contentGate.requests) { $0 == mediaItem.timelineItem.id }
        context.send(viewAction: .menuAction(.forward(itemID: mediaItem.timelineItem.id), item: mediaItem))
        try await firstContentRequested.fulfill()

        let secondContentRequested = deferFulfillment(contentGate.requests, timeout: .milliseconds(250)) { $0 == mediaItem.timelineItem.id }
        let forwarded = deferFulfillment(viewModel.actions) { action in
            guard case .displayMessageForwarding(let forwardingBatch) = action else { return false }
            return forwardingBatch.items.map(\.id) == [mediaItem.timelineItem.id]
        }
        context.send(viewAction: .menuAction(.forward(itemID: mediaItem.timelineItem.id), item: mediaItem))
        contentGate.resume()
        try await secondContentRequested.fulfill()

        contentGate.resume()
        try await forwarded.fulfill()

        #expect(forwardingActionCount == 1)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    mutating func deinitializingMediaPreviewCancelsForwardingPreparation() async throws {
        setupViewModel()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        let contentGate = MediaPreviewForwardingContentGate()
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        var forwardingActionCount = 0
        let cancellable = viewModel.actions.sink { action in
            guard case .displayMessageForwarding = action else { return }
            forwardingActionCount += 1
        }
        weak let weakViewModel = viewModel
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == mediaItem.timelineItem.id }
        context.send(viewAction: .menuAction(.forward(itemID: mediaItem.timelineItem.id), item: mediaItem))
        try await contentRequested.fulfill()

        viewModel = nil
        await Task.yield()
        let providerMutationToken = timelineController.providerMutationToken()
        contentGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(weakViewModel == nil)
        #expect(providerMutationToken != nil)
        #expect(forwardingActionCount == 0)
        withExtendedLifetime(cancellable) { }
    }

    @Test
    mutating func saveImage() async throws {
        // Given a view model with a loaded image.
        try await loadingItem()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        #expect(mediaItem.contentType == UTType.jpeg.localizedDescription)
        
        // When choosing to save the image.
        context.send(viewAction: .menuAction(.save, item: mediaItem))
        try await Task.sleep(for: .seconds(0.5))
        
        // Then the image should be saved as a photo to the user's photo library.
        #expect(photoLibraryManager.addResourceAtCalled)
        #expect(photoLibraryManager.addResourceAtReceivedArguments?.type == .photo)
        #expect(photoLibraryManager.addResourceAtReceivedArguments?.url == mediaItem.fileHandle?.url)
    }
    
    @Test
    mutating func saveImageWithoutAuthorization() async throws {
        // Given a view model with a loaded image where the user has denied access to the photo library.
        setupViewModel(photoLibraryAuthorizationDenied: true)
        try await loadInitialItem()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        #expect(mediaItem.contentType == UTType.jpeg.localizedDescription)
        
        // When choosing to save the image.
        let deferred = deferFulfillment(context.viewState.previewControllerDriver) { $0.isAuthorizationRequired }
        context.send(viewAction: .menuAction(.save, item: mediaItem))
        
        // Then the user should be prompted to allow access.
        try await deferred.fulfill()
        #expect(photoLibraryManager.addResourceAtCalled)
    }
    
    @Test
    mutating func saveVideo() async throws {
        // Given a view model with a loaded video.
        setupViewModel(initialItemIndex: 1)
        try await loadInitialItem()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        #expect(mediaItem.contentType == UTType.mpeg4Movie.localizedDescription)
        
        // When choosing to save the video.
        context.send(viewAction: .menuAction(.save, item: mediaItem))
        try await Task.sleep(for: .seconds(0.5))
        
        // Then the video should be saved as a video in the user's photo library.
        #expect(photoLibraryManager.addResourceAtCalled)
        #expect(photoLibraryManager.addResourceAtReceivedArguments?.type == .video)
        #expect(photoLibraryManager.addResourceAtReceivedArguments?.url == mediaItem.fileHandle?.url)
    }
    
    @Test
    mutating func saveFile() async throws {
        // Given a view model with a loaded file.
        setupViewModel(initialItemIndex: 2)
        try await loadInitialItem()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item")
            return
        }
        #expect(mediaItem.contentType == UTType.pdf.localizedDescription)
        
        // When choosing to save the file.
        let deferred = deferFulfillment(context.viewState.previewControllerDriver) { $0.isExportFile }
        context.send(viewAction: .menuAction(.save, item: mediaItem))
        let exportAction = try await deferred.fulfill()
        
        guard case let .exportFile(file) = exportAction else {
            Issue.record("Unexpected action")
            return
        }
        
        // Then the binding should be set for the user to export the file to their specified location.
        #expect(!photoLibraryManager.addResourceAtCalled)
        #expect(file.url == mediaItem.fileHandle?.url)
    }
    
    // MARK: - Helpers
    
    private func loadInitialItem() async throws {
        let deferred = deferFulfillment(viewModel.state.previewControllerDriver) { $0.isItemLoaded }
        let initialItem = context.viewState.dataSource.previewController(QLPreviewController(),
                                                                         previewItemAt: context.viewState.dataSource.initialItemIndex)
        guard let initialPreviewItem = initialItem as? TimelineMediaPreviewItem.Media else {
            Issue.record("The initial item should be a media preview.")
            return
        }
        context.send(viewAction: .updateCurrentItem(.media(initialPreviewItem)))
        try await deferred.fulfill()
    }
    
    private mutating func setupViewModel(initialItemIndex: Int = 0, photoLibraryAuthorizationDenied: Bool = false) {
        let initialItems = makeItems()
        timelineController = MockTimelineController(timelineKind: .media(.mediaFilesScreen))
        timelineController.timelineItems = initialItems
        
        mediaProvider = MediaProviderMock(configuration: .init())
        photoLibraryManager = PhotoLibraryManagerMock(.init(authorizationDenied: photoLibraryAuthorizationDenied))
        
        timelineViewModel = TimelineViewModel.mock(timelineKind: .media(.mediaFilesScreen),
                                                   timelineController: timelineController)
        viewModel = TimelineMediaPreviewViewModel(initialItem: initialItems[initialItemIndex],
                                                  timelineViewModel: timelineViewModel,
                                                  mediaProvider: mediaProvider,
                                                  photoLibraryManager: photoLibraryManager,
                                                  userIndicatorController: UserIndicatorControllerMock(),
                                                  appMediator: AppMediatorMock())
    }

    private mutating func assertForwardingIsInvalidated(replacement: (EventBasedMessageTimelineItemProtocol) -> RoomTimelineItemProtocol) async throws {
        setupViewModel()
        guard case let .media(mediaItem) = context.viewState.currentItem else {
            Issue.record("There should be a current item.")
            return
        }
        let contentGate = MediaPreviewForwardingContentGate()
        defer { contentGate.resume() }
        timelineController.messageEventContentClosure = { itemID in
            await contentGate.content(for: itemID)
        }
        let contentRequested = deferFulfillment(contentGate.requests) { $0 == mediaItem.timelineItem.id }
        let noForward = deferFailure(viewModel.actions, timeout: .milliseconds(150)) { action in
            guard case .displayMessageForwarding = action else { return false }
            return true
        }
        let noDismiss = deferFailure(viewModel.state.previewControllerDriver, timeout: .milliseconds(150)) { action in
            guard case .dismissDetailsSheet = action else { return false }
            return true
        }

        context.send(viewAction: .menuAction(.forward(itemID: mediaItem.timelineItem.id), item: mediaItem))
        try await contentRequested.fulfill()

        let replacementItem = replacement(mediaItem.timelineItem)
        let replacementType = RoomTimelineItemType(item: replacementItem)
        let replacementPublished = deferFulfillment(timelineViewModel.context.$viewState) { state in
            state.timelineState.itemViewStates.first?.type == replacementType
        }
        timelineController.timelineItems = [replacementItem]
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [replacementItem],
                                                                isSwitchingTimelines: false,
                                                                providerGeneration: timelineController.timelineItemsProviderGeneration,
                                                                timelineItemsGeneration: timelineController.timelineItemsGeneration))
        try await replacementPublished.fulfill()

        contentGate.resume()
        try await noForward.fulfill()
        try await noDismiss.fulfill()
    }
    
    private func makeItems() -> [EventBasedMessageTimelineItemProtocol] {
        [
            Self.makeImageItem(),
            VideoRoomTimelineItem(id: .randomEvent,
                                  timestamp: .mock,
                                  isOutgoing: false,
                                  isEditable: false,
                                  canBeRepliedTo: true,
                                  sender: .init(id: ""),
                                  content: .init(filename: "Super video.mp4",
                                                 videoInfo: .mockVideo,
                                                 thumbnailInfo: .mockThumbnail,
                                                 contentType: .mpeg4Movie)),
            FileRoomTimelineItem(id: .randomEvent,
                                 timestamp: .mock,
                                 isOutgoing: false,
                                 isEditable: false,
                                 canBeRepliedTo: true,
                                 sender: .init(id: ""),
                                 content: .init(filename: "Important file.pdf",
                                                source: try? .init(url: .mockMXCFile, mimeType: "document/pdf"),
                                                fileSize: 2453,
                                                thumbnailSource: nil,
                                                contentType: .pdf))
        ]
    }

    private static func makeImageItem(id: TimelineItemIdentifier = .randomEvent,
                                      caption: String = "A caption goes right here.") -> ImageRoomTimelineItem {
        ImageRoomTimelineItem(id: id,
                              timestamp: .mock,
                              isOutgoing: false,
                              isEditable: false,
                              canBeRepliedTo: true,
                              sender: .init(id: "", displayName: "Sally Sanderson"),
                              content: .init(filename: "Amazing image.jpeg",
                                             caption: caption,
                                             imageInfo: .mockImage,
                                             thumbnailInfo: .mockThumbnail,
                                             contentType: .jpeg))
    }
}

@MainActor
private final class MediaPreviewForwardingContentGate {
    let requests = PassthroughSubject<TimelineItemIdentifier, Never>()
    private var continuation: CheckedContinuation<RoomMessageEventContentWithoutRelation?, Never>?

    func content(for itemID: TimelineItemIdentifier) async -> RoomMessageEventContentWithoutRelation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requests.send(itemID)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: .init(noHandle: .init()))
    }
}
