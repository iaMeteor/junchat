//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftState
import SwiftUI

enum UserSessionFlowCoordinatorAction {
    case logout
    case clearCache
    /// Logout and disable App Lock without any confirmation. The user forgot their PIN.
    case forceLogout
}

typealias CallScreenCoordinatorFactory = @MainActor (CallScreenCoordinatorParameters) -> any CallScreenCoordinatorProtocol

class UserSessionFlowCoordinator: FlowCoordinatorProtocol {
    enum HomeTab: Hashable { case chats, contacts, entertainment, spaces }

    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationTabCoordinator: NavigationTabCoordinator<HomeTab>
    private let appLockService: AppLockServiceProtocol
    private let flowParameters: CommonFlowParameters
    private let callScreenCoordinatorFactory: CallScreenCoordinatorFactory

    private var userSession: UserSessionProtocol {
        flowParameters.userSession
    }

    private let onboardingFlowCoordinator: OnboardingFlowCoordinator
    private let onboardingStackCoordinator: NavigationStackCoordinator
    private let chatsSplitCoordinator: NavigationSplitCoordinator
    private let chatsTabFlowCoordinator: ChatsTabFlowCoordinator
    private let chatsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let contactsStackCoordinator: NavigationStackCoordinator
    private let contactsScreenCoordinator: ContactsScreenCoordinator
    private let contactsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let entertainmentStackCoordinator: NavigationStackCoordinator
    private let entertainmentScreenCoordinator: EntertainmentScreenCoordinator
    private let entertainmentTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let spacesSplitCoordinator: NavigationSplitCoordinator
    private let spacesTabFlowCoordinator: SpacesTabFlowCoordinator
    private let spacesTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails

    // periphery:ignore - retaining purpose
    private var settingsFlowCoordinator: SettingsFlowCoordinator?

    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        /// The root screen for this flow.
        case tabBar
        /// Showing the settings screen.
        case settingsScreen
    }

    enum Event: EventType {
        /// The flow is being started.
        case start

        /// Request presentation of the settings screen.
        case showSettingsScreen
        /// The settings screen has been dismissed.
        case dismissedSettingsScreen
    }

    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []
    private var incomingCallOverlayCancellables: Set<AnyCancellable> = []
    private var globalIncomingCallPresentation = GlobalIncomingCallPresentation()
    private var presentedIncomingCallRoomID: String?
    private var presentedIncomingCallIdentity: ElementCallIncomingCallIdentity?
    private var presentedCallScreenRoomID: String?
    private var presentedCallScreenIncomingCallIdentity: ElementCallIncomingCallIdentity?
    private var presentedCallScreenStartedAt: Date?
    private var callScreenHasSeenRemoteParticipant = false
    private var endedCallDismissalWorkItem: DispatchWorkItem?
    private var callPresentationRequestID: UUID?
    private var incomingCallOverlayRequestID: UUID?

    private let actionsSubject: PassthroughSubject<UserSessionFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<UserSessionFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(isNewLogin: Bool,
         navigationRootCoordinator: NavigationRootCoordinator,
         appLockService: AppLockServiceProtocol,
         flowParameters: CommonFlowParameters,
         callScreenCoordinatorFactory: @escaping CallScreenCoordinatorFactory = { CallScreenCoordinator(parameters: $0) }) {
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appLockService = appLockService
        self.flowParameters = flowParameters
        self.callScreenCoordinatorFactory = callScreenCoordinatorFactory

        navigationTabCoordinator = NavigationTabCoordinator()
        navigationRootCoordinator.setRootCoordinator(navigationTabCoordinator)

        chatsSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        chatsTabFlowCoordinator = ChatsTabFlowCoordinator(isNewLogin: isNewLogin,
                                                          navigationSplitCoordinator: chatsSplitCoordinator,
                                                          flowParameters: flowParameters)
        chatsTabDetails = .init(tag: HomeTab.chats, title: L10n.screenHomeTabChats, icon: \.chat, selectedIcon: \.chatSolid)
        chatsTabDetails.navigationSplitCoordinator = chatsSplitCoordinator

        contactsStackCoordinator = NavigationStackCoordinator()
        contactsScreenCoordinator = ContactsScreenCoordinator(parameters: .init(userSession: flowParameters.userSession,
                                                                                userIndicatorController: flowParameters.userIndicatorController))
        contactsStackCoordinator.setRootCoordinator(contactsScreenCoordinator)
        contactsTabDetails = .init(tag: HomeTab.contacts, title: "通讯录", icon: \.userProfile, selectedIcon: \.userProfileSolid)

        entertainmentStackCoordinator = NavigationStackCoordinator()
        entertainmentScreenCoordinator = EntertainmentScreenCoordinator()
        entertainmentStackCoordinator.setRootCoordinator(entertainmentScreenCoordinator)
        entertainmentTabDetails = .init(tag: HomeTab.entertainment, title: "娱乐", icon: \.labs, selectedIcon: \.labs)

        spacesSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        spacesTabFlowCoordinator = SpacesTabFlowCoordinator(navigationSplitCoordinator: spacesSplitCoordinator,
                                                            flowParameters: flowParameters)
        spacesTabDetails = .init(tag: HomeTab.spaces, title: L10n.screenHomeTabSpaces, icon: \.space, selectedIcon: \.spaceSolid)
        spacesTabDetails.navigationSplitCoordinator = spacesSplitCoordinator

        onboardingStackCoordinator = NavigationStackCoordinator()
        onboardingFlowCoordinator = OnboardingFlowCoordinator(isNewLogin: isNewLogin,
                                                              appLockService: appLockService,
                                                              navigationStackCoordinator: onboardingStackCoordinator,
                                                              flowParameters: flowParameters)

        var initialTabs: [NavigationTabCoordinator<HomeTab>.Tab] = [
            .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
            .init(coordinator: contactsStackCoordinator, details: contactsTabDetails)
        ]
        if flowParameters.appSettings.showEntertainmentTab {
            initialTabs.append(.init(coordinator: entertainmentStackCoordinator, details: entertainmentTabDetails))
        }
        initialTabs.append(.init(coordinator: spacesSplitCoordinator, details: spacesTabDetails))
        navigationTabCoordinator.setTabs(initialTabs, animated: false)

        stateMachine = flowParameters.stateMachineFactory.makeUserSessionFlowStateMachine(state: .initial)
        configureStateMachine()

        setupObservers()
    }

    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }

    func stop() {
        chatsTabFlowCoordinator.stop()
    }

    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        switch appRoute {
        case .accountProvisioningLink:
            break // We always ignore this flow when logged in.
        case .settings, .chatBackupSettings:
            if ProcessInfo.processInfo.isiOSAppOnMac {
                startSettingsFlow(detached: true)
            } else {
                if stateMachine.state != .settingsScreen {
                    stateMachine.tryEvent(.showSettingsScreen)
                }
                settingsFlowCoordinator?.handleAppRoute(appRoute, animated: animated)
            }
        case .call(let roomID, let isVoiceCall, let incomingCallIdentity):
            let requestID = beginCallPresentationRequest()
            Task {
                await presentCallScreen(roomID: roomID,
                                        isVoiceCall: isVoiceCall,
                                        incomingCallIdentity: incomingCallIdentity,
                                        requestID: requestID)
            }
        case .roomList, .room, .roomAlias, .childRoom, .childRoomAlias,
             .roomDetails, .roomMemberDetails, .userProfile,
             .event, .eventOnRoomAlias, .childEvent, .childEventOnRoomAlias,
             .share, .transferOwnership, .thread, .globalSearch:
            clearPresentedSheets(animated: animated) // Make sure the presented route is visible.
            chatsTabFlowCoordinator.handleAppRoute(appRoute, animated: animated)
            if navigationTabCoordinator.selectedTab != .chats {
                navigationTabCoordinator.selectedTab = .chats
            }
        }
    }

    func clearRoute(animated: Bool) {
        clearPresentedSheets(animated: animated)
        chatsTabFlowCoordinator.clearRoute(animated: animated)
    }

    /// Clearing routes is more complicated than it first seems. When passing routes
    /// to the chats flow we can't clear all routes as e.g. childRoom/childEvent etc
    /// expect to push into the existing stack. But we do need to hide any sheets that
    /// might cover up the presented route. BUT! We probably shouldn't dismiss onboarding
    /// or verification flows until they're complete… This needs more thought before we
    /// codify it all into the state machine.
    private func clearPresentedSheets(animated: Bool) {
        switch stateMachine.state {
        case .initial, .tabBar:
            break
        case .settingsScreen:
            navigationTabCoordinator.setSheetCoordinator(nil, animated: animated)
        }
    }

    func isDisplayingRoomScreen(withRoomID roomID: String) -> Bool {
        guard navigationTabCoordinator.selectedTab == .chats else { return false }
        return chatsTabFlowCoordinator.isDisplayingRoomScreen(withRoomID: roomID)
    }

    // MARK: - Private

    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .tabBar]) { [weak self] _ in
            guard let self else { return }

            chatsTabFlowCoordinator.start()
            spacesTabFlowCoordinator.start()
            attemptStartingOnboarding()
        }

        stateMachine.addRoutes(event: .showSettingsScreen, transitions: [.tabBar => .settingsScreen]) { [weak self] _ in
            self?.startSettingsFlow(detached: false)
        }
        stateMachine.addRoutes(event: .dismissedSettingsScreen, transitions: [.settingsScreen => .tabBar]) { [weak self] _ in
            self?.settingsFlowCoordinator = nil
        }

        stateMachine.addErrorHandler { context in
            fatalError("Unexpected transition: \(context)")
        }
    }

    // Keeps the flow's publisher wiring together so ownership remains visible.
    // swiftlint:disable:next function_body_length
    private func setupObservers() {
        flowParameters.appSettings.$showEntertainmentTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeTabs()
            }
            .store(in: &cancellables)

        chatsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .switchToChatsTab:
                    navigationTabCoordinator.selectedTab = .chats
                case .showSettings:
                    handleAppRoute(.settings, animated: true)
                case .showChatBackupSettings:
                    handleAppRoute(.chatBackupSettings, animated: true)
                case .sessionVerification(let flow):
                    presentSessionVerificationScreen(flow: flow)
                case .showCallScreen(let roomProxy, let isVoiceCall):
                    let requestID = beginCallPresentationRequest()
                    Task {
                        await self.presentCallScreen(roomProxy: roomProxy,
                                                     voiceOnly: isVoiceCall,
                                                     requestID: requestID)
                    }
                case .hideCallScreenOverlay:
                    hideCallScreenOverlay()
                case .logout:
                    Task { await self.runLogoutFlow() }
                }
            }
            .store(in: &cancellables)

        spacesTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentCallScreen(let roomProxy, let isVoiceCall):
                    let requestID = beginCallPresentationRequest()
                    Task {
                        await self.presentCallScreen(roomProxy: roomProxy,
                                                     voiceOnly: isVoiceCall,
                                                     requestID: requestID)
                    }
                case .verifyUser(let userID):
                    presentSessionVerificationScreen(flow: .userInitiator(userID: userID))
                case .showSettings:
                    stateMachine.tryEvent(.showSettingsScreen)
                }
            }
            .store(in: &cancellables)

        contactsScreenCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .showRoom(let roomID):
                    clearPresentedSheets(animated: true)
                    chatsTabFlowCoordinator.handleAppRoute(.room(roomID: roomID, via: []), animated: true)
                    navigationTabCoordinator.selectedTab = .chats
                }
            }
            .store(in: &cancellables)

        userSession.sessionSecurityStatePublisher
            .map(\.verificationState)
            .filter { $0 != .unknown }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }

                attemptStartingOnboarding()
                setupSessionVerificationRequestsObserver()
            }
            .store(in: &cancellables)

        let reachabilityNotificationID = "io.element.elementx.reachability.notification"
        userSession.clientProxy.homeserverReachabilityPublisher.removeDuplicates()
            .combineLatest(flowParameters.appMediator.networkMonitor.reachabilityPublisher.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] homeserverReachability, networkReachability in
                MXLog.info("Homeserver reachability: \(homeserverReachability)")

                guard let self else { return }
                switch (networkReachability, homeserverReachability) {
                case (.reachable, .reachable):
                    flowParameters.userIndicatorController.retractIndicatorWithId(reachabilityNotificationID)
                case (.reachable, .unreachable):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonServerUnreachable,
                                                                                 persistent: true))
                case (.unreachable, _):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonOffline,
                                                                                 persistent: true))
                }
            }
            .store(in: &cancellables)

        onboardingFlowCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .requestPresentation(let animated):
                    navigationTabCoordinator.setFullScreenCoverCoordinator(onboardingStackCoordinator, animated: animated)
                case .dismiss:
                    navigationTabCoordinator.setFullScreenCoverCoordinator(nil)
                case .logoutConfirmed:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)

        flowParameters.elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                switch action {
                case .startCall(_, _, let incomingCallIdentity):
                    self?.dismissIncomingCallOverlayIfNeeded(matching: incomingCallIdentity)
                case .endCall(let roomID):
                    Task { await self?.dismissCallScreenIfNeeded(matching: roomID) }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher
            .combineLatest(flowParameters.ongoingCallRoomIDPublisher,
                           flowParameters.elementCallService.incomingCallIdentityPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms, ongoingCallRoomID, incomingCallIdentity in
                self?.updateIncomingCallOverlay(rooms: rooms,
                                                ongoingCallRoomID: ongoingCallRoomID,
                                                pendingIncomingCallIdentity: incomingCallIdentity)
                self?.dismissEndedCallScreenIfNeeded(rooms: rooms, ongoingCallRoomID: ongoingCallRoomID)
            }
            .store(in: &cancellables)
    }

    private func updateHomeTabs(animated: Bool = true) {
        let selectedTab = navigationTabCoordinator.selectedTab
        var tabs: [NavigationTabCoordinator<HomeTab>.Tab] = [
            .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
            .init(coordinator: contactsStackCoordinator, details: contactsTabDetails)
        ]

        if flowParameters.appSettings.showEntertainmentTab {
            tabs.append(.init(coordinator: entertainmentStackCoordinator, details: entertainmentTabDetails))
        }

        tabs.append(.init(coordinator: spacesSplitCoordinator, details: spacesTabDetails))
        navigationTabCoordinator.setTabs(tabs, animated: animated)

        if let selectedTab, tabs.contains(where: { $0.details.tag == selectedTab }) {
            navigationTabCoordinator.selectedTab = selectedTab
        }
    }

    // MARK: - Onboarding

    private func attemptStartingOnboarding() {
        MXLog.info("Attempting to start onboarding")

        if onboardingFlowCoordinator.shouldStart {
            clearRoute(animated: false)
            onboardingFlowCoordinator.start()
        }
    }

    // MARK: - Settings

    private func startSettingsFlow(detached: Bool) {
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = SettingsFlowCoordinator(appLockService: appLockService,
                                                  navigationStackCoordinator: navigationStackCoordinator,
                                                  flowParameters: flowParameters)

        coordinator.actions.sink { [weak self] action in
            guard let self else { return }

            switch action {
            case .dismiss:
                navigationTabCoordinator.setSheetCoordinator(nil)
            case .clearCache:
                actionsSubject.send(.clearCache)
            case .runLogoutFlow:
                Task {
                    self.navigationTabCoordinator.setSheetCoordinator(nil)

                    // The sheet needs to be dismissed before the alert can be shown
                    try await Task.sleep(for: .milliseconds(100))
                    await self.runLogoutFlow()
                }
            case .forceLogout:
                actionsSubject.send(.forceLogout)
            }
        }
        .store(in: &cancellables)

        coordinator.handleAppRoute(.settings, animated: false)

        if detached {
            flowParameters.windowManager.registerCoordinator(navigationStackCoordinator,
                                                             flowCoordinator: coordinator,
                                                             forWindowType: .settings)
        } else {
            settingsFlowCoordinator = coordinator

            navigationTabCoordinator.setSheetCoordinator(navigationStackCoordinator) { [weak self] in
                self?.stateMachine.tryEvent(.dismissedSettingsScreen)
            }
        }
    }

    // MARK: - Session Verification

    private func setupSessionVerificationRequestsObserver() {
        userSession.clientProxy.sessionVerificationController?.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self, case .receivedVerificationRequest(let details) = action else {
                    return
                }

                MXLog.info("Received session verification request")

                if details.senderProfile.userID == userSession.clientProxy.userID {
                    presentSessionVerificationScreen(flow: .deviceResponder(requestDetails: details))
                } else {
                    presentSessionVerificationScreen(flow: .userResponder(requestDetails: details))
                }
            }
            .store(in: &cancellables)
    }

    private func presentSessionVerificationScreen(flow: SessionVerificationScreenFlow) {
        guard let sessionVerificationController = userSession.clientProxy.sessionVerificationController else {
            fatalError("The sessionVerificationController should aways be valid at this point")
        }

        let navigationStackCoordinator = NavigationStackCoordinator()

        let parameters = SessionVerificationScreenCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController,
                                                                        flow: flow,
                                                                        appSettings: flowParameters.appSettings,
                                                                        mediaProvider: userSession.mediaProvider)

        let coordinator = SessionVerificationScreenCoordinator(parameters: parameters)

        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .done:
                    self?.navigationTabCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)

        navigationStackCoordinator.setRootCoordinator(coordinator)

        navigationTabCoordinator.setSheetCoordinator(navigationStackCoordinator)
    }

    // MARK: - Calls

    private func beginCallPresentationRequest() -> UUID {
        let requestID = UUID()
        callPresentationRequestID = requestID
        return requestID
    }

    private func presentCallScreen(roomID: String,
                                   isVoiceCall: Bool,
                                   playConnectedTone: Bool? = nil,
                                   incomingCallIdentity: ElementCallIncomingCallIdentity? = nil,
                                   requestID: UUID) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            MXLog.warning("[JunchatCall] presentCallScreen failed: room not joined")
            if callPresentationRequestID == requestID, let incomingCallIdentity {
                flowParameters.elementCallService.clearAcceptedIncomingCall(incomingCallIdentity: incomingCallIdentity)
            }
            return
        }

        guard callPresentationRequestID == requestID else {
            MXLog.info("[JunchatCall] ignoring superseded call presentation request")
            return
        }

        if let incomingCallIdentity,
           flowParameters.elementCallService.acceptedIncomingCallIdentity != incomingCallIdentity {
            MXLog.info("[JunchatCall] ignoring superseded accepted call presentation")
            return
        }

        let shouldPlayConnectedTone = playConnectedTone ?? (incomingCallIdentity == nil)
        let callPresentationDetails = [
            "voice=\(isVoiceCall)",
            "playConnectedTone=\(shouldPlayConnectedTone)",
            "explicit=\(playConnectedTone != nil)",
            "acceptedIncoming=\(incomingCallIdentity != nil)"
        ].joined(separator: " ")
        MXLog.info("[JunchatCall] presentCallScreen request \(callPresentationDetails)")
        await presentCallScreen(roomProxy: roomProxy,
                                voiceOnly: isVoiceCall,
                                playConnectedTone: shouldPlayConnectedTone,
                                incomingCallIdentity: incomingCallIdentity,
                                requestID: requestID)
    }

    private func presentCallScreen(roomProxy: JoinedRoomProxyProtocol,
                                   voiceOnly: Bool,
                                   playConnectedTone: Bool = true,
                                   incomingCallIdentity: ElementCallIncomingCallIdentity? = nil,
                                   requestID: UUID) async {
        guard callPresentationRequestID == requestID else {
            MXLog.info("[JunchatCall] ignoring superseded call presentation request")
            return
        }

        MXLog.info("[JunchatCall] presentCallScreen roomProxy voice=\(voiceOnly) playConnectedTone=\(playConnectedTone)")
        let colorScheme: ColorScheme = flowParameters.windowManager.mainWindow?.traitCollection.userInterfaceStyle == .light ? .light : .dark
        await presentCallScreen(configuration: .init(roomProxy: roomProxy,
                                                     clientProxy: userSession.clientProxy,
                                                     clientID: InfoPlistReader.main.bundleIdentifier,
                                                     elementCallBaseURL: flowParameters.appSettings.elementCallBaseURL,
                                                     elementCallBaseURLOverride: flowParameters.appSettings.elementCallBaseURLOverride,
                                                     voiceOnly: voiceOnly,
                                                     colorScheme: colorScheme,
                                                     playConnectedTone: playConnectedTone,
                                                     incomingCallIdentity: incomingCallIdentity),
                                requestID: requestID)
    }

    private weak var callScreenCoordinator: (any CallScreenCoordinatorProtocol)?
    private var callScreenCoordinatorCancellable: AnyCancellable?

    private var isCallScreenOverlayPresented: Bool {
        guard let callScreenCoordinator else { return false }
        return navigationTabCoordinator.overlayCoordinator === callScreenCoordinator
    }

    private func updateIncomingCallOverlay(rooms: [RoomSummary],
                                           ongoingCallRoomID: String?,
                                           pendingIncomingCallIdentity: ElementCallIncomingCallIdentity?) {
        guard let candidate = globalIncomingCallPresentation.candidate(from: rooms,
                                                                       ongoingCallRoomID: ongoingCallRoomID,
                                                                       pendingIncomingCallIdentity: pendingIncomingCallIdentity,
                                                                       ownUserID: userSession.clientProxy.userID) else {
            incomingCallOverlayRequestID = nil
            if pendingIncomingCallIdentity != nil || ongoingCallRoomID != nil {
                MXLog.info("[JunchatCall] no incoming overlay candidate hasPending=\(pendingIncomingCallIdentity != nil) hasOngoing=\(ongoingCallRoomID != nil) roomsWithCall=\(rooms.filter(\.hasOngoingCall).count)")
            }
            dismissIncomingCallOverlayIfNeeded()
            return
        }

        MXLog.info("[JunchatCall] incoming overlay candidate voice=\(candidate.isVoiceCall)")

        guard candidate.roomID != presentedIncomingCallRoomID ||
            candidate.incomingCallIdentity != presentedIncomingCallIdentity ||
            !(navigationTabCoordinator.overlayCoordinator is IncomingCallScreenCoordinator) else {
            return
        }

        let requestID = UUID()
        incomingCallOverlayRequestID = requestID
        Task { await presentIncomingCallOverlay(candidate, requestID: requestID) }
    }

    private func presentIncomingCallOverlay(_ candidate: GlobalIncomingCallCandidate, requestID: UUID) async {
        guard incomingCallOverlayRequestID == requestID else { return }

        await stopPresentedCallScreenForReplacementIfNeeded()

        guard incomingCallOverlayRequestID == requestID,
              isCurrentIncomingCallCandidate(candidate),
              callScreenCoordinator == nil else {
            return
        }

        incomingCallOverlayCancellables.removeAll()

        let coordinator = IncomingCallScreenCoordinator(parameters: .init(candidate: candidate,
                                                                          mediaProvider: userSession.mediaProvider))
        coordinator.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .accept(let candidate):
                    guard isPresentedIncomingCallCandidate(candidate) else { return }
                    MXLog.info("[JunchatCall] incoming overlay accepted voice=\(candidate.isVoiceCall)")
                    acceptIncomingCallCandidate(candidate)
                case .decline(let candidate):
                    guard isPresentedIncomingCallCandidate(candidate) else { return }
                    MXLog.info("[JunchatCall] incoming overlay declined")
                    globalIncomingCallPresentation.dismiss(candidate)
                    dismissIncomingCallOverlayIfNeeded()
                    Task {
                        if let incomingCallIdentity = candidate.incomingCallIdentity {
                            await self.flowParameters.elementCallService.declineIncomingCall(incomingCallIdentity: incomingCallIdentity)
                        } else {
                            await self.flowParameters.elementCallService.declineIncomingCall(roomID: candidate.roomID)
                        }
                    }
                }
            }
            .store(in: &incomingCallOverlayCancellables)

        presentedIncomingCallRoomID = candidate.roomID
        presentedIncomingCallIdentity = candidate.incomingCallIdentity
        navigationTabCoordinator.setOverlayCoordinator(coordinator, animated: true)

        #if DEBUG
        autoAcceptIncomingCallForDebugIfNeeded(candidate)
        #endif
    }

    private func acceptIncomingCallCandidate(_ candidate: GlobalIncomingCallCandidate) {
        globalIncomingCallPresentation.dismiss(candidate)
        dismissIncomingCallOverlayIfNeeded()
        Task {
            guard let acceptedIncomingCallIdentity = await flowParameters.elementCallService.acceptIncomingCall(roomID: candidate.roomID,
                                                                                                                isVoiceCall: candidate.isVoiceCall,
                                                                                                                incomingCallIdentity: candidate.incomingCallIdentity) else {
                return
            }
            let requestID = beginCallPresentationRequest()
            await presentCallScreen(roomID: candidate.roomID,
                                    isVoiceCall: candidate.isVoiceCall,
                                    playConnectedTone: false,
                                    incomingCallIdentity: acceptedIncomingCallIdentity,
                                    requestID: requestID)
        }
    }

    #if DEBUG
    private func autoAcceptIncomingCallForDebugIfNeeded(_ candidate: GlobalIncomingCallCandidate) {
        let configuredRoomID = ProcessInfo.processInfo.environment["JUNCHAT_DEBUG_AUTO_ACCEPT_INCOMING_CALL_ROOM_ID"]
        guard configuredRoomID == "*" || configuredRoomID == candidate.roomID else { return }

        MXLog.info("[JunchatCall] DEBUG auto-accept incoming overlay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isPresentedIncomingCallCandidate(candidate) else { return }
            self.acceptIncomingCallCandidate(candidate)
        }
    }
    #endif

    private func dismissIncomingCallOverlayIfNeeded() {
        incomingCallOverlayRequestID = nil
        guard navigationTabCoordinator.overlayCoordinator is IncomingCallScreenCoordinator else {
            presentedIncomingCallRoomID = nil
            presentedIncomingCallIdentity = nil
            incomingCallOverlayCancellables.removeAll()
            return
        }

        presentedIncomingCallRoomID = nil
        presentedIncomingCallIdentity = nil
        incomingCallOverlayCancellables.removeAll()
        navigationTabCoordinator.setOverlayCoordinator(nil)
    }

    private func dismissIncomingCallOverlayIfNeeded(matching incomingCallIdentity: ElementCallIncomingCallIdentity) {
        guard presentedIncomingCallIdentity == incomingCallIdentity else { return }
        dismissIncomingCallOverlayIfNeeded()
    }

    private func isPresentedIncomingCallCandidate(_ candidate: GlobalIncomingCallCandidate) -> Bool {
        guard navigationTabCoordinator.overlayCoordinator is IncomingCallScreenCoordinator,
              presentedIncomingCallRoomID == candidate.roomID else {
            return false
        }

        return presentedIncomingCallIdentity == candidate.incomingCallIdentity
    }

    private func isCurrentIncomingCallCandidate(_ candidate: GlobalIncomingCallCandidate) -> Bool {
        guard let incomingCallIdentity = candidate.incomingCallIdentity else {
            return flowParameters.elementCallService.incomingCallIdentityPublisher.value == nil
        }

        return flowParameters.elementCallService.incomingCallIdentityPublisher.value == incomingCallIdentity
    }

    private func presentCallScreen(configuration: ElementCallConfiguration, requestID: UUID) async {
        guard callPresentationRequestID == requestID else {
            MXLog.info("[JunchatCall] ignoring superseded call presentation request")
            return
        }

        endedCallDismissalWorkItem?.cancel()
        endedCallDismissalWorkItem = nil

        if presentedCallScreenRoomID == configuration.callRoomID,
           presentedCallScreenIncomingCallIdentity == configuration.incomingCallIdentity,
           isCallScreenOverlayPresented {
            MXLog.info("Returning to call while setup is in progress.")
            callScreenCoordinator?.stopPictureInPicture()
            callPresentationRequestID = nil
            return
        }

        if flowParameters.ongoingCallRoomIDPublisher.value == configuration.callRoomID {
            if !isCallScreenOverlayPresented {
                MXLog.warning("[JunchatCall] rebuilding missing call overlay for ongoing call")
            }
        }

        await stopPresentedCallScreenForReplacementIfNeeded()

        guard callPresentationRequestID == requestID else {
            MXLog.info("[JunchatCall] replacement call was superseded during teardown")
            return
        }

        if let incomingCallIdentity = configuration.incomingCallIdentity,
           flowParameters.elementCallService.acceptedIncomingCallIdentity != incomingCallIdentity {
            MXLog.info("[JunchatCall] accepted call was superseded during teardown")
            return
        }

        guard callScreenCoordinator == nil else { return }

        MXLog.info("[JunchatCall] presenting call overlay voice=\(configuration.voiceOnly) playConnectedTone=\(configuration.playConnectedTone)")

        let callScreenCoordinator = callScreenCoordinatorFactory(.init(elementCallService: flowParameters.elementCallService,
                                                                       configuration: configuration,
                                                                       allowPictureInPicture: true,
                                                                       appSettings: flowParameters.appSettings,
                                                                       appHooks: flowParameters.appHooks,
                                                                       analytics: flowParameters.analytics))

        callScreenCoordinatorCancellable = callScreenCoordinator.actions
            .sink { [weak self, weak callScreenCoordinator] action in
                guard let self,
                      let callScreenCoordinator,
                      self.callScreenCoordinator === callScreenCoordinator,
                      navigationTabCoordinator.overlayCoordinator === callScreenCoordinator else {
                    return
                }
                switch action {
                case .pictureInPictureStarted:
                    MXLog.info("Hiding call for PiP presentation.")
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .pictureInPictureStopped:
                    MXLog.info("Restoring call after PiP presentation.")
                    navigationTabCoordinator.setOverlayPresentationMode(.fullScreen)
                case .dismiss:
                    clearPresentedCallScreenState()
                    navigationTabCoordinator.setOverlayCoordinator(nil)
                }
            }

        presentedCallScreenRoomID = configuration.callRoomID
        presentedCallScreenIncomingCallIdentity = configuration.incomingCallIdentity
        presentedCallScreenStartedAt = Date()
        callScreenHasSeenRemoteParticipant = false
        self.callScreenCoordinator = callScreenCoordinator
        callPresentationRequestID = nil
        navigationTabCoordinator.setOverlayCoordinator(callScreenCoordinator, animated: true)

        flowParameters.analytics.track(screen: .RoomCall)
    }

    func hideCallScreenOverlay() {
        guard let callScreenCoordinator else {
            MXLog.warning("Picture in picture isn't available, keeping the call screen visible.")
            return
        }

        Task { [weak self, weak callScreenCoordinator] in
            guard let self, let callScreenCoordinator else { return }

            MXLog.info("Starting picture in picture to hide the call screen overlay.")
            guard case .success = await callScreenCoordinator.requestPictureInPicture(),
                  self.callScreenCoordinator === callScreenCoordinator else {
                MXLog.warning("Picture in picture did not start, keeping the call screen visible.")
                return
            }
            MXLog.info("Picture in picture hide request completed; delegate controls overlay presentation.")
        }
    }

    private func stopPresentedCallScreenForReplacementIfNeeded() async {
        guard let existingCallScreenCoordinator = callScreenCoordinator, isCallScreenOverlayPresented else { return }

        MXLog.info("[JunchatCall] waiting for the previous call to finish teardown")
        await existingCallScreenCoordinator.stopAndWaitForTeardown()
        guard callScreenCoordinator === existingCallScreenCoordinator else { return }

        clearPresentedCallScreenState()
        if navigationTabCoordinator.overlayCoordinator === existingCallScreenCoordinator {
            navigationTabCoordinator.setOverlayCoordinator(nil)
        }
    }

    private func dismissCallScreenIfNeeded(matching roomID: String? = nil) async {
        if let roomID, presentedCallScreenRoomID != roomID {
            return
        }

        guard let callScreenCoordinator, isCallScreenOverlayPresented else {
            clearPresentedCallScreenState()
            return
        }

        await callScreenCoordinator.stopAndWaitForTeardown()
        guard self.callScreenCoordinator === callScreenCoordinator else { return }

        clearPresentedCallScreenState()
        if navigationTabCoordinator.overlayCoordinator === callScreenCoordinator {
            navigationTabCoordinator.setOverlayCoordinator(nil)
        }
    }

    private func dismissEndedCallScreenIfNeeded(rooms: [RoomSummary], ongoingCallRoomID: String?) {
        guard let presentedCallScreenRoomID,
              ongoingCallRoomID == presentedCallScreenRoomID,
              isCallScreenOverlayPresented,
              let room = rooms.first(where: { $0.id == presentedCallScreenRoomID }) else {
            return
        }

        let remoteCallParticipants = room.activeRoomCallParticipants.filter { $0 != userSession.clientProxy.userID }
        let hasActiveCall = room.hasOngoingCall && !remoteCallParticipants.isEmpty
        if hasActiveCall {
            callScreenHasSeenRemoteParticipant = true
            endedCallDismissalWorkItem?.cancel()
            endedCallDismissalWorkItem = nil
            return
        }

        let initialSyncGracePeriod: TimeInterval = 8
        let callScreenAge = presentedCallScreenStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if !callScreenHasSeenRemoteParticipant, callScreenAge < initialSyncGracePeriod {
            endedCallDismissalWorkItem?.cancel()
            endedCallDismissalWorkItem = nil
            let initialSyncDetails = [
                "participantCount=\(room.activeRoomCallParticipants.count)",
                "includesOwnUser=\(room.activeRoomCallParticipants.contains(userSession.clientProxy.userID))",
                "age=\(String(format: "%.2f", callScreenAge))s"
            ].joined(separator: " ")
            MXLog.info("[JunchatCall] keeping call overlay during initial membership sync \(initialSyncDetails)")
            return
        }

        guard endedCallDismissalWorkItem == nil else { return }

        let roomID = presentedCallScreenRoomID
        let dismissalDelay = callScreenHasSeenRemoteParticipant ? 1.0 : 2.0
        let dismissalDetails = [
            "participantCount=\(room.activeRoomCallParticipants.count)",
            "includesOwnUser=\(room.activeRoomCallParticipants.contains(userSession.clientProxy.userID))",
            "hasSeenRemote=\(callScreenHasSeenRemoteParticipant)",
            "delay=\(dismissalDelay)s"
        ].joined(separator: " ")
        MXLog.info("[JunchatCall] scheduling call overlay dismissal after inactive room summary \(dismissalDetails)")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.presentedCallScreenRoomID == roomID,
                  self.flowParameters.ongoingCallRoomIDPublisher.value == roomID,
                  self.isCallScreenOverlayPresented else {
                return
            }

            MXLog.info("[JunchatCall] dismissing call overlay because room stayed inactive")
            self.flowParameters.elementCallService.tearDownCallSession()
            Task { await self.dismissCallScreenIfNeeded() }
        }
        endedCallDismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissalDelay, execute: workItem)
    }

    private func clearPresentedCallScreenState() {
        endedCallDismissalWorkItem?.cancel()
        endedCallDismissalWorkItem = nil
        presentedCallScreenRoomID = nil
        presentedCallScreenIncomingCallIdentity = nil
        presentedCallScreenStartedAt = nil
        callScreenHasSeenRemoteParticipant = false
        callScreenCoordinatorCancellable = nil
        callScreenCoordinator = nil
    }

    // MARK: - Logout

    private func runLogoutFlow() async {
        let secureBackupController = userSession.clientProxy.secureBackupController

        guard case let .success(isLastDevice) = await userSession.clientProxy.isOnlyDeviceLeft() else {
            navigationRootCoordinator.alertInfo = .init(id: .init())
            return
        }

        guard isLastDevice else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutConfirmationDialogTitle,
                                                        message: L10n.screenSignoutConfirmationDialogContent,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        })
            return
        }

        guard secureBackupController.recoveryState.value == .enabled else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutRecoveryDisabledTitle,
                                                        message: L10n.screenSignoutRecoveryDisabledSubtitle,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                            self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                        })
            return
        }

        guard secureBackupController.keyBackupState.value == .enabled else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutKeyBackupDisabledTitle,
                                                        message: L10n.screenSignoutKeyBackupDisabledSubtitle,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                            self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                        })
            return
        }

        presentSecureBackupLogoutConfirmationScreen()
    }

    private func presentSecureBackupLogoutConfirmationScreen() {
        let coordinator = SecureBackupLogoutConfirmationScreenCoordinator(parameters: .init(secureBackupController: userSession.clientProxy.secureBackupController,
                                                                                            homeserverReachabilityPublisher: userSession.clientProxy.homeserverReachabilityPublisher))

        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .cancel:
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .settings:
                    chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .logout:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)

        navigationTabCoordinator.setSheetCoordinator(coordinator, animated: true)
    }
}
