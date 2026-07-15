//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias MediaEventsTimelineScreenViewModelType = StateStoreViewModelV2<MediaEventsTimelineScreenViewState, MediaEventsTimelineScreenViewAction>

private enum MediaEventsTimelineActionSource {
    case media
    case files

    init(screenMode: MediaEventsTimelineScreenMode) {
        self = switch screenMode {
        case .media: .media
        case .files: .files
        }
    }
}

private enum MediaEventsTimelineActionKind {
    case preview
    case details
}

private struct MediaEventsTimelineActionCredential {
    let source: MediaEventsTimelineActionSource
    let modeGeneration: UInt
    let itemID: TimelineItemIdentifier
    let actionKind: MediaEventsTimelineActionKind
}

class MediaEventsTimelineScreenViewModel: MediaEventsTimelineScreenViewModelType, MediaEventsTimelineScreenViewModelProtocol {
    private let mediaTimelineViewModel: TimelineViewModelProtocol
    private let filesTimelineViewModel: TimelineViewModelProtocol
    private let mediaProvider: MediaProviderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let appMediator: AppMediatorProtocol
    private let mediaPreviewForwardingHandoff: TimelineMediaPreviewForwardingHandoff
    
    private var isOldestItemVisible = false
    private var modeGeneration: UInt = 0
    private var activeTimelineActionSource: MediaEventsTimelineActionSource
    private var pendingMediaActionCredential: MediaEventsTimelineActionCredential?
    
    private var activeTimelineViewModel: TimelineViewModelProtocol {
        switch state.bindings.screenMode {
        case .media:
            mediaTimelineViewModel
        case .files:
            filesTimelineViewModel
        }
    }
    
    private var mediaPreviewCancellable: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<MediaEventsTimelineScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<MediaEventsTimelineScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(mediaTimelineViewModel: TimelineViewModelProtocol,
         filesTimelineViewModel: TimelineViewModelProtocol,
         initialScreenMode: MediaEventsTimelineScreenMode = .media,
         mediaProvider: MediaProviderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         appMediator: AppMediatorProtocol,
         mediaPreviewForwardingClock: any Clock<Duration> = ContinuousClock()) {
        self.mediaTimelineViewModel = mediaTimelineViewModel
        self.filesTimelineViewModel = filesTimelineViewModel
        self.mediaProvider = mediaProvider
        self.userIndicatorController = userIndicatorController
        self.appMediator = appMediator
        activeTimelineActionSource = .init(screenMode: initialScreenMode)
        mediaPreviewForwardingHandoff = .init(clock: mediaPreviewForwardingClock)
        
        let activeTimelineContext = switch initialScreenMode {
        case .media: mediaTimelineViewModel.context
        case .files: filesTimelineViewModel.context
        }
        
        super.init(initialViewState: .init(activeTimelineContext: activeTimelineContext, bindings: .init(screenMode: initialScreenMode)), mediaProvider: mediaProvider)
                
        mediaTimelineViewModel.context.$viewState.sink { [weak self] timelineViewState in
            guard let self, state.bindings.screenMode == .media else {
                return
            }
            
            updateWithTimelineViewState(timelineViewState)
        }
        .store(in: &cancellables)
        
        mediaTimelineViewModel.actions.sink { [weak self] action in
            self?.handleTimelineAction(action, source: .media)
        }
        .store(in: &cancellables)
        
        filesTimelineViewModel.context.$viewState.sink { [weak self] timelineViewState in
            guard let self, state.bindings.screenMode == .files else {
                return
            }
            
            updateWithTimelineViewState(timelineViewState)
        }
        .store(in: &cancellables)
        
        filesTimelineViewModel.actions.sink { [weak self] action in
            self?.handleTimelineAction(action, source: .files)
        }
        .store(in: &cancellables)
        
        updateWithTimelineViewState(activeTimelineViewModel.context.viewState)
    }
    
    // MARK: - Public
    
    override func process(viewAction: MediaEventsTimelineScreenViewAction) {
        MXLog.info("View model: received view action: \(viewAction)")
        
        switch viewAction {
        case .changedScreenMode:
            handleScreenModeChange()
        case .oldestItemDidAppear:
            isOldestItemVisible = true
            backPaginateIfNecessary(backPaginationState: activeTimelineViewModel.context.viewState.timelineState.paginationState.backward)
        case .oldestItemDidDisappear:
            isOldestItemVisible = false
        case .tappedItem(let item):
            registerMediaAction(itemID: item.identifier, actionKind: .preview)
            activeTimelineViewModel.context.send(viewAction: .mediaTapped(itemID: item.identifier))
        case .longPressedItem(let item):
            registerMediaAction(itemID: item.identifier, actionKind: .details)
            activeTimelineViewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.identifier))
        }
    }
    
    func stop() {
        invalidatePendingMediaAction()
        mediaTimelineViewModel.stop()
        filesTimelineViewModel.stop()
        cancelMediaPreviewForwardingHandoff()
        // Work around QLPreviewController dismissal issues, see the InteractiveQuickLookModifier.
        state.bindings.mediaPreviewViewModel = nil
        state.bindings.mediaPreviewSheetViewModel = nil
    }
    
    // MARK: - Private

    private var currentTimelineActionSource: MediaEventsTimelineActionSource {
        .init(screenMode: state.bindings.screenMode)
    }

    private func timelineViewModel(for source: MediaEventsTimelineActionSource) -> TimelineViewModelProtocol {
        switch source {
        case .media: mediaTimelineViewModel
        case .files: filesTimelineViewModel
        }
    }

    private func handleScreenModeChange() {
        let newSource = currentTimelineActionSource
        if newSource != activeTimelineActionSource {
            invalidatePendingMediaAction()
            cancelMediaPreviewForwardingHandoff()
            timelineViewModel(for: activeTimelineActionSource).stop()
            activeTimelineActionSource = newSource
        }

        state.activeTimelineContext = timelineViewModel(for: newSource).context
        updateWithTimelineViewState(activeTimelineViewModel.context.viewState)
    }

    private func handleTimelineAction(_ action: TimelineViewModelAction, source: MediaEventsTimelineActionSource) {
        switch action {
        case .displayMediaPreview(let mediaPreviewViewModel):
            guard case .media(let mediaItem) = mediaPreviewViewModel.state.currentItem,
                  consumePendingMediaAction(from: source, itemID: mediaItem.timelineItem.id, actionKind: .preview) else { return }
            displayMediaPreview(mediaPreviewViewModel)
        case .displayMediaDetails(item: let item):
            guard consumePendingMediaAction(from: source, itemID: item.id, actionKind: .details) else { return }
            displayMediaPreviewSheet(for: item)
        case .displayEmojiPicker, .displayReportContent, .displayCameraPicker, .displayMediaPicker,
             .displayDocumentPicker, .displayLocationPicker, .displayLiveLocation, .displayPollForm, .displayMediaUploadPreviewScreen,
             .displaySenderDetails, .displayMessageForwarding, .displayLocation, .displayResolveSendFailure,
             .displayThread, .composer, .hasScrolled, .viewInRoomTimeline, .displayRoom:
            break
        }
    }

    private func registerMediaAction(itemID: TimelineItemIdentifier, actionKind: MediaEventsTimelineActionKind) {
        pendingMediaActionCredential = .init(source: currentTimelineActionSource,
                                             modeGeneration: modeGeneration,
                                             itemID: itemID,
                                             actionKind: actionKind)
    }

    private func consumePendingMediaAction(from source: MediaEventsTimelineActionSource,
                                           itemID: TimelineItemIdentifier,
                                           actionKind: MediaEventsTimelineActionKind) -> Bool {
        guard source == currentTimelineActionSource,
              source == activeTimelineActionSource,
              let pendingMediaActionCredential,
              pendingMediaActionCredential.source == source,
              pendingMediaActionCredential.modeGeneration == modeGeneration,
              pendingMediaActionCredential.itemID == itemID,
              pendingMediaActionCredential.actionKind == actionKind else {
            return false
        }
        self.pendingMediaActionCredential = nil
        return true
    }

    private func invalidatePendingMediaAction() {
        modeGeneration &+= 1
        pendingMediaActionCredential = nil
    }

    private func displayMediaPreviewSheet(for item: EventBasedMessageTimelineItemProtocol) {
        cancelMediaPreviewForwardingHandoff()
        let sheetModel = TimelineMediaPreviewViewModel(initialItem: item,
                                                       timelineViewModel: activeTimelineViewModel,
                                                       mediaProvider: mediaProvider,
                                                       photoLibraryManager: PhotoLibraryManager(),
                                                       userIndicatorController: userIndicatorController,
                                                       appMediator: appMediator)
        mediaPreviewCancellable = sheetModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .displayMessageForwarding(let forwardingBatch):
                displayMessageForwarding(forwardingBatch: forwardingBatch)
            case .viewInRoomTimeline(let itemID):
                cancelMediaPreviewForwardingHandoff()
                state.bindings.mediaPreviewSheetViewModel = nil
                actionsSubject.send(.viewInRoomTimeline(itemID))
            case .dismiss:
                state.bindings.mediaPreviewSheetViewModel = nil
                cancelMediaPreviewForwardingHandoff()
            }
        }
        
        // Triggers a download of the item so that can be shared/saved
        sheetModel.context.send(viewAction: .updateCurrentItem(sheetModel.state.currentItem))
        state.bindings.mediaPreviewSheetViewModel = sheetModel
    }
    
    private func updateWithTimelineViewState(_ timelineViewState: TimelineViewState) {
        var newGroups = [MediaEventsTimelineGroup]()
        var currentItems = [RoomTimelineItemViewState]()
        
        timelineViewState.timelineState.itemViewStates.filter { itemViewState in
            switch itemViewState.type {
            case .image, .video:
                state.bindings.screenMode == .media
            case .audio, .file, .voice:
                state.bindings.screenMode == .files
            case .separator:
                true
            default:
                false
            }
        }.reversed().forEach { item in
            if case .separator(let item) = item.type {
                let group = MediaEventsTimelineGroup(id: item.id.uniqueID.value,
                                                     title: titleForDate(item.timestamp),
                                                     items: currentItems)
                if !currentItems.isEmpty {
                    newGroups.append(group)
                    currentItems = []
                }
            } else {
                currentItems.append(item)
            }
        }
        
        if !currentItems.isEmpty {
            MXLog.warning("Found ungrouped timeline items, appending them at end.")
            let group = MediaEventsTimelineGroup(id: UUID().uuidString,
                                                 title: titleForDate(.now),
                                                 items: currentItems)
            newGroups.append(group)
        }

        state.groups = newGroups
        
        state.isBackPaginating = timelineViewState.timelineState.paginationState.backward == .paginating
        state.shouldShowEmptyState = newGroups.isEmpty && timelineViewState.timelineState.paginationState.backward == .endReached
        backPaginateIfNecessary(backPaginationState: timelineViewState.timelineState.paginationState.backward)
    }
    
    private func backPaginateIfNecessary(backPaginationState: PaginationState) {
        if backPaginationState == .idle, isOldestItemVisible {
            activeTimelineViewModel.context.send(viewAction: .paginateBackwards)
        }
    }
    
    private func displayMediaPreview(_ viewModel: TimelineMediaPreviewViewModel) {
        cancelMediaPreviewForwardingHandoff()
        mediaPreviewCancellable = viewModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .displayMessageForwarding(let forwardingBatch):
                displayMessageForwarding(forwardingBatch: forwardingBatch)
            case .viewInRoomTimeline(let itemID):
                state.bindings.mediaPreviewViewModel = nil
                cancelMediaPreviewForwardingHandoff()
                actionsSubject.send(.viewInRoomTimeline(itemID))
            case .dismiss:
                state.bindings.mediaPreviewViewModel = nil
                cancelMediaPreviewForwardingHandoff()
            }
        }
        
        state.bindings.mediaPreviewViewModel = viewModel
    }
    
    private func titleForDate(_ date: Date) -> String {
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .month) {
            L10n.commonDateThisMonth
        } else {
            date.formatted(.dateTime.month(.wide).year())
        }
    }
    
    private func displayMessageForwarding(forwardingBatch: MessageForwardingBatch) {
        state.bindings.mediaPreviewViewModel = nil
        state.bindings.mediaPreviewSheetViewModel = nil
        mediaPreviewForwardingHandoff.schedule { [weak self] in
            guard let self else { return }
            mediaPreviewCancellable = nil
            actionsSubject.send(.displayMessageForwarding(forwardingBatch))
        }
    }

    private func cancelMediaPreviewForwardingHandoff() {
        mediaPreviewForwardingHandoff.cancel()
        mediaPreviewCancellable?.cancel()
        mediaPreviewCancellable = nil
    }
}
