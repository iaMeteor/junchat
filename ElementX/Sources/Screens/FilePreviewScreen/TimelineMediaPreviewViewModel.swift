//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias TimelineMediaPreviewViewModelType = StateStoreViewModel<TimelineMediaPreviewViewState, TimelineMediaPreviewViewAction>

class TimelineMediaPreviewViewModel: TimelineMediaPreviewViewModelType {
    static let displayMessageForwardingDelay: TimeInterval = 1.0
    
    let instanceID = UUID()
    
    private let timelineViewModel: TimelineViewModelProtocol
    private let mediaProvider: MediaProviderProtocol
    private let photoLibraryManager: PhotoLibraryManagerProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let appMediator: AppMediatorProtocol
    
    private let actionsSubject: PassthroughSubject<TimelineMediaPreviewViewModelAction, Never> = .init()
    var actions: AnyPublisher<TimelineMediaPreviewViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var prepareMessageForwardingTask: Task<Void, Never>?
    private var messageForwardingPreparationRequestID: UUID?
    
    init(initialItem: EventBasedMessageTimelineItemProtocol,
         timelineViewModel: TimelineViewModelProtocol,
         mediaProvider: MediaProviderProtocol,
         photoLibraryManager: PhotoLibraryManagerProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         appMediator: AppMediatorProtocol) {
        self.timelineViewModel = timelineViewModel
        self.mediaProvider = mediaProvider
        self.photoLibraryManager = photoLibraryManager
        self.userIndicatorController = userIndicatorController
        self.appMediator = appMediator
        
        let timelineState = timelineViewModel.context.viewState.timelineState
        
        super.init(initialViewState: TimelineMediaPreviewViewState(dataSource: .init(itemViewStates: timelineState.itemViewStates,
                                                                                     initialItem: initialItem,
                                                                                     paginationState: timelineState.paginationState)),
                   mediaProvider: mediaProvider)
        
        rebuildCurrentItemActions()
        
        let canRedactSelfPublisher = timelineViewModel.context.$viewState.map(\.canCurrentUserRedactSelf)
        let canRedactOthersPublisher = timelineViewModel.context.$viewState.map(\.canCurrentUserRedactOthers)
        
        canRedactSelfPublisher.merge(with: canRedactOthersPublisher)
            .sink { [weak self] _ in
                self?.rebuildCurrentItemActions()
            }
            .store(in: &cancellables)
        
        timelineViewModel.context.$viewState.map(\.timelineState.itemViewStates)
            .removeDuplicates()
            .sink { [weak self] itemViewStates in
                self?.cancelMessageForwardingPreparation(releasingProviderLease: true)
                self?.state.dataSource.updatePreviewItems(itemViewStates: itemViewStates)
            }
            .store(in: &cancellables)
        
        timelineViewModel.context.$viewState.map(\.timelineState.paginationState)
            .removeDuplicates()
            .sink { [weak self] paginationState in
                guard let self else { return }
                state.dataSource.paginationState = paginationState
                paginateIfNeeded()
            }
            .store(in: &cancellables)
    }
    
    override func process(viewAction: TimelineMediaPreviewViewAction) {
        switch viewAction {
        case .updateCurrentItem(let item):
            Task { await updateCurrentItem(item) }
        case .showItemDetails(let mediaItem):
            state.previewControllerDriver.send(.showItemDetails(mediaItem))
        case .menuAction(let action, let item):
            switch action {
            case .viewInRoomTimeline:
                state.previewControllerDriver.send(.dismissDetailsSheet)
                actionsSubject.send(.viewInRoomTimeline(item.timelineItem.id))
            case .save:
                Task { await saveCurrentItem() }
            case .redact:
                state.bindings.redactConfirmationItem = item
            case .forward(let itemID):
                forwardItem(itemID: itemID)
            default:
                MXLog.error("Received unexpected action: \(action)")
            }
        case .redactConfirmation(let item):
            redactItem(item)
        case .timelineEndReached:
            showTimelineEndIndicator()
        }
    }

    isolated deinit {
        prepareMessageForwardingTask?.cancel()
        timelineViewModel.cancelForwardingItemPreparation(preparationOwnerID: instanceID)
    }
    
    private func forwardItem(itemID: TimelineItemIdentifier) {
        cancelMessageForwardingPreparation(releasingProviderLease: false)
        let requestID = UUID()
        messageForwardingPreparationRequestID = requestID
        let preparationOwnerID = instanceID
        let timelineViewModel = timelineViewModel
        prepareMessageForwardingTask = Task { [weak self] in
            let forwardingItem = await timelineViewModel.makeForwardingItem(for: itemID,
                                                                            requestID: requestID,
                                                                            preparationOwnerID: preparationOwnerID)
            guard let self, let forwardingItem, !Task.isCancelled,
                  messageForwardingPreparationRequestID == requestID else {
                return
            }
            prepareMessageForwardingTask = nil
            messageForwardingPreparationRequestID = nil
            state.previewControllerDriver.send(.dismissDetailsSheet)
            actionsSubject.send(.displayMessageForwarding(.init(firstItem: forwardingItem)))
        }
    }

    private func cancelMessageForwardingPreparation(releasingProviderLease: Bool) {
        prepareMessageForwardingTask?.cancel()
        prepareMessageForwardingTask = nil
        messageForwardingPreparationRequestID = nil
        if releasingProviderLease {
            timelineViewModel.cancelForwardingItemPreparation(preparationOwnerID: instanceID)
        }
    }
    
    private func updateCurrentItem(_ previewItem: TimelineMediaPreviewItem) async {
        if case let .media(item) = previewItem {
            item.downloadError = nil // Clear any existing error.
        }
        state.dataSource.updateCurrentItem(previewItem)
        rebuildCurrentItemActions()
        
        if case let .media(mediaItem) = previewItem {
            if mediaItem.fileHandle == nil, let source = mediaItem.mediaSource {
                switch await mediaProvider.loadFileFromSource(source, filename: mediaItem.filename) {
                case .success(let handle):
                    mediaItem.fileHandle = handle
                    state.previewControllerDriver.send(.itemLoaded(mediaItem.id))
                case .failure(let error):
                    MXLog.error("Failed loading media: \(error)")
                    context.objectWillChange.send() // Manually trigger the SwiftUI view update.
                    mediaItem.downloadError = error
                }
            }
        } else {
            paginateIfNeeded()
        }
    }
    
    private func paginateIfNeeded() {
        switch state.currentItem {
        case .loading(.paginatingBackwards):
            if state.dataSource.paginationState.backward == .idle {
                timelineViewModel.context.send(viewAction: .paginateBackwards)
            }
        case .loading(.paginatingForwards):
            if state.dataSource.paginationState.forward == .idle {
                timelineViewModel.context.send(viewAction: .paginateForwards)
            }
        default:
            break
        }
    }
    
    private func rebuildCurrentItemActions() {
        let timelineContext = timelineViewModel.context
        state.currentItemActions = switch state.currentItem {
        case .media(let mediaItem):
            TimelineItemMenuActionProvider(timelineItem: mediaItem.timelineItem,
                                           canCurrentUserSendMessage: timelineContext.viewState.canCurrentUserSendMessage,
                                           canCurrentUserRedactSelf: timelineContext.viewState.canCurrentUserRedactSelf,
                                           canCurrentUserRedactOthers: timelineContext.viewState.canCurrentUserRedactOthers,
                                           canCurrentUserPin: timelineContext.viewState.canCurrentUserPin,
                                           pinnedEventIDs: timelineContext.viewState.pinnedEventIDs,
                                           isDM: timelineContext.viewState.isDirectOneToOneRoom,
                                           isViewSourceEnabled: timelineContext.viewState.isViewSourceEnabled,
                                           areThreadsEnabled: timelineContext.viewState.areThreadsEnabled,
                                           timelineKind: timelineContext.viewState.timelineKind,
                                           emojiProvider: timelineContext.viewState.emojiProvider)
                .makeActions()
        case .loading:
            nil
        }
    }
    
    private func saveCurrentItem() async {
        guard case let .media(mediaItem) = state.currentItem, let fileURL = mediaItem.fileHandle?.url else {
            MXLog.error("Unable to save an item without a URL, the button shouldn't be visible.")
            return
        }
        
        // Dismiss the details sheet (nicer flow for images/video but _required_ in order to select a file directory).
        state.previewControllerDriver.send(.dismissDetailsSheet)
        
        do {
            switch mediaItem.timelineItem {
            case is AudioRoomTimelineItem, is FileRoomTimelineItem:
                state.previewControllerDriver.send(.exportFile(.init(url: fileURL)))
                return // Don't show the indicator.
            case is ImageRoomTimelineItem:
                try await photoLibraryManager.addResource(.photo, at: fileURL).get()
            case is VideoRoomTimelineItem:
                try await photoLibraryManager.addResource(.video, at: fileURL).get()
            default:
                break
            }
            
            showSavedIndicator()
        } catch PhotoLibraryManagerError.notAuthorized {
            MXLog.error("Not authorised to save item to photo library")
            state.previewControllerDriver.send(.authorizationRequired(appMediator: appMediator))
        } catch {
            MXLog.error("Failed saving item: \(error)")
            showErrorIndicator()
        }
    }
    
    private func redactItem(_ item: TimelineMediaPreviewItem.Media) {
        timelineViewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.timelineItem.id, action: .redact))
        state.bindings.redactConfirmationItem = nil
        state.previewControllerDriver.send(.dismissDetailsSheet)
        actionsSubject.send(.dismiss)
        showRedactedIndicator()
    }
    
    // MARK: - Indicators
    
    private func showRedactedIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: statusIndicatorID,
                                                              type: .toast,
                                                              title: L10n.commonFileDeleted,
                                                              iconName: "checkmark"))
    }
    
    private func showSavedIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: statusIndicatorID,
                                                              type: .toast,
                                                              title: L10n.commonFileSaved,
                                                              iconName: "checkmark"))
    }
    
    private func showErrorIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: statusIndicatorID,
                                                              type: .toast,
                                                              title: L10n.errorUnknown,
                                                              iconName: "xmark"))
    }
    
    private func showTimelineEndIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: statusIndicatorID,
                                                              type: .toast,
                                                              title: L10n.screenMediaDetailsNoMoreMediaToShow))
    }
    
    private var statusIndicatorID: String {
        "\(Self.self)-Status"
    }
}
