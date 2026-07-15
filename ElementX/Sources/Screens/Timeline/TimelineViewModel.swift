//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Algorithms
import Combine
import MatrixRustSDK
import OrderedCollections
import SwiftUI

typealias TimelineViewModelType = StateStoreViewModel<TimelineViewState, TimelineViewAction>

// swiftlint:disable:next type_body_length
class TimelineViewModel: TimelineViewModelType, TimelineViewModelProtocol {
    private enum Constants {
        static let paginationEventLimit: UInt16 = 20
        static let detachedTimelineSize: UInt16 = 100
        static let focusTimelineToastIndicatorID = "RoomScreenFocusTimelineToastIndicator"
        static let toastErrorID = "RoomScreenToastError"
    }

    private enum PrivacyModeAuthorityResolutionError: Error {
        case timedOut
    }

    private let roomProxy: JoinedRoomProxyProtocol
    private let timelineController: TimelineControllerProtocol
    private let userSession: UserSessionProtocol
    private let mediaPlayerProvider: MediaPlayerProviderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let appMediator: AppMediatorProtocol
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let emojiProvider: EmojiProviderProtocol
    private let timelineControllerFactory: TimelineControllerFactoryProtocol
    private let privacyModeAuthorityTimeout: Duration

    private let timelineInteractionHandler: TimelineInteractionHandler

    private let composerFocusedSubject = PassthroughSubject<Bool, Never>()

    private let actionsSubject: PassthroughSubject<TimelineViewModelAction, Never> = .init()
    var actions: AnyPublisher<TimelineViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private var currentUserProxy: RoomMemberProxyProtocol?

    private var paginateBackwardsTask: Task<Void, Never>?
    private var paginateForwardsTask: Task<Void, Never>?
    private var sendMessageTasks = [UUID: Task<Void, Never>]()
    private var prepareMessageForwardingTask: Task<Void, Never>?
    private var prepareDirectMessageForwardingTask: Task<Void, Never>?
    private var redactMessagesTask: Task<Void, Never>?
    private var mediaTapTask: Task<Void, Never>?
    private var mediaTapRequestID: UUID?
    private var messageForwardingPreparationGeneration = 0
    private var messageSelectionProviderLease: TimelineProviderLease?
    private let directMessageForwardingPreparationOwnerID = UUID()
    private var directMessageForwardingPreparationRequestID: UUID?
    private let forwardingItemPreparer: TimelineForwardingItemPreparer
    private var renderedProviderGeneration: UInt
    private var renderedTimelineItemsGeneration: UInt

    init(roomProxy: JoinedRoomProxyProtocol,
         focussedEventID: String? = nil,
         timelineController: TimelineControllerProtocol,
         userSession: UserSessionProtocol,
         mediaPlayerProvider: MediaPlayerProviderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         analyticsService: AnalyticsService,
         emojiProvider: EmojiProviderProtocol,
         linkMetadataProvider: LinkMetadataProviderProtocol,
         timelineControllerFactory: TimelineControllerFactoryProtocol,
         privacyModeAuthorityTimeout: Duration = .seconds(1)) {
        self.roomProxy = roomProxy
        self.timelineController = timelineController
        self.userSession = userSession
        self.mediaPlayerProvider = mediaPlayerProvider
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.userIndicatorController = userIndicatorController
        self.appMediator = appMediator
        self.emojiProvider = emojiProvider
        self.timelineControllerFactory = timelineControllerFactory
        self.privacyModeAuthorityTimeout = privacyModeAuthorityTimeout
        forwardingItemPreparer = TimelineForwardingItemPreparer(roomID: roomProxy.id,
                                                                timelineController: timelineController)
        renderedProviderGeneration = timelineController.timelineItemsProviderGeneration
        renderedTimelineItemsGeneration = timelineController.timelineItemsGeneration

        let voiceMessageRecorder = VoiceMessageRecorder(audioRecorder: AudioRecorder(), mediaPlayerProvider: mediaPlayerProvider)

        timelineInteractionHandler = TimelineInteractionHandler(roomProxy: roomProxy,
                                                                timelineController: timelineController,
                                                                userSession: userSession,
                                                                mediaPlayerProvider: mediaPlayerProvider,
                                                                voiceMessageRecorder: voiceMessageRecorder,
                                                                userIndicatorController: userIndicatorController,
                                                                appMediator: appMediator,
                                                                appSettings: appSettings,
                                                                analyticsService: analyticsService,
                                                                emojiProvider: emojiProvider,
                                                                linkMetadataProvider: linkMetadataProvider,
                                                                timelineControllerFactory: timelineControllerFactory)

        let hideTimelineMedia = switch userSession.clientProxy.timelineMediaVisibilityPublisher.value {
        case .always:
            false
        case .privateOnly:
            !(roomProxy.infoPublisher.value.isPrivate ?? true)
        case .never:
            true
        }
        super.init(initialViewState: TimelineViewState(timelineKind: timelineController.timelineKind,
                                                       roomID: roomProxy.id,
                                                       isDirectOneToOneRoom: roomProxy.isDirectOneToOneRoom,
                                                       timelineState: TimelineState(focussedEvent: focussedEventID.map { .init(eventID: $0, appearance: .immediate) }),
                                                       ownUserID: roomProxy.ownUserID,
                                                       hideTimelineMedia: hideTimelineMedia,
                                                       isEmergencyPrivacyModeEnabled: appSettings.junchatEmergencyPrivacyModeEnabled,
                                                       isViewSourceEnabled: appSettings.viewSourceEnabled,
                                                       areThreadsEnabled: appSettings.threadsEnabled,
                                                       linkPreviewsEnabled: appSettings.linkPreviewsEnabled,
                                                       hasPredecessor: roomProxy.predecessorRoom != nil,
                                                       pinnedEventIDs: roomProxy.infoPublisher.value.pinnedEventIDs,
                                                       emojiProvider: emojiProvider,
                                                       linkMetadataProvider: hideTimelineMedia ? nil : linkMetadataProvider,
                                                       mapTilerConfiguration: appSettings.mapTilerConfiguration,
                                                       bindings: .init(reactionsCollapsed: [:])),
                   mediaProvider: userSession.mediaProvider)

        if focussedEventID != nil {
            // The timeline controller will start loading a detached timeline.
            showFocusLoadingIndicator()
        }

        setupSubscriptions()
        setupDirectRoomSubscriptionsIfNeeded()

        state.audioPlayerStateProvider = { [weak self] itemID -> AudioPlayerState? in
            guard let self else {
                return nil
            }

            return self.timelineInteractionHandler.audioPlayerState(for: itemID)
        }

        state.pillContextUpdater = { [weak self] pillContext in
            self?.pillContextUpdater(pillContext)
        }

        state.roomNameForIDResolver = { [weak self] roomID in
            self?.userSession.clientProxy.roomSummaryForIdentifier(roomID)?.name
        }

        state.roomNameForAliasResolver = { [weak self] alias in
            self?.userSession.clientProxy.roomSummaryForAlias(alias)?.name
        }

        state.timelineState.paginationState = timelineController.paginationState
        buildTimelineViews(timelineItems: timelineController.timelineItems)

        updateRoomInfo(roomProxy.infoPublisher.value)
        updateMembers(roomProxy.membersPublisher.value)

        // Note: beware if we get to e.g. restore a reply / edit,
        // maybe we are tracking a non-needed first initial state
        trackComposerMode(.default)
    }

    isolated deinit {
        prepareMessageForwardingTask?.cancel()
        prepareDirectMessageForwardingTask?.cancel()
        redactMessagesTask?.cancel()
        mediaTapTask?.cancel()
        forwardingItemPreparer.cancel(preparationOwnerID: directMessageForwardingPreparationOwnerID)
        for task in sendMessageTasks.values {
            task.cancel()
        }
        if let messageSelectionProviderLease {
            timelineController.releaseProviderLease(messageSelectionProviderLease)
        }
    }

    // MARK: - Public

    func stop() {
        cancelMediaTap()
    }

    override func process(viewAction: TimelineViewAction) {
        if state.messageSelectionState.isActive, viewAction.isBlockedDuringMessageSelection {
            cancelMessageForwardingPreparation()
            return
        }

        switch viewAction {
        case .itemAppeared(let id):
            Task { await timelineController.processItemAppearance(id) }
        case .itemDisappeared(let id):
            Task { await timelineController.processItemDisappearance(id) }
        case .mediaTapped(let id):
            handleMediaTapped(with: id)
        case .itemSendInfoTapped(let itemID):
            handleItemSendInfoTapped(itemID: itemID)
        case .toggleReaction(let emoji, let itemID):
            emojiProvider.markEmojiAsFrequentlyUsed(emoji)

            guard case let .event(_, eventOrTransactionID) = itemID else {
                fatalError()
            }

            Task { await timelineController.toggleReaction(emoji, to: eventOrTransactionID) }
        case .sendReadReceiptIfNeeded(let lastVisibleItemID):
            Task { await sendReadReceiptIfNeeded(for: lastVisibleItemID) }
        case .paginateBackwards:
            paginateBackwards()
        case .paginateForwards:
            paginateForwards()
        case .scrollToBottom:
            scrollToBottom()
        case .scrollToFirstItemForCurrentDate:
            state.timelineState.scrollToFirstItemForDatePublisher.send()
        case .displayTimelineItemMenu(let itemID):
            guard let timelineItem = timelineItem(withExactIdentifier: itemID) as? EventBasedTimelineItemProtocol else { return }
            timelineInteractionHandler.displayTimelineItemActionMenu(for: timelineItem)
        case .handleTimelineItemMenuAction(let itemID, let action):
            guard timelineItem(withExactIdentifier: itemID) != nil else { return }
            if action == .selectMessages {
                startMessageSelection(itemID: itemID)
            } else {
                timelineInteractionHandler.handleTimelineItemMenuAction(action, itemID: itemID)
            }
        case .toggleMessageSelection(let itemID):
            toggleMessageSelection(itemID: itemID)
        case .cancelMessageSelection:
            cancelMessageForwardingPreparation()
            setMessageSelectionState(.init())
        case .confirmMessageRedaction:
            confirmMessageRedaction()
        case .forwardMessageSelection:
            forwardMessageSelection()
        case .tappedOnSenderDetails(let sender):
            handleTappedOnSenderDetails(sender: sender)
        case .displayEmojiPicker(let itemID):
            timelineInteractionHandler.displayEmojiPicker(for: itemID)
        case .displayReactionSummary(let itemID, let key):
            displayReactionSummary(for: itemID, selectedKey: key)
        case .displayReadReceipts(let itemID):
            displayReadReceipts(for: itemID)
        case .displayThread(let itemID):
            actionsSubject.send(.displayThread(itemID: itemID))
        case .handlePasteOrDrop(let providers):
            timelineInteractionHandler.handlePasteOrDrop(providers)
        case .handlePollAction(let pollAction):
            handlePollAction(pollAction)
        case .handleAudioPlayerAction(let audioPlayerAction):
            handleAudioPlayerAction(audioPlayerAction)
        case .stopLiveLocationSharing(let id):
            state.stoppedLiveLocationIDs.insert(id)
            Task { await stopLiveLocationSharing() }
        case .focusOnEventID(let eventID):
            Task { await focusOnEvent(eventID: eventID) }
        case .focusLive:
            focusLive()
        case .scrolledToFocussedItem:
            didScrollToFocussedItem()
        case .hasSwitchedTimeline:
            Task { state.timelineState.isSwitchingTimelines = false }
        case let .hasScrolled(direction):
            actionsSubject.send(.hasScrolled(direction: direction))
        case .displayPredecessorRoom:
            guard let predecessorID = roomProxy.predecessorRoom?.roomId else {
                fatalError("Predecessor room should exist if this action is triggered.")
            }
            let serverNames = roomProxy.knownServerNames(maxCount: 50) // Limit to the same number used by ClientProxy.resolveRoomAlias(_:)
            actionsSubject.send(.displayRoom(roomID: predecessorID, via: Array(serverNames)))
        }
    }

    func process(composerAction: ComposerToolbarViewModelAction) {
        switch composerAction {
        case .sendMessage(let message, let html, let mode, let intentionalMentions):
            startSendingCurrentMessage(message,
                                       html: html,
                                       mode: mode,
                                       intentionalMentions: intentionalMentions)
        case .editLastMessage:
            editLastMessage()
        case .attach(let attachment):
            attach(attachment)
        case .handlePasteOrDrop(let providers):
            timelineInteractionHandler.handlePasteOrDrop(providers)
        case .composerModeChanged(mode: let mode):
            trackComposerMode(mode)
        case .composerFocusedChanged(isFocused: let isFocused):
            composerFocusedSubject.send(isFocused)
        case .voiceMessage(let voiceMessageAction):
            processVoiceMessageAction(voiceMessageAction)
        case .contentChanged(let isEmpty):
            guard appSettings.sharePresence else {
                return
            }

            Task {
                await roomProxy.sendTypingNotification(isTyping: !isEmpty)
            }
        }
    }

    func focusOnEvent(eventID: String) async {
        guard let providerMutationToken = timelineController.providerMutationToken() else {
            cancelMessageForwardingPreparation()
            return
        }

        if state.timelineState.hasLoadedItem(with: eventID) {
            state.timelineState.focussedEvent = .init(eventID: eventID, appearance: .animated)
            return
        }

        showFocusLoadingIndicator()
        defer {
            hideFocusLoadingIndicator()
        }

        switch await timelineController.focusOnEvent(eventID,
                                                     timelineSize: Constants.detachedTimelineSize,
                                                     using: providerMutationToken) {
        case .success:
            state.timelineState.focussedEvent = .init(eventID: eventID, appearance: .immediate)
        case .failure(let error):
            guard case .providerMutationInvalidated = error else {
                MXLog.error("Failed to focus on event \(eventID)")

                if case .eventNotFound = error {
                    displayErrorToast(L10n.errorMessageNotFound)
                } else {
                    displayErrorToast(L10n.commonFailed)
                }
                return
            }
        }
    }

    func stopLiveLocationSharing() async {
        await userSession.liveLocationManager.stopLiveLocation(roomID: roomProxy.id)
    }

    func makeForwardingItem(for itemID: TimelineItemIdentifier,
                            requestID: UUID,
                            preparationOwnerID: UUID) async -> MessageForwardingItem? {
        await forwardingItemPreparer.makeForwardingItem(for: itemID,
                                                        requestID: requestID,
                                                        preparationOwnerID: preparationOwnerID,
                                                        providerGeneration: renderedProviderGeneration,
                                                        timelineItemsGeneration: renderedTimelineItemsGeneration,
                                                        canCurrentUserRedactSelf: state.canCurrentUserRedactSelf,
                                                        canCurrentUserRedactOthers: state.canCurrentUserRedactOthers)
    }

    func cancelForwardingItemPreparation(preparationOwnerID: UUID) {
        forwardingItemPreparer.cancel(preparationOwnerID: preparationOwnerID)
    }

    // MARK: - Private

    private func handleTappedOnSenderDetails(sender: TimelineItemSender) {
        let memberDetails: ManageRoomMemberDetails = if let memberProxy = roomProxy.membersPublisher.value.first(where: { $0.userID == sender.id }) {
            .memberDetails(roomMember: .init(withProxy: memberProxy))
        } else {
            .loadingMemberDetails(sender: sender)
        }

        let viewModel = ManageRoomMemberSheetViewModel(memberDetails: memberDetails,
                                                       permissions: .init(canKick: state.canCurrentUserKick,
                                                                          canBan: state.canCurrentUserBan,
                                                                          ownPowerLevel: currentUserProxy?.powerLevel ?? .init(value: 0)),
                                                       roomProxy: roomProxy,
                                                       userIndicatorController: userIndicatorController,
                                                       analyticsService: analyticsService,
                                                       mediaProvider: userSession.mediaProvider)

        viewModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss(let shouldShowDetails):
                state.bindings.manageMemberViewModel = nil
                if shouldShowDetails {
                    actionsSubject.send(.displaySenderDetails(userID: sender.id))
                }
            }
        }
        .store(in: &cancellables)
        state.bindings.manageMemberViewModel = viewModel
    }

    private func focusLive() {
        guard let providerMutationToken = timelineController.providerMutationToken() else {
            cancelMessageForwardingPreparation()
            return
        }
        focusLive(using: providerMutationToken)
    }

    private func focusLive(using providerMutationToken: TimelineProviderMutationToken) {
        timelineController.focusLive(using: providerMutationToken)
    }

    private func didScrollToFocussedItem() {
        if var focussedEvent = state.timelineState.focussedEvent {
            focussedEvent.appearance = .hasAppeared
            state.timelineState.focussedEvent = focussedEvent
            hideFocusLoadingIndicator()
            analyticsService.signpost.finishTransaction(.notificationToMessage)
        }
    }

    private func editLastMessage() {
        guard let item = timelineController.timelineItems.reversed().first(where: {
            guard let item = $0 as? EventBasedMessageTimelineItemProtocol else {
                return false
            }

            return item.sender.id == roomProxy.ownUserID && item.isEditable
        }) else {
            return
        }

        timelineInteractionHandler.handleTimelineItemMenuAction(.edit, itemID: item.id)
    }

    private func attach(_ attachment: ComposerAttachmentType) {
        switch attachment {
        case .camera:
            actionsSubject.send(.displayCameraPicker)
        case .photoLibrary:
            actionsSubject.send(.displayMediaPicker)
        case .file:
            actionsSubject.send(.displayDocumentPicker)
        case .emoji:
            break
        case .location:
            actionsSubject.send(.displayLocationPicker)
        case .poll:
            actionsSubject.send(.displayPollForm(mode: .new))
        }
    }

    private func handlePollAction(_ action: TimelineViewPollAction) {
        switch action {
        case let .selectOption(pollStartID, optionID):
            timelineInteractionHandler.sendPollResponse(pollStartID: pollStartID, optionID: optionID)
        case let .end(pollStartID):
            displayAlert(.pollEndConfirmation(pollStartID))
        case .edit(let pollStartID, let poll):
            actionsSubject.send(.displayPollForm(mode: .edit(eventID: pollStartID, poll: poll)))
        }
    }

    private func handleAudioPlayerAction(_ action: TimelineAudioPlayerAction) {
        switch action {
        case .playPause(let itemID):
            Task { await timelineInteractionHandler.playPauseAudio(for: itemID) }
        case .seek(let itemID, let progress):
            Task { await timelineInteractionHandler.seekAudio(for: itemID, progress: progress) }
        case .changePlaybackSpeed(let itemID):
            timelineInteractionHandler.changePlaybackSpeed(for: itemID)
        }
    }

    private func processVoiceMessageAction(_ action: ComposerToolbarVoiceMessageAction) {
        switch action {
        case .startRecording:
            Task {
                await mediaPlayerProvider.detachAllStates(except: nil)
                await timelineInteractionHandler.startRecordingVoiceMessage()
            }
        case .stopRecording:
            Task { await timelineInteractionHandler.stopRecordingVoiceMessage() }
        case .cancelRecording:
            Task { await timelineInteractionHandler.cancelRecordingVoiceMessage() }
        case .deleteRecording:
            Task { await timelineInteractionHandler.deleteCurrentVoiceMessage() }
        case .send:
            Task { await timelineInteractionHandler.sendCurrentVoiceMessage() }
        case .startPlayback:
            Task { await timelineInteractionHandler.startPlayingRecordedVoiceMessage() }
        case .pausePlayback:
            timelineInteractionHandler.pausePlayingRecordedVoiceMessage()
        case .seekPlayback(let progress):
            Task { await timelineInteractionHandler.seekRecordedVoiceMessage(to: progress) }
        case .scrubPlayback(let scrubbing):
            Task { await timelineInteractionHandler.scrubVoiceMessagePlayback(scrubbing: scrubbing) }
        }
    }

    private func updateMembers(_ members: [RoomMemberProxyProtocol]) {
        state.members = members.reduce(into: [String: RoomMemberState]()) { dictionary, member in
            dictionary[member.userID] = RoomMemberState(displayName: member.displayName, avatarURL: member.avatarURL)
            if member.userID == roomProxy.ownUserID {
                currentUserProxy = member
            }
        }
    }

    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        state.pinnedEventIDs = roomInfo.pinnedEventIDs

        if let powerLevels = roomInfo.powerLevels {
            state.canCurrentUserSendMessage = powerLevels.canOwnUser(sendMessage: .roomMessage)
            state.canCurrentUserRedactOthers = powerLevels.canOwnUserRedactOther()
            state.canCurrentUserRedactSelf = powerLevels.canOwnUserRedactOwn()
            state.canCurrentUserPin = powerLevels.canOwnUserPinOrUnpin()
            state.canCurrentUserKick = powerLevels.canOwnUserKick()
            state.canCurrentUserBan = powerLevels.canOwnUserBan()
        }
    }

    private func setupSubscriptions() {
        timelineController.callbacks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] callback in
                guard let self else { return }

                switch callback {
                case .updatedTimelineItems(let updatedItems, let isSwitchingTimelines, let providerGeneration, let timelineItemsGeneration):
                    handleUpdatedTimelineItems(updatedItems,
                                               isSwitchingTimelines: isSwitchingTimelines,
                                               providerGeneration: providerGeneration,
                                               timelineItemsGeneration: timelineItemsGeneration)
                case .paginationState(let paginationState):
                    if state.timelineState.paginationState != paginationState {
                        state.timelineState.paginationState = paginationState
                    }
                case .isLive(let isLive):
                    if state.timelineState.isLive != isLive {
                        state.timelineState.isLive = isLive
                    }

                    if isLive, state.timelineState.focussedEvent != nil {
                        state.timelineState.focussedEvent = nil
                        hideFocusLoadingIndicator()
                    }
                }
            }
            .store(in: &cancellables)

        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)

        setupAppSettingsSubscriptions()

        roomProxy.membersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateMembers($0) }
            .store(in: &cancellables)

        roomProxy.typingMembersPublisher
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _ in self?.appSettings.sharePresence ?? false }
            .weakAssign(to: \.state.typingMembers, on: self)
            .store(in: &cancellables)

        timelineInteractionHandler.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .composer(let action):
                    actionsSubject.send(.composer(action: action))
                case .displayAudioRecorderPermissionError:
                    displayAlert(.audioRecodingPermissionError)
                case .displayErrorToast(let title):
                    displayErrorToast(title)
                case .displayEmojiPicker(let itemID, let selectedEmojis):
                    actionsSubject.send(.displayEmojiPicker(itemID: itemID, selectedEmojis: selectedEmojis))
                case .displayMessageForwarding(let itemID):
                    forwardMessage(itemID: itemID)
                case .displayPollForm(let mode):
                    actionsSubject.send(.displayPollForm(mode: mode))
                case .displayReportContent(let itemID, let senderID):
                    actionsSubject.send(.displayReportContent(itemID: itemID, senderID: senderID))
                case .displayMediaUploadPreviewScreen(let mediaURLs):
                    actionsSubject.send(.displayMediaUploadPreviewScreen(mediaURLs: mediaURLs))
                case .showActionMenu(let actionMenuInfo):
                    if case .media(.mediaFilesScreen) = timelineController.timelineKind,
                       let item = actionMenuInfo.item as? EventBasedMessageTimelineItemProtocol {
                        actionsSubject.send(.displayMediaDetails(item: item))
                    } else {
                        self.state.bindings.actionMenuInfo = actionMenuInfo
                    }
                case .showDebugInfo(let debugInfo):
                    state.bindings.debugInfo = debugInfo
                case .viewInRoomTimeline(let eventID):
                    Task { await self.viewInRoomTimeline(eventID: eventID) }
                case .displayThread(let itemID):
                    actionsSubject.send(.displayThread(itemID: itemID))
                case .showTranslation(let text):
                    self.state.bindings.textToBeTranslated = text
                    self.state.bindings.showTranslation = true
                }
            }
            .store(in: &cancellables)
    }

    private func handleUpdatedTimelineItems(_ updatedItems: [RoomTimelineItemProtocol],
                                            isSwitchingTimelines: Bool,
                                            providerGeneration: UInt,
                                            timelineItemsGeneration: UInt) {
        guard providerGeneration == timelineController.activeProviderGeneration,
              timelineItemsGeneration == timelineController.timelineItemsGeneration,
              !timelineController.isTimelineItemsBuildInProgress else { return }
        if providerGeneration != renderedProviderGeneration ||
            timelineItemsGeneration != renderedTimelineItemsGeneration {
            cancelMediaTap()
        }
        cancelDirectMessageForwardingPreparation(releasingProviderLease: true)
        if prepareMessageForwardingTask != nil {
            cancelMessageForwardingPreparation()
        }
        if providerGeneration == renderedProviderGeneration {
            renderedTimelineItemsGeneration = timelineItemsGeneration
            refreshMessageSelectionProviderLeaseIfNeeded()
            reconcileMessageSelection(with: updatedItems)
        } else {
            setMessageSelectionState(.init())
            renderedProviderGeneration = providerGeneration
            renderedTimelineItemsGeneration = timelineItemsGeneration
        }
        buildTimelineViews(timelineItems: updatedItems, isSwitchingTimelines: isSwitchingTimelines)

        if !updatedItems.isEmpty {
            analyticsService.signpost.finishTransaction(.openRoom)
        }
    }

    func viewInRoomTimeline(eventID: String) async {
        switch await roomProxy.loadOrFetchEventDetails(for: eventID) {
        case .success(let event):
            let threadRootEventID: String? = if appSettings.threadsEnabled {
                event.threadRootEventId()
            } else {
                nil
            }
            actionsSubject.send(.viewInRoomTimeline(eventID: eventID, threadRootEventID: threadRootEventID))
        case .failure:
            userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        }
    }

    private func setupAppSettingsSubscriptions() {
        appSettings.$sharePresence
            .weakAssign(to: \.state.showReadReceipts, on: self)
            .store(in: &cancellables)

        appSettings.$viewSourceEnabled
            .weakAssign(to: \.state.isViewSourceEnabled, on: self)
            .store(in: &cancellables)

        appSettings.$threadsEnabled
            .weakAssign(to: \.state.areThreadsEnabled, on: self)
            .store(in: &cancellables)

        appSettings.$junchatEmergencyPrivacyModeEnabled
            .weakAssign(to: \.state.isEmergencyPrivacyModeEnabled, on: self)
            .store(in: &cancellables)

        userSession.clientProxy.timelineMediaVisibilityPublisher
            .removeDuplicates()
            .flatMap { [weak self] timelineMediaVisibility -> AnyPublisher<Bool, Never> in
                switch timelineMediaVisibility {
                case .always:
                    return Just(false).eraseToAnyPublisher()
                case .never:
                    return Just(true).eraseToAnyPublisher()
                case .privateOnly:
                    guard let self else { return Just(false).eraseToAnyPublisher() }
                    return roomProxy.infoPublisher
                        .map { !($0.isPrivate ?? false) }
                        .removeDuplicates()
                        .eraseToAnyPublisher()
                }
            }
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.hideTimelineMedia, on: self)
            .store(in: &cancellables)
    }

    private func setupDirectRoomSubscriptionsIfNeeded() {
        guard roomProxy.infoPublisher.value.isDirect else {
            return
        }

        let shouldShowInviteAlert = composerFocusedSubject
            .removeDuplicates()
            .map { [weak self] isFocused in
                guard let self else { return false }

                return isFocused && self.roomProxy.infoPublisher.value.isUserAloneInDirectRoom
            }
            // We want to show the alert just once, so we are taking the first "true" emitted
            .first { $0 }

        shouldShowInviteAlert
            .sink { [weak self] _ in
                self?.displayAlert(.inviteAgain)
            }
            .store(in: &cancellables)
    }

    private func paginateBackwards() {
        guard paginateBackwardsTask == nil else {
            return
        }

        paginateBackwardsTask = Task { [weak self] in
            guard let self else {
                return
            }

            switch await timelineController.paginateBackwards(requestSize: Constants.paginationEventLimit) {
            case .failure:
                displayErrorToast(L10n.errorFailedLoadingMessages)
            default:
                break
            }
            paginateBackwardsTask = nil
        }
    }

    private func paginateForwards() {
        guard paginateForwardsTask == nil,
              let providerMutationToken = timelineController.providerMutationToken() else {
            return
        }

        paginateForwardsTask = Task { [weak self] in
            guard let self else {
                return
            }

            switch await timelineController.paginateForwards(requestSize: Constants.paginationEventLimit) {
            case .failure:
                displayErrorToast(L10n.errorFailedLoadingMessages)
            default:
                break
            }

            if state.timelineState.paginationState.forward == .endReached {
                focusLive(using: providerMutationToken)
            }

            paginateForwardsTask = nil
        }
    }

    private func scrollToBottom() {
        guard let providerMutationToken = timelineController.providerMutationToken() else {
            cancelMessageForwardingPreparation()
            return
        }
        scrollToBottom(using: providerMutationToken)
    }

    private func scrollToBottom(using providerMutationToken: TimelineProviderMutationToken) {
        if state.timelineState.isLive {
            guard timelineController.isProviderMutationTokenValid(providerMutationToken) else { return }
            state.timelineState.scrollToBottomPublisher.send(())
        } else {
            focusLive(using: providerMutationToken)
        }
    }

    private func startMessageSelection(itemID: TimelineItemIdentifier) {
        guard let capabilities = selectableMessageSelectionCapabilities(itemID: itemID) else {
            return
        }
        cancelDirectMessageForwardingPreparation(releasingProviderLease: true)
        cancelMessageForwardingPreparation()
        var selectionState = TimelineMessageSelectionState()
        selectionState.insert(capabilities)
        setMessageSelectionState(selectionState)
    }

    private func toggleMessageSelection(itemID: TimelineItemIdentifier) {
        guard let capabilities = selectableMessageSelectionCapabilities(itemID: itemID),
              state.messageSelectionState.isActive else {
            return
        }

        cancelMessageForwardingPreparation()
        var selectionState = state.messageSelectionState
        if selectionState.selectedIDs.contains(capabilities.id) {
            selectionState.remove(capabilities.id)
        } else {
            selectionState.insert(capabilities)
        }
        setMessageSelectionState(selectionState)
    }

    private func setMessageSelectionState(_ selectionState: TimelineMessageSelectionState) {
        let wasActive = state.messageSelectionState.isActive
        if !wasActive, selectionState.isActive {
            guard let providerLease = timelineController.acquireProviderLease() else { return }
            messageSelectionProviderLease = providerLease
        }
        state.messageSelectionState = selectionState
        if wasActive, !selectionState.isActive {
            if let messageSelectionProviderLease {
                timelineController.releaseProviderLease(messageSelectionProviderLease)
                self.messageSelectionProviderLease = nil
            }
        }
    }

    private func refreshMessageSelectionProviderLeaseIfNeeded() {
        guard state.messageSelectionState.isActive else { return }
        if let messageSelectionProviderLease {
            timelineController.releaseProviderLease(messageSelectionProviderLease)
            self.messageSelectionProviderLease = nil
        }
        guard let providerLease = timelineController.acquireProviderLease() else {
            state.messageSelectionState = .init()
            return
        }
        messageSelectionProviderLease = providerLease
    }

    private func confirmMessageRedaction() {
        let selectionState = state.messageSelectionState
        guard selectionState.canRedactSelectedMessages else {
            return
        }
        cancelMessageForwardingPreparation()
        let selectedIDs = selectionState.selectedIDs.intersection(selectionState.redactionIDs)
        guard let providerLease = messageSelectionProviderLease else { return }
        messageSelectionProviderLease = nil
        setMessageSelectionState(.init())

        let timelineController = timelineController
        redactMessagesTask = Task { [weak self] in
            defer { timelineController.releaseProviderLease(providerLease) }
            let result = await timelineController.redact(Array(selectedIDs), using: providerLease)
            guard !Task.isCancelled, let self else { return }
            redactMessagesTask = nil
            if case .failure = result {
                displayErrorToast(L10n.commonFailed)
            }
        }
    }

    private func forwardMessageSelection() {
        cancelMessageForwardingPreparation()

        let selectionState = state.messageSelectionState
        guard selectionState.canForwardSelectedMessages else {
            return
        }
        let selectedIDs = selectionState.selectedIDs
        guard let providerLease = messageSelectionProviderLease else { return }
        let generation = messageForwardingPreparationGeneration
        let roomID = roomProxy.id
        let timelineController = timelineController

        prepareMessageForwardingTask = Task { [weak self] in
            let forwardingItems = await Self.selectedForwardingItems(selectedIDs: selectedIDs,
                                                                     roomID: roomID,
                                                                     timelineController: timelineController,
                                                                     providerLease: providerLease)
            guard !Task.isCancelled,
                  let self,
                  messageForwardingPreparationGeneration == generation else {
                return
            }
            prepareMessageForwardingTask = nil

            guard let forwardingItems,
                  let firstItem = forwardingItems.first else {
                displayErrorToast(UntranslatedL10n.screenRoomMessageSelectionChangedError)
                return
            }

            guard let forwardingBatch = MessageForwardingBatch(firstItem: firstItem,
                                                               remainingItems: Array(forwardingItems.dropFirst())) else {
                displayErrorToast(UntranslatedL10n.screenRoomMessageSelectionChangedError)
                return
            }
            setMessageSelectionState(.init())
            actionsSubject.send(.displayMessageForwarding(forwardingBatch: forwardingBatch))
        }
    }

    private func cancelMessageForwardingPreparation() {
        prepareMessageForwardingTask?.cancel()
        prepareMessageForwardingTask = nil
        messageForwardingPreparationGeneration &+= 1
    }

    private static func selectedForwardingItems(selectedIDs: Set<TimelineItemIdentifier.EventOrTransactionID>,
                                                roomID: String,
                                                timelineController: TimelineControllerProtocol,
                                                providerLease: TimelineProviderLease) async -> [MessageForwardingItem]? {
        guard timelineController.isProviderLeaseValid(providerLease) else { return nil }
        var forwardingItems = [MessageForwardingItem]()
        var sourceItemTypes = [TimelineItemIdentifier.EventOrTransactionID: RoomTimelineItemType]()
        var remainingIDs = selectedIDs

        for timelineItem in timelineController.timelineItems {
            guard !Task.isCancelled else { return nil }

            guard let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol,
                  let eventOrTransactionID = eventTimelineItem.id.eventOrTransactionID,
                  remainingIDs.remove(eventOrTransactionID) != nil else {
                continue
            }

            guard eventTimelineItem.isForwardable else { return nil }
            let sourceItemType = RoomTimelineItemType(item: eventTimelineItem)
            guard let forwardingItem = await makeForwardingItem(for: eventTimelineItem.id,
                                                                roomID: roomID,
                                                                timelineController: timelineController,
                                                                providerLease: providerLease),
                !Task.isCancelled,
                timelineController.isProviderLeaseValid(providerLease) else {
                return nil
            }

            sourceItemTypes[eventOrTransactionID] = sourceItemType
            forwardingItems.append(forwardingItem)
        }

        await waitForEnqueuedTimelineUpdates()
        guard !Task.isCancelled,
              timelineController.isProviderLeaseValid(providerLease) else { return nil }

        guard remainingIDs.isEmpty,
              forwardingItems.count == selectedIDs.count,
              sourceItemTypes.count == selectedIDs.count,
              selectionMatchesCurrentTimeline(sourceItemTypes: sourceItemTypes,
                                              selectedIDs: selectedIDs,
                                              timelineItems: timelineController.timelineItems) else {
            return nil
        }

        return forwardingItems
    }

    private static func selectionMatchesCurrentTimeline(sourceItemTypes: [TimelineItemIdentifier.EventOrTransactionID: RoomTimelineItemType],
                                                        selectedIDs: Set<TimelineItemIdentifier.EventOrTransactionID>,
                                                        timelineItems: [RoomTimelineItemProtocol]) -> Bool {
        var currentItems = [TimelineItemIdentifier.EventOrTransactionID: EventBasedTimelineItemProtocol]()
        for case let currentItem as EventBasedTimelineItemProtocol in timelineItems {
            guard let currentID = currentItem.id.eventOrTransactionID,
                  selectedIDs.contains(currentID) else { continue }
            guard currentItems.updateValue(currentItem, forKey: currentID) == nil else { return false }
        }

        return sourceItemTypes.allSatisfy { sourceID, sourceItemType in
            guard let currentItem = currentItems[sourceID] else { return false }
            return currentItem.isForwardable && RoomTimelineItemType(item: currentItem) == sourceItemType
        }
    }

    private static func waitForEnqueuedTimelineUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private static func makeForwardingItem(for itemID: TimelineItemIdentifier,
                                           roomID: String,
                                           timelineController: TimelineControllerProtocol,
                                           providerLease: TimelineProviderLease) async -> MessageForwardingItem? {
        guard let content = await timelineController.messageEventContent(for: itemID, using: providerLease) else { return nil }
        return .init(id: itemID, roomID: roomID, content: content)
    }

    private func selectableMessageSelectionCapabilities(itemID: TimelineItemIdentifier) -> TimelineMessageSelectionCapabilities? {
        guard let eventTimelineItem = timelineItem(withExactIdentifier: itemID) as? EventBasedTimelineItemProtocol else {
            return nil
        }

        return TimelineMessageSelectionEligibility.capabilities(for: eventTimelineItem,
                                                                canCurrentUserRedactSelf: state.canCurrentUserRedactSelf,
                                                                canCurrentUserRedactOthers: state.canCurrentUserRedactOthers)
    }

    private func timelineItem(withExactIdentifier itemID: TimelineItemIdentifier) -> RoomTimelineItemProtocol? {
        guard renderedProviderGeneration == timelineController.timelineItemsProviderGeneration,
              renderedProviderGeneration == timelineController.activeProviderGeneration,
              renderedTimelineItemsGeneration == timelineController.timelineItemsGeneration,
              !timelineController.isTimelineItemsBuildInProgress,
              let timelineItem = timelineController.timelineItems.firstUsingStableID(itemID),
              timelineItem.id == itemID else {
            return nil
        }
        return timelineItem
    }

    private func forwardableTimelineItem(withExactIdentifier itemID: TimelineItemIdentifier) -> EventBasedTimelineItemProtocol? {
        guard let eventTimelineItem = timelineItem(withExactIdentifier: itemID) as? EventBasedTimelineItemProtocol,
              TimelineMessageSelectionEligibility.capabilities(for: eventTimelineItem,
                                                               canCurrentUserRedactSelf: state.canCurrentUserRedactSelf,
                                                               canCurrentUserRedactOthers: state.canCurrentUserRedactOthers)?.canForward == true else {
            return nil
        }
        return eventTimelineItem
    }

    private func reconcileMessageSelection(with timelineItems: [RoomTimelineItemProtocol]) {
        guard state.messageSelectionState.isActive else { return }

        var selectionState = state.messageSelectionState
        for timelineItem in timelineItems {
            guard let previousItem = state.timelineState.itemsDictionary[timelineItem.id.uniqueID],
                  let previousID = previousItem.identifier.eventOrTransactionID,
                  selectionState.isSelected(previousID) else {
                continue
            }

            guard let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol,
                  let capabilities = TimelineMessageSelectionEligibility.capabilities(for: eventTimelineItem,
                                                                                      canCurrentUserRedactSelf: state.canCurrentUserRedactSelf,
                                                                                      canCurrentUserRedactOthers: state.canCurrentUserRedactOthers) else {
                selectionState.remove(previousID)
                continue
            }

            selectionState.replace(previousID, with: capabilities)
        }
        setMessageSelectionState(selectionState)
    }

    private func sendReadReceiptIfNeeded(for lastVisibleItemID: TimelineItemIdentifier) async {
        guard appMediator.appState == .active else { return }

        await timelineController.sendReadReceipt(for: lastVisibleItemID)
    }

    private func handleMediaTapped(with itemID: TimelineItemIdentifier) {
        cancelMediaTap()
        guard let timelineItem = timelineItem(withExactIdentifier: itemID) as? EventBasedTimelineItemProtocol else { return }

        let requestID = UUID()
        let providerGeneration = renderedProviderGeneration
        let timelineItemsGeneration = renderedTimelineItemsGeneration
        mediaTapRequestID = requestID
        state.showLoading = true
        mediaTapTask = Task { [weak self] in
            guard let self else { return }
            let action = await timelineInteractionHandler.processItemTap(timelineItem)
            guard !Task.isCancelled else { return }
            handleMediaTapAction(action,
                                 itemID: itemID,
                                 requestID: requestID,
                                 providerGeneration: providerGeneration,
                                 timelineItemsGeneration: timelineItemsGeneration)
        }
    }

    private func handleMediaTapAction(_ action: TimelineControllerAction,
                                      itemID: TimelineItemIdentifier,
                                      requestID: UUID,
                                      providerGeneration: UInt,
                                      timelineItemsGeneration: UInt) {
        guard mediaTapRequestID == requestID,
              renderedProviderGeneration == providerGeneration,
              renderedTimelineItemsGeneration == timelineItemsGeneration,
              timelineItem(withExactIdentifier: itemID)?.id == itemID else {
            finishMediaTap(requestID: requestID)
            return
        }

        finishMediaTap(requestID: requestID)

        switch action {
        case .displayMediaPreview(let item, let timelineViewModelKind):
            actionsSubject.send(.composer(action: .removeFocus)) // Hide the keyboard otherwise a big white space is sometimes shown when dismissing the preview.

            let mediaPreviewViewModel = makeMediaPreviewViewModel(item: item, timelineViewModelKind: timelineViewModelKind)
            actionsSubject.send(.displayMediaPreview(mediaPreviewViewModel))
        case .displayLocation(let location):
            actionsSubject.send(.displayLocation(location))
        case .displayLiveLocation(let sender, let initialLiveLocationShare):
            actionsSubject.send(.displayLiveLocation(sender: sender, initialLiveLocationShare: initialLiveLocationShare))
        case .none:
            break
        }
    }

    private func cancelMediaTap() {
        mediaTapRequestID = nil
        mediaTapTask?.cancel()
        mediaTapTask = nil
        state.showLoading = false
    }

    private func finishMediaTap(requestID: UUID) {
        guard mediaTapRequestID == requestID else { return }
        mediaTapRequestID = nil
        mediaTapTask = nil
        state.showLoading = false
    }

    private func handleItemSendInfoTapped(itemID: TimelineItemIdentifier) {
        guard let timelineItem = timelineController.timelineItems.firstUsingStableID(itemID) else {
            MXLog.warning("Couldn't find timeline item.")
            return
        }

        guard let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol else {
            fatalError("Only events can have send info.")
        }

        if case .sendingFailed(.unknown) = eventTimelineItem.properties.deliveryStatus {
            displayAlert(.sendingFailed)
        } else if case let .sendingFailed(.verifiedUser(failure)) = eventTimelineItem.properties.deliveryStatus {
            guard let sendHandle = timelineController.sendHandle(for: itemID) else {
                MXLog.error("Cannot find send handle for \(itemID).")
                return
            }

            actionsSubject.send(.displayResolveSendFailure(failure: failure,
                                                           sendHandle: sendHandle))

        } else if let forwarderMessage = eventTimelineItem.properties.encryptionForwarder?.message {
            displayAlert(.encryptionForwarder(forwarderMessage))
        } else if let authenticityMessage = eventTimelineItem.properties.encryptionAuthenticity?.message {
            displayAlert(.encryptionAuthenticity(authenticityMessage))
        }
    }

    private func slashCommand(message: String) -> SlashCommand? {
        for command in SlashCommand.allCases where message.starts(with: command.rawValue) {
            return command
        }
        return nil
    }

    private static func handleJoinCommand(message: String,
                                          clientProxy: ClientProxyProtocol,
                                          actionsSubject: PassthroughSubject<TimelineViewModelAction, Never>) async {
        guard let alias = String(message.dropFirst(SlashCommand.join.rawValue.count))
            .components(separatedBy: .whitespacesAndNewlines)
            .first,
            case let .success(resolvedAlias) = await clientProxy.resolveRoomAlias(alias),
            !Task.isCancelled else {
            return
        }

        actionsSubject.send(.displayRoom(roomID: resolvedAlias.roomId, via: resolvedAlias.servers))
    }

    private func startSendingCurrentMessage(_ message: String, html: String?, mode: ComposerMode, intentionalMentions: IntentionalMentions) {
        guard !message.isEmpty else {
            fatalError("This message should never be empty")
        }

        actionsSubject.send(.composer(action: .clear))

        let command = slashCommand(message: message)
        let requiresPrivacyModeAuthority = switch mode {
        case .reply:
            true
        case .default:
            command == nil
        case .edit, .recordVoiceMessage, .previewVoiceMessage:
            false
        }

        let taskID = UUID()
        let emergencyPrivacyModeEnabled = appSettings.junchatEmergencyPrivacyModeEnabled
        let privacyModeService = userSession.privacyModeService
        let clientProxy = userSession.clientProxy
        let roomID = timelineController.roomID
        let authorityTimeout = privacyModeAuthorityTimeout
        let timelineController = timelineController
        let providerMutationToken = timelineController.providerMutationToken(ensuringProviderIsConfigured: true)
        let actionsSubject = actionsSubject

        sendMessageTasks[taskID] = Task { [weak self] in
            if requiresPrivacyModeAuthority {
                guard await Self.resolvePrivacyModeEnabled(emergencyPrivacyModeEnabled: emergencyPrivacyModeEnabled,
                                                           privacyModeService: privacyModeService,
                                                           roomID: roomID,
                                                           authorityTimeout: authorityTimeout) != nil else {
                    self?.sendMessageTasks[taskID] = nil
                    return
                }
            }

            guard !Task.isCancelled else {
                self?.sendMessageTasks[taskID] = nil
                return
            }

            await Self.sendCurrentMessage(message,
                                          html: html,
                                          mode: mode,
                                          intentionalMentions: intentionalMentions,
                                          command: command,
                                          timelineController: timelineController,
                                          clientProxy: clientProxy,
                                          actionsSubject: actionsSubject)
            if !Task.isCancelled, let providerMutationToken {
                self?.scrollToBottom(using: providerMutationToken)
            }
            self?.sendMessageTasks[taskID] = nil
        }
    }

    private static func sendCurrentMessage(_ message: String,
                                           html: String?,
                                           mode: ComposerMode,
                                           intentionalMentions: IntentionalMentions,
                                           command: SlashCommand?,
                                           timelineController: TimelineControllerProtocol,
                                           clientProxy: ClientProxyProtocol,
                                           actionsSubject: PassthroughSubject<TimelineViewModelAction, Never>) async {
        guard !Task.isCancelled else { return }

        switch mode {
        case .reply(let eventID, _, _):
            await timelineController.sendMessage(message,
                                                 html: html,
                                                 inReplyToEventID: eventID,
                                                 intentionalMentions: intentionalMentions)
        case .edit(let originalEventOrTransactionID, .default):
            await timelineController.edit(originalEventOrTransactionID,
                                          message: message,
                                          html: html,
                                          intentionalMentions: intentionalMentions)
        case .edit(let originalEventOrTransactionID, .addCaption),
             .edit(let originalEventOrTransactionID, .editCaption):
            await timelineController.editCaption(originalEventOrTransactionID,
                                                 message: message,
                                                 html: html,
                                                 intentionalMentions: intentionalMentions)
        case .default:
            switch command {
            case .join:
                await handleJoinCommand(message: message, clientProxy: clientProxy, actionsSubject: actionsSubject)
            case .none:
                await timelineController.sendMessage(message,
                                                     html: html,
                                                     inReplyToEventID: nil,
                                                     intentionalMentions: intentionalMentions)
            }
        case .recordVoiceMessage, .previewVoiceMessage:
            fatalError("invalid composer mode.")
        }
    }

    private static func resolvePrivacyModeEnabled(emergencyPrivacyModeEnabled: Bool,
                                                  privacyModeService: PrivacyModeServiceProtocol,
                                                  roomID: String,
                                                  authorityTimeout: Duration) async -> Bool? {
        if let cachedValue = await privacyModeService.cachedValue(roomID: roomID) {
            return Task.isCancelled ? nil : emergencyPrivacyModeEnabled || cachedValue
        }

        guard !Task.isCancelled else {
            return nil
        }

        do {
            // Exiting the group waits for the cancelled load, preventing migration writes after send begins.
            let enabled = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let result = await privacyModeService.load(roomID: roomID)
                    try Task.checkCancellation()

                    switch result {
                    case .success(let enabled):
                        return enabled
                    case .failure:
                        return await privacyModeService.cachedValue(roomID: roomID) ?? false
                    }
                }

                group.addTask {
                    try await Task.sleep(for: authorityTimeout)
                    try Task.checkCancellation()
                    await privacyModeService.cancelLoadAndWait(roomID: roomID)
                    throw PrivacyModeAuthorityResolutionError.timedOut
                }

                defer { group.cancelAll() }
                return try await group.next() ?? false
            }

            return Task.isCancelled ? nil : emergencyPrivacyModeEnabled || enabled
        } catch PrivacyModeAuthorityResolutionError.timedOut {
            guard !Task.isCancelled else {
                return nil
            }
            let cachedValue = await privacyModeService.cachedValue(roomID: roomID) ?? false
            return Task.isCancelled ? nil : emergencyPrivacyModeEnabled || cachedValue
        } catch {
            return nil
        }
    }

    private func trackComposerMode(_ mode: ComposerMode) {
        var isEdit = false
        var isReply = false
        switch mode {
        case .edit:
            isEdit = true
        case .reply:
            isReply = true
        default:
            break
        }

        analyticsService.trackComposer(inThread: false, isEditing: isEdit, isReply: isReply, startsThread: nil)
    }

    private func makeMediaPreviewViewModel(item: EventBasedMessageTimelineItemProtocol,
                                           timelineViewModelKind: TimelineControllerAction.TimelineViewModelKind) -> TimelineMediaPreviewViewModel {
        let timelineViewModel = switch timelineViewModelKind {
        case .active: self
        case .new(let newViewModel): newViewModel
        }

        return TimelineMediaPreviewViewModel(initialItem: item,
                                             timelineViewModel: timelineViewModel,
                                             mediaProvider: userSession.mediaProvider,
                                             photoLibraryManager: PhotoLibraryManager(),
                                             userIndicatorController: userIndicatorController,
                                             appMediator: appMediator)
    }

    // MARK: - Timeline Item Building

    private func buildTimelineViews(timelineItems: [RoomTimelineItemProtocol], isSwitchingTimelines: Bool = false) {
        var timelineItemsDictionary = OrderedDictionary<TimelineItemIdentifier.UniqueID, RoomTimelineItemViewState>()

        timelineItems.filter { $0 is RedactedRoomTimelineItem }.forEach { timelineItem in
            // Stops the audio player when a voice message is redacted.
            guard let playerState = mediaPlayerProvider.playerState(for: .timelineItemIdentifier(timelineItem.id)) else {
                return
            }

            Task { @MainActor in
                playerState.detachAudioPlayer()
                mediaPlayerProvider.unregister(audioPlayerState: playerState)
            }
        }

        let itemsGroupedByTimelineDisplayStyle = timelineItems.chunked { current, next in
            canGroupItem(timelineItem: current, with: next)
        }

        for itemGroup in itemsGroupedByTimelineDisplayStyle {
            guard !itemGroup.isEmpty else {
                MXLog.error("Found empty item group")
                continue
            }

            if itemGroup.count == 1 {
                if let firstItem = itemGroup.first {
                    timelineItemsDictionary.updateValue(updateViewState(item: firstItem, groupStyle: .single),
                                                        forKey: firstItem.id.uniqueID)
                }
            } else {
                for (index, item) in itemGroup.enumerated() {
                    if index == 0 {
                        timelineItemsDictionary.updateValue(updateViewState(item: item, groupStyle: state.timelineKind == .pinned ? .single : .first),
                                                            forKey: item.id.uniqueID)
                    } else if index == itemGroup.count - 1 {
                        timelineItemsDictionary.updateValue(updateViewState(item: item, groupStyle: state.timelineKind == .pinned ? .single : .last),
                                                            forKey: item.id.uniqueID)
                    } else {
                        timelineItemsDictionary.updateValue(updateViewState(item: item, groupStyle: state.timelineKind == .pinned ? .single : .middle),
                                                            forKey: item.id.uniqueID)
                    }
                }
            }
        }

        if isSwitchingTimelines {
            state.timelineState.isSwitchingTimelines = true
        }

        state.timelineState.itemsDictionary = timelineItemsDictionary
    }

    private func updateViewState(item: RoomTimelineItemProtocol, groupStyle: TimelineGroupStyle) -> RoomTimelineItemViewState {
        if let timelineItemViewState = state.timelineState.itemsDictionary[item.id.uniqueID] {
            timelineItemViewState.groupStyle = groupStyle
            timelineItemViewState.type = .init(item: item)
            return timelineItemViewState
        } else {
            return RoomTimelineItemViewState(item: item, groupStyle: groupStyle)
        }
    }

    private func canGroupItem(timelineItem: RoomTimelineItemProtocol, with otherTimelineItem: RoomTimelineItemProtocol) -> Bool {
        if timelineItem is CollapsibleTimelineItem || otherTimelineItem is CollapsibleTimelineItem {
            return false
        }

        guard let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol,
              let otherEventTimelineItem = otherTimelineItem as? EventBasedTimelineItemProtocol else {
            return false
        }

        // State events aren't rendered as messages so shouldn't be grouped.
        if eventTimelineItem is StateRoomTimelineItem || otherEventTimelineItem is StateRoomTimelineItem {
            return false
        }

        return eventTimelineItem.sender == otherEventTimelineItem.sender
            && eventTimelineItem.properties.reactions.isEmpty // Reactions break the grouping.
            && otherEventTimelineItem.timestamp.timeIntervalSince(eventTimelineItem.timestamp) < 5 * 60 // As does the passage of time.
    }

    // MARK: - Direct chats logics

    private let inviteLoadingIndicatorID = UUID().uuidString

    private func inviteOtherDMUserBack() {
        guard roomProxy.infoPublisher.value.isUserAloneInDirectRoom else {
            displayAlert(.unknown)
            return
        }

        Task {
            userIndicatorController.submitIndicator(.init(id: inviteLoadingIndicatorID, type: .toast, title: L10n.commonLoading))
            defer {
                userIndicatorController.retractIndicatorWithId(inviteLoadingIndicatorID)
            }

            guard
                let members = await roomProxy.members(),
                members.count == 2,
                let otherPerson = members.first(where: { $0.userID != roomProxy.ownUserID && $0.membership == .leave })
            else {
                displayAlert(.unknown)
                return
            }

            switch await roomProxy.invite(userID: otherPerson.userID) {
            case .success:
                break
            case .failure:
                displayAlert(.unableToInvite)
            }
        }
    }

    // MARK: - Reactions

    private func displayReactionSummary(for itemID: TimelineItemIdentifier, selectedKey: String) {
        guard let timelineItem = timelineController.timelineItems.firstUsingStableID(itemID),
              let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol else {
            return
        }

        state.bindings.reactionSummaryInfo = .init(reactions: eventTimelineItem.properties.reactions, selectedKey: selectedKey)
    }

    // MARK: - Read Receipts

    private func displayReadReceipts(for itemID: TimelineItemIdentifier) {
        guard let timelineItem = timelineController.timelineItems.firstUsingStableID(itemID),
              let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol else {
            return
        }

        state.bindings.readReceiptsSummaryInfo = .init(orderedReceipts: eventTimelineItem.properties.orderedReadReceipts, id: eventTimelineItem.id)
    }

    // MARK: - Message forwarding

    private func forwardMessage(itemID: TimelineItemIdentifier) {
        cancelDirectMessageForwardingPreparation(releasingProviderLease: false)
        let requestID = UUID()
        directMessageForwardingPreparationRequestID = requestID
        let preparationOwnerID = directMessageForwardingPreparationOwnerID
        let forwardingItemPreparer = forwardingItemPreparer
        let providerGeneration = renderedProviderGeneration
        let timelineItemsGeneration = renderedTimelineItemsGeneration
        let canCurrentUserRedactSelf = state.canCurrentUserRedactSelf
        let canCurrentUserRedactOthers = state.canCurrentUserRedactOthers
        prepareDirectMessageForwardingTask = Task { [weak self] in
            let forwardingItem = await forwardingItemPreparer.makeForwardingItem(for: itemID,
                                                                                 requestID: requestID,
                                                                                 preparationOwnerID: preparationOwnerID,
                                                                                 providerGeneration: providerGeneration,
                                                                                 timelineItemsGeneration: timelineItemsGeneration,
                                                                                 canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                                                                 canCurrentUserRedactOthers: canCurrentUserRedactOthers)
            guard let self,
                  let forwardingItem,
                  !Task.isCancelled,
                  directMessageForwardingPreparationRequestID == requestID else {
                return
            }
            prepareDirectMessageForwardingTask = nil
            directMessageForwardingPreparationRequestID = nil
            actionsSubject.send(.displayMessageForwarding(forwardingBatch: .init(firstItem: forwardingItem)))
        }
    }

    private func cancelDirectMessageForwardingPreparation(releasingProviderLease: Bool) {
        prepareDirectMessageForwardingTask?.cancel()
        prepareDirectMessageForwardingTask = nil
        directMessageForwardingPreparationRequestID = nil
        if releasingProviderLease {
            forwardingItemPreparer.cancel(preparationOwnerID: directMessageForwardingPreparationOwnerID)
        }
    }

    // MARK: Pills

    private func pillContextUpdater(_ pillContext: PillContext) {
        switch pillContext.data.type {
        case let .user(id):
            let isOwnMention = id == state.ownUserID
            if let profile = state.members[id] {
                pillContext.viewState = .mention(isOwnMention: isOwnMention, displayText: PillUtilities.userPillDisplayText(username: profile.displayName, userID: id))
            } else {
                pillContext.viewState = .mention(isOwnMention: isOwnMention, displayText: id)
                pillContext.cancellable = context.$viewState
                    .compactMap { $0.members[id] }
                    .sink { [weak pillContext] profile in
                        guard let pillContext else {
                            return
                        }
                        pillContext.viewState = .mention(isOwnMention: isOwnMention, displayText: PillUtilities.userPillDisplayText(username: profile.displayName, userID: id))
                        pillContext.cancellable = nil
                    }
            }
        case .allUsers:
            pillContext.viewState = .mention(isOwnMention: true, displayText: PillUtilities.atRoom)
        case .event(let room):
            let pillViewState: PillViewState
            switch room {
            case .roomAlias(let alias):
                let roomSummary = userSession.clientProxy.roomSummaryForAlias(alias)
                pillViewState = .reference(displayText: PillUtilities.eventPillDisplayText(roomName: roomSummary?.name, rawRoomText: alias))
            case .roomID(let id):
                let roomSummary = userSession.clientProxy.roomSummaryForIdentifier(id)
                pillViewState = .reference(displayText: PillUtilities.eventPillDisplayText(roomName: roomSummary?.name, rawRoomText: id))
            }
            pillContext.viewState = pillViewState
        case .roomAlias(let alias):
            let roomSummary = userSession.clientProxy.roomSummaryForAlias(alias)
            pillContext.viewState = .reference(displayText: PillUtilities.roomPillDisplayText(roomName: roomSummary?.name, rawRoomText: alias))
        case .roomID(let id):
            let roomSummary = userSession.clientProxy.roomSummaryForIdentifier(id)
            pillContext.viewState = .reference(displayText: PillUtilities.roomPillDisplayText(roomName: roomSummary?.name, rawRoomText: id))
        }
    }

    // MARK: - User Indicators

    private func showFocusLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Constants.focusTimelineToastIndicatorID,
                                                              type: .toast(progress: .indeterminate),
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }

    private func hideFocusLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Constants.focusTimelineToastIndicatorID)
    }

    private func displayAlert(_ type: TimelineAlertInfoType) {
        switch type {
        case .audioRecodingPermissionError:
            state.bindings.alertInfo = .init(id: type,
                                             title: L10n.dialogPermissionMicrophoneTitleIos(InfoPlistReader.main.bundleDisplayName),
                                             message: L10n.dialogPermissionMicrophoneDescriptionIos,
                                             primaryButton: .init(title: L10n.commonSettings) { [weak self] in self?.appMediator.openAppSettings() },
                                             secondaryButton: .init(title: L10n.actionNotNow, role: .cancel, action: nil))
        case .pollEndConfirmation(let pollStartID):
            state.bindings.alertInfo = .init(id: type,
                                             title: L10n.actionEndPoll,
                                             message: L10n.commonPollEndConfirmation,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionOk) { self.timelineInteractionHandler.endPoll(pollStartID: pollStartID) })
        case .sendingFailed:
            state.bindings.alertInfo = .init(id: type,
                                             title: L10n.commonSendingFailed,
                                             primaryButton: .init(title: L10n.actionOk, action: nil))
        case .encryptionAuthenticity(let message):
            state.bindings.alertInfo = .init(id: type,
                                             title: message,
                                             primaryButton: .init(title: L10n.actionOk, action: nil))
        case .encryptionForwarder(let message):
            state.bindings.alertInfo = .init(id: type,
                                             title: message,
                                             primaryButton: .init(title: L10n.actionOk, action: nil),
                                             secondaryButton: .init(title: L10n.actionLearnMore) { [weak self] in
                                                 guard let self else { return }
                                                 appMediator.open(appSettings.historySharingDetailsURL)
                                             })
        case .inviteAgain:
            state.bindings.alertInfo = .init(id: .inviteAgain,
                                             title: L10n.screenRoomInviteAgainAlertTitle,
                                             message: L10n.screenRoomInviteAgainAlertMessage,
                                             primaryButton: .init(title: L10n.actionInvite) { [weak self] in self?.inviteOtherDMUserBack() },
                                             secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
        case .unableToInvite:
            state.bindings.alertInfo = .init(id: .unableToInvite,
                                             title: L10n.commonUnableToInviteTitle,
                                             message: L10n.commonUnableToInviteMessage)
        case .unknown:
            state.bindings.alertInfo = .init(id: .unknown, title: L10n.commonError)
        }
    }

    private func displayErrorToast(_ title: String) {
        userIndicatorController.submitIndicator(UserIndicator(id: Constants.toastErrorID,
                                                              type: .toast,
                                                              title: title,
                                                              iconName: "xmark"))
    }
}

@MainActor
private final class TimelineForwardingItemPreparer {
    private struct Request: Hashable {
        let id: UUID
        let ownerID: UUID
    }

    private struct Waiter {
        let request: Request
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let roomID: String
    private let timelineController: TimelineControllerProtocol
    private var activeRequest: Request?
    private var activeLease: (request: Request, lease: TimelineProviderLease)?
    private var waiters = [Waiter]()
    private var cancelledRequests = Set<Request>()

    init(roomID: String, timelineController: TimelineControllerProtocol) {
        self.roomID = roomID
        self.timelineController = timelineController
    }

    func makeForwardingItem(for itemID: TimelineItemIdentifier,
                            requestID: UUID,
                            preparationOwnerID: UUID,
                            providerGeneration: UInt,
                            timelineItemsGeneration: UInt,
                            canCurrentUserRedactSelf: Bool,
                            canCurrentUserRedactOthers: Bool) async -> MessageForwardingItem? {
        let request = Request(id: requestID, ownerID: preparationOwnerID)
        defer { cancelledRequests.remove(request) }
        guard await acquireSlot(for: request) else { return nil }
        defer { releaseSlot(for: request) }

        guard isActive(request),
              let sourceItem = forwardableTimelineItem(withExactIdentifier: itemID,
                                                       providerGeneration: providerGeneration,
                                                       timelineItemsGeneration: timelineItemsGeneration,
                                                       canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                                       canCurrentUserRedactOthers: canCurrentUserRedactOthers) else {
            return nil
        }
        let sourceItemType = RoomTimelineItemType(item: sourceItem)

        guard let providerLease = timelineController.acquireProviderLease(),
              providerLease.providerGeneration == providerGeneration,
              providerLease.timelineItemsGeneration == timelineItemsGeneration else {
            return nil
        }
        activeLease = (request, providerLease)
        defer { releaseLease(providerLease, for: request) }

        guard isActive(request), timelineController.isProviderLeaseValid(providerLease),
              let content = await timelineController.messageEventContent(for: itemID, using: providerLease),
              isActive(request), timelineController.isProviderLeaseValid(providerLease),
              let currentItem = forwardableTimelineItem(withExactIdentifier: itemID,
                                                        providerGeneration: providerGeneration,
                                                        timelineItemsGeneration: timelineItemsGeneration,
                                                        canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                                        canCurrentUserRedactOthers: canCurrentUserRedactOthers),
              RoomTimelineItemType(item: currentItem) == sourceItemType else {
            return nil
        }

        return MessageForwardingItem(id: itemID, roomID: roomID, content: content)
    }

    func cancel(preparationOwnerID: UUID) {
        if let activeRequest, activeRequest.ownerID == preparationOwnerID {
            cancelledRequests.insert(activeRequest)
            if let activeLease, activeLease.request == activeRequest {
                timelineController.releaseProviderLease(activeLease.lease)
                self.activeLease = nil
            }
            self.activeRequest = nil
        }

        let cancelledWaiters = waiters.filter { $0.request.ownerID == preparationOwnerID }
        waiters.removeAll { $0.request.ownerID == preparationOwnerID }
        for waiter in cancelledWaiters {
            cancelledRequests.insert(waiter.request)
            waiter.continuation.resume(returning: false)
        }
        resumeNextWaiterIfNeeded()
    }

    private func acquireSlot(for request: Request) async -> Bool {
        guard !Task.isCancelled, !cancelledRequests.contains(request) else { return false }
        guard activeRequest != nil else {
            activeRequest = request
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !cancelledRequests.contains(request) else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(.init(request: request, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(request)
            }
        }
    }

    private func releaseSlot(for request: Request) {
        guard activeRequest == request else { return }
        activeRequest = nil
        resumeNextWaiterIfNeeded()
    }

    private func releaseLease(_ lease: TimelineProviderLease, for request: Request) {
        guard activeLease?.request == request, activeLease?.lease == lease else { return }
        timelineController.releaseProviderLease(lease)
        activeLease = nil
    }

    private func cancelWaiter(_ request: Request) {
        guard let index = waiters.firstIndex(where: { $0.request == request }) else { return }
        let waiter = waiters.remove(at: index)
        cancelledRequests.insert(request)
        waiter.continuation.resume(returning: false)
    }

    private func resumeNextWaiterIfNeeded() {
        guard activeRequest == nil else { return }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            guard !cancelledRequests.contains(waiter.request) else {
                waiter.continuation.resume(returning: false)
                continue
            }
            activeRequest = waiter.request
            waiter.continuation.resume(returning: true)
            return
        }
    }

    private func isActive(_ request: Request) -> Bool {
        !Task.isCancelled && activeRequest == request && !cancelledRequests.contains(request)
    }

    private func forwardableTimelineItem(withExactIdentifier itemID: TimelineItemIdentifier,
                                         providerGeneration: UInt,
                                         timelineItemsGeneration: UInt,
                                         canCurrentUserRedactSelf: Bool,
                                         canCurrentUserRedactOthers: Bool) -> EventBasedTimelineItemProtocol? {
        guard timelineController.activeProviderGeneration == providerGeneration,
              timelineController.timelineItemsProviderGeneration == providerGeneration,
              timelineController.timelineItemsGeneration == timelineItemsGeneration,
              !timelineController.isTimelineItemsBuildInProgress,
              let timelineItem = timelineController.timelineItems.firstUsingStableID(itemID),
              timelineItem.id == itemID,
              let eventTimelineItem = timelineItem as? EventBasedTimelineItemProtocol,
              TimelineMessageSelectionEligibility.capabilities(for: eventTimelineItem,
                                                               canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                                               canCurrentUserRedactOthers: canCurrentUserRedactOthers)?.canForward == true else {
            return nil
        }
        return eventTimelineItem
    }
}

private extension TimelineViewAction {
    var isBlockedDuringMessageSelection: Bool {
        switch self {
        case .mediaTapped,
             .itemSendInfoTapped,
             .toggleReaction,
             .displayTimelineItemMenu,
             .handleTimelineItemMenuAction,
             .tappedOnSenderDetails,
             .displayReactionSummary,
             .displayEmojiPicker,
             .displayReadReceipts,
             .displayThread,
             .handlePasteOrDrop,
             .handlePollAction,
             .handleAudioPlayerAction,
             .stopLiveLocationSharing,
             .focusOnEventID,
             .focusLive,
             .scrollToBottom,
             .paginateForwards,
             .displayPredecessorRoom:
            true
        default:
            false
        }
    }
}

// MARK: - Mocks

extension TimelineViewModel {
    static let mock = mock(timelineKind: .live)

    static func mock(timelineKind: TimelineKind = .live, timelineController: MockTimelineController? = nil, hasPredecessor: Bool = false) -> TimelineViewModel {
        let clientProxyMock = ClientProxyMock(.init())
        clientProxyMock.roomSummaryForAliasReturnValue = .mock(id: "!room:matrix.org", name: "Room")
        clientProxyMock.roomSummaryForIdentifierReturnValue = .mock(id: "!room:matrix.org", name: "Room", canonicalAlias: "#room:matrix.org")
        let roomProxy = JoinedRoomProxyMock(.init(name: "Preview room", predecessor: hasPredecessor ? .init(roomId: UUID().uuidString) : nil))
        return TimelineViewModel(roomProxy: roomProxy,
                                 focussedEventID: nil,
                                 timelineController: timelineController ?? MockTimelineController(timelineKind: timelineKind),
                                 userSession: UserSessionMock(.init(clientProxy: clientProxyMock)),
                                 mediaPlayerProvider: MediaPlayerProviderMock(),
                                 userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                 appMediator: AppMediatorMock.default,
                                 appSettings: ServiceLocator.shared.settings,
                                 analyticsService: ServiceLocator.shared.analytics,
                                 emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                 linkMetadataProvider: LinkMetadataProvider(),
                                 timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
}

extension EnvironmentValues {
    /// Used to access and inject the room context without observing it
    @Entry var timelineContext: TimelineViewModel.Context?
    /// An event ID which will be non-nil when a timeline item should show as focussed.
    @Entry var focussedEventID: String?
}

private enum SlashCommand: String, CaseIterable {
    case join = "/join "
}
