//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum PinnedEventsTimelineFlowCoordinatorAction {
    case finished
    case displayUser(userID: String)
    case forwardedMessageToRoom(roomID: String)
    case displayRoomScreenWithFocussedPin(eventID: String, threadRootEventID: String?)
}

class PinnedEventsTimelineFlowCoordinator: FlowCoordinatorProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let flowParameters: CommonFlowParameters
    private let messageForwardingCoordinatorFactory: @MainActor (MessageForwardingScreenCoordinatorParameters) -> MessageForwardingScreenCoordinator
    
    private var userSession: UserSessionProtocol {
        flowParameters.userSession
    }
    
    private let actionsSubject: PassthroughSubject<PinnedEventsTimelineFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<PinnedEventsTimelineFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    init(roomProxy: JoinedRoomProxyProtocol,
         navigationStackCoordinator: NavigationStackCoordinator,
         flowParameters: CommonFlowParameters,
         messageForwardingCoordinatorFactory: @escaping @MainActor (MessageForwardingScreenCoordinatorParameters) -> MessageForwardingScreenCoordinator = MessageForwardingScreenCoordinator.init) {
        self.roomProxy = roomProxy
        self.navigationStackCoordinator = navigationStackCoordinator
        self.flowParameters = flowParameters
        self.messageForwardingCoordinatorFactory = messageForwardingCoordinatorFactory
    }
    
    func start(animated: Bool) {
        Task { await presentPinnedEventsTimeline() }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        fatalError()
    }
    
    func clearRoute(animated: Bool) {
        fatalError()
    }
    
    private func presentPinnedEventsTimeline() async {
        let userID = userSession.clientProxy.userID
        let timelineItemFactory = RoomTimelineItemFactory(userID: userID,
                                                          attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                                          stateEventStringBuilder: RoomStateEventStringBuilder(userID: userID))
        
        guard case let .success(timelineController) = await flowParameters.timelineControllerFactory.buildPinnedEventsTimelineController(roomProxy: roomProxy,
                                                                                                                                         timelineItemFactory: timelineItemFactory,
                                                                                                                                         mediaProvider: userSession.mediaProvider) else {
            fatalError("This can never fail because we allow this view to be presented only when the timeline is fully loaded and not nil")
        }
        
        let coordinator = PinnedEventsTimelineScreenCoordinator(parameters: .init(roomProxy: roomProxy,
                                                                                  timelineController: timelineController,
                                                                                  userSession: userSession,
                                                                                  mediaPlayerProvider: MediaPlayerProvider(),
                                                                                  appMediator: flowParameters.appMediator,
                                                                                  appSettings: flowParameters.appSettings,
                                                                                  analytics: flowParameters.analytics,
                                                                                  emojiProvider: flowParameters.emojiProvider,
                                                                                  linkMetadataProvider: flowParameters.linkMetadataProvider,
                                                                                  timelineControllerFactory: flowParameters.timelineControllerFactory,
                                                                                  userIndicatorController: flowParameters.userIndicatorController))
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .dismiss:
                    actionsSubject.send(.finished)
                case .displayUser(let userID):
                    actionsSubject.send(.displayUser(userID: userID))
                case .presentLocationViewer(let location):
                    presentMapNavigator(interactionMode: .viewStatic(location),
                                        timelineController: timelineController)
                case .presentLiveLocationViewer(let sender, let initialLiveLocationShare):
                    presentMapNavigator(interactionMode: .viewLive(sender: sender, initialLiveLocationShare: initialLiveLocationShare),
                                        timelineController: timelineController)
                case .displayMessageForwarding(let forwardingBatch):
                    presentMessageForwarding(with: forwardingBatch)
                case .displayRoomScreenWithFocussedPin(let eventID, let threadRootEventID):
                    actionsSubject.send(.displayRoomScreenWithFocussedPin(eventID: eventID, threadRootEventID: threadRootEventID))
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
    }
    
    private func presentMapNavigator(interactionMode: LocationSharingInteractionMode,
                                     timelineController: TimelineControllerProtocol) {
        let stackCoordinator = NavigationStackCoordinator()
        
        let params = LocationSharingScreenCoordinatorParameters(interactionMode: interactionMode,
                                                                mapURLBuilder: flowParameters.appSettings.mapTilerConfiguration,
                                                                roomProxy: roomProxy,
                                                                timelineController: timelineController,
                                                                liveLocationManager: flowParameters.userSession.liveLocationManager,
                                                                appMediator: flowParameters.appMediator,
                                                                analytics: flowParameters.analytics,
                                                                userIndicatorController: flowParameters.userIndicatorController,
                                                                mediaProvider: flowParameters.userSession.mediaProvider)
        let coordinator = LocationSharingScreenCoordinator(parameters: params)
        
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .close:
                self.navigationStackCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)
        
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator)
    }
    
    func presentMessageForwarding(with forwardingBatch: MessageForwardingBatch) {
        let roomSummaryProvider = userSession.clientProxy.alternateRoomSummaryProvider
        
        let stackCoordinator = NavigationStackCoordinator()
        
        let parameters = MessageForwardingScreenCoordinatorParameters(forwardingBatch: forwardingBatch,
                                                                      userSession: userSession,
                                                                      roomSummaryProvider: roomSummaryProvider,
                                                                      userIndicatorController: flowParameters.userIndicatorController)
        let coordinator = messageForwardingCoordinatorFactory(parameters)
        
        coordinator.actions.sink { [weak self, weak coordinator] action in
            guard let self else { return }
            
            switch action {
            case .dismiss:
                navigationStackCoordinator.setSheetCoordinator(nil)
            case .queued(let roomID):
                coordinator?.confirmForwardingCompleted()
                actionsSubject.send(.forwardedMessageToRoom(roomID: roomID))
                navigationStackCoordinator.setSheetCoordinator(nil)
            }
        }
        .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)

        navigationStackCoordinator.setSheetCoordinator(stackCoordinator)
    }
}
