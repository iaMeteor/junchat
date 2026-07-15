//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ThreadTimelineScreenViewModelType = StateStoreViewModel<ThreadTimelineScreenViewState, ThreadTimelineScreenViewAction>

class ThreadTimelineScreenViewModel: ThreadTimelineScreenViewModelType, ThreadTimelineScreenViewModelProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let userSession: UserSessionProtocol
    private let mediaPreviewForwardingHandoff: TimelineMediaPreviewForwardingHandoff
    private var mediaPreviewCancellable: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<ThreadTimelineScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ThreadTimelineScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(roomProxy: JoinedRoomProxyProtocol,
         userSession: UserSessionProtocol,
         mediaPreviewForwardingClock: any Clock<Duration> = ContinuousClock()) {
        self.roomProxy = roomProxy
        self.userSession = userSession
        mediaPreviewForwardingHandoff = .init(clock: mediaPreviewForwardingClock)
        
        super.init(initialViewState: ThreadTimelineScreenViewState(roomTitle: roomProxy.infoPublisher.value.displayName ?? roomProxy.id,
                                                                   roomAvatar: roomProxy.infoPublisher.value.avatar), mediaProvider: userSession.mediaProvider)
        
        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)
        
        let identityStatusChangesPublisher = roomProxy.identityStatusChangesPublisher.receive(on: DispatchQueue.main)
        Task { [weak self] in
            for await _ in identityStatusChangesPublisher.values {
                guard !Task.isCancelled else {
                    return
                }
                
                await self?.updateVerificationBadge()
            }
        }
        .store(in: &cancellables)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
        Task { await updateVerificationBadge() }
    }
    
    // MARK: - Public
    
    override func process(viewAction: ThreadTimelineScreenViewAction) { }
    
    func stop() {
        cancelMediaPreviewForwardingHandoff()
        // Work around QLPreviewController dismissal issues, see the InteractiveQuickLookModifier.
        state.bindings.mediaPreviewViewModel = nil
    }
    
    func displayMediaPreview(_ mediaPreviewViewModel: TimelineMediaPreviewViewModel) {
        cancelMediaPreviewForwardingHandoff()
        mediaPreviewCancellable = mediaPreviewViewModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .viewInRoomTimeline:
                fatalError("\(action) should not be visible on a thread preview.")
            case .displayMessageForwarding(let forwardingBatch):
                state.bindings.mediaPreviewViewModel = nil
                mediaPreviewForwardingHandoff.schedule { [weak self] in
                    guard let self else { return }
                    mediaPreviewCancellable = nil
                    actionsSubject.send(.displayMessageForwarding(forwardingBatch))
                }
            case .dismiss:
                state.bindings.mediaPreviewViewModel = nil
                cancelMediaPreviewForwardingHandoff()
            }
        }
        
        state.bindings.mediaPreviewViewModel = mediaPreviewViewModel
    }
    
    // MARK: - Private

    private func cancelMediaPreviewForwardingHandoff() {
        mediaPreviewForwardingHandoff.cancel()
        mediaPreviewCancellable?.cancel()
        mediaPreviewCancellable = nil
    }
    
    private func updateVerificationBadge() async {
        guard roomProxy.isDirectOneToOneRoom,
              let dmRecipient = roomProxy.membersPublisher.value.first(where: { $0.userID != roomProxy.ownUserID }),
              case let .success(userIdentity) = await userSession.clientProxy.userIdentity(for: dmRecipient.userID, fallBackToServer: true) else {
            state.dmRecipientVerificationState = .notVerified
            return
        }
        
        guard let userIdentity else {
            MXLog.error("User identity is unavailable for DM recipient; falling back to not verified.")
            state.dmRecipientVerificationState = .notVerified
            return
        }
        
        state.dmRecipientVerificationState = userIdentity.verificationState
    }
    
    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        state.roomTitle = roomInfo.displayName ?? roomProxy.id
        state.roomAvatar = roomInfo.avatar
        if let powerLevels = roomInfo.powerLevels {
            state.canSendMessage = powerLevels.canOwnUser(sendMessage: .roomMessage)
        }
    }
}
