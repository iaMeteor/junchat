//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@MainActor
struct PinnedEventsTimelineFlowCoordinatorTests {
    @Test
    func queuedForwardingIsConfirmedBeforeParentTearsDownTheNestedCoordinator() {
        let parentNavigationStackCoordinator = NavigationStackCoordinator()
        let pinnedNavigationStackCoordinator = NavigationStackCoordinator()
        let viewModel = MessageForwardingScreenViewModelSpy()
        let flowCoordinator = PinnedEventsTimelineFlowCoordinator(roomProxy: JoinedRoomProxyMock(.init()),
                                                                  navigationStackCoordinator: pinnedNavigationStackCoordinator,
                                                                  flowParameters: makeFlowParameters()) { _ in
            MessageForwardingScreenCoordinator(viewModel: viewModel)
        }
        var cancellables = Set<AnyCancellable>()

        parentNavigationStackCoordinator.setSheetCoordinator(pinnedNavigationStackCoordinator)
        flowCoordinator.actionsPublisher
            .sink { action in
                guard case .forwardedMessageToRoom = action else { return }
                viewModel.lifecycleEvents.append(.parentAction)
                parentNavigationStackCoordinator.setSheetCoordinator(nil)
            }
            .store(in: &cancellables)

        flowCoordinator.presentMessageForwarding(with: makeForwardingBatch())
        viewModel.sendQueued(roomID: "destination")

        #expect(viewModel.lifecycleEvents == [.confirmed, .parentAction, .stopped])
        #expect(parentNavigationStackCoordinator.sheetCoordinator == nil)
        #expect(pinnedNavigationStackCoordinator.sheetCoordinator == nil)
    }

    private func makeFlowParameters() -> CommonFlowParameters {
        let clientProxy = ClientProxyMock(.init(userID: "@alice:example.org",
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))

        return CommonFlowParameters(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                    bugReportService: BugReportServiceMock(.init()),
                                    elementCallService: ElementCallServiceMock(.init()),
                                    timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                    emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                    linkMetadataProvider: LinkMetadataProvider(),
                                    appMediator: AppMediatorMock.default,
                                    appSettings: ServiceLocator.shared.settings,
                                    appHooks: AppHooks(),
                                    analytics: ServiceLocator.shared.analytics,
                                    userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                    notificationManager: NotificationManagerMock(),
                                    stateMachineFactory: StateMachineFactory())
    }

    private func makeForwardingBatch() -> MessageForwardingBatch {
        let item = MessageForwardingItem(id: .event(uniqueID: .init("event"), eventOrTransactionID: .eventID("event")),
                                         roomID: "source",
                                         content: .init(noHandle: .init()))
        return .init(firstItem: item)
    }
}

@MainActor
private final class MessageForwardingScreenViewModelSpy: MessageForwardingScreenViewModelType, MessageForwardingScreenViewModelProtocol {
    enum LifecycleEvent: Equatable {
        case confirmed
        case parentAction
        case stopped
    }

    private let actionsSubject = PassthroughSubject<MessageForwardingScreenViewModelAction, Never>()
    var actions: AnyPublisher<MessageForwardingScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    var lifecycleEvents = [LifecycleEvent]()

    init() {
        super.init(initialViewState: .init())
    }

    func sendQueued(roomID: String) {
        actionsSubject.send(.queued(roomID: roomID))
    }

    func confirmForwardingCompleted() {
        lifecycleEvents.append(.confirmed)
    }

    func stop() {
        lifecycleEvents.append(.stopped)
    }
}
