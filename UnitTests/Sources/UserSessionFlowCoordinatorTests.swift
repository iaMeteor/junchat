//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDKMocks
import Testing

@MainActor
struct UserSessionFlowCoordinatorTests {
    private var userSessionFlowCoordinator: UserSessionFlowCoordinator!
    private var rootCoordinator: NavigationRootCoordinator!
    private var clientProxy: ClientProxyMock!
    private var elementCallService: ElementCallServiceMock!
    private var userIndicatorController: UserIndicatorControllerMock!
    private let stateMachineFactory = PublishedStateMachineFactory()
    private let callScreenCoordinatorFactory = CallScreenCoordinatorTestFactory()

    private let staticRoomListSubject = CurrentValueSubject<[RoomSummary], Never>([])
    private let ongoingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)
    private let incomingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)
    private let incomingCallIdentitySubject = CurrentValueSubject<ElementCallIncomingCallIdentity?, Never>(nil)
    private let networkReachabilitySubject: CurrentValueSubject<NetworkMonitorReachability, Never> = .init(.reachable)
    private let homeserverReachabilitySubject: CurrentValueSubject<NetworkMonitorReachability, Never> = .init(.reachable)
    private var cancellables = Set<AnyCancellable>()

    private var tabCoordinator: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>? {
        rootCoordinator?.rootCoordinator as? NavigationTabCoordinator
    }

    private var chatsSplitCoordinator: NavigationSplitCoordinator? {
        tabCoordinator?.tabCoordinators.first as? NavigationSplitCoordinator
    }

    private var detailCoordinator: CoordinatorProtocol? {
        chatsSplitCoordinator?.detailCoordinator
    }

    private var detailNavigationStack: NavigationStackCoordinator? {
        detailCoordinator as? NavigationStackCoordinator
    }

    init() async throws {
        AppSettings.resetAllSettings()
        rootCoordinator = NavigationRootCoordinator()

        clientProxy = ClientProxyMock(.init(userID: "hi@bob",
                                            deviceID: "DEVICEID",
                                            roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.homeserverReachabilityPublisher = homeserverReachabilitySubject.asCurrentValuePublisher()
        let staticRoomSummaryProvider = RoomSummaryProviderMock()
        staticRoomSummaryProvider.roomListPublisher = staticRoomListSubject.asCurrentValuePublisher()
        staticRoomSummaryProvider.statePublisher = CurrentValueSubject<RoomSummaryProviderState, Never>(.loaded(totalNumberOfRooms: 0)).asCurrentValuePublisher()
        clientProxy.staticRoomSummaryProvider = staticRoomSummaryProvider

        let networkMonitor = NetworkMonitorMock.default
        networkMonitor.reachabilityPublisher = networkReachabilitySubject.asCurrentValuePublisher()
        let appMediator = AppMediatorMock.default
        appMediator.networkMonitor = networkMonitor

        userIndicatorController = UserIndicatorControllerMock()

        elementCallService = ElementCallServiceMock(.init())
        elementCallService.ongoingCallRoomIDPublisher = ongoingCallRoomIDSubject.asCurrentValuePublisher()
        elementCallService.incomingCallRoomIDPublisher = incomingCallRoomIDSubject.asCurrentValuePublisher()
        elementCallService.incomingCallIdentityPublisher = incomingCallIdentitySubject.asCurrentValuePublisher()

        let flowParameters = CommonFlowParameters(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                  bugReportService: BugReportServiceMock(.init()),
                                                  elementCallService: elementCallService,
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                  emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  appMediator: appMediator,
                                                  appSettings: ServiceLocator.shared.settings,
                                                  appHooks: AppHooks(),
                                                  analytics: ServiceLocator.shared.analytics,
                                                  userIndicatorController: userIndicatorController,
                                                  notificationManager: NotificationManagerMock(),
                                                  stateMachineFactory: stateMachineFactory)

        userSessionFlowCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                                navigationRootCoordinator: rootCoordinator,
                                                                appLockService: AppLockServiceMock(),
                                                                flowParameters: flowParameters,
                                                                verificationPromptDecisionStore: VerificationPromptDecisionStore(userDefaults: AppSettings.sharedUserDefaults),
                                                                callScreenCoordinatorFactory: callScreenCoordinatorFactory.make)

        userSessionFlowCoordinator.start()
    }

    // MARK: Navigation

    @Test
    func initialState() {
        #expect(chatsSplitCoordinator != nil)
        #expect(detailCoordinator == nil)
    }

    @Test
    func homeTabsIncludeContactsBetweenChatsAndSpaces() throws {
        let coordinators = try #require(tabCoordinator?.tabCoordinators)

        #expect(coordinators.count == 3)

        guard coordinators.count == 3 else {
            Issue.record("Expected chats, contacts and spaces tabs.")
            return
        }

        #expect(tabCoordinator?.selectedTab == .chats)
        #expect(coordinators[0] is NavigationSplitCoordinator)
        #expect((coordinators[1] as? NavigationStackCoordinator)?.rootCoordinator is ContactsScreenCoordinator)
        #expect(coordinators[2] is NavigationSplitCoordinator)
    }

    @Test
    func onboardingRequiresIdentityConfirmationUntilPermanentlyHidden() throws {
        let (userDefaults, suiteName) = try makeVerificationPromptUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let decisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let sharedUserDefaults = AppSettings.sharedUserDefaults
        let legacyKey = "hasRunIdentityConfirmationOnboarding"
        let suiteLegacyObject = sharedUserDefaults.object(forKey: legacyKey)
        defer {
            if let suiteLegacyObject {
                sharedUserDefaults.set(suiteLegacyObject, forKey: legacyKey)
            } else {
                sharedUserDefaults.removeObject(forKey: legacyKey)
            }
        }
        sharedUserDefaults.removeObject(forKey: legacyKey)

        do {
            let previousLegacyObject = sharedUserDefaults.object(forKey: legacyKey)
            defer {
                if let previousLegacyObject {
                    sharedUserDefaults.set(previousLegacyObject, forKey: legacyKey)
                } else {
                    sharedUserDefaults.removeObject(forKey: legacyKey)
                }
            }

            let legacyAppSettings = AppSettings()
            legacyAppSettings.hasRunIdentityConfirmationOnboarding = true
            #expect(sharedUserDefaults.object(forKey: legacyKey) as? Bool == true)

            #expect(makeOnboardingFlowCoordinator(userID: "@alice:example.org",
                                                  verificationState: .unverified,
                                                  appSettings: legacyAppSettings,
                                                  decisionStore: decisionStore).shouldStart)

            decisionStore.hidePermanently(for: "@alice:example.org")

            #expect(!makeOnboardingFlowCoordinator(userID: "@alice:example.org",
                                                   verificationState: .unverified,
                                                   decisionStore: decisionStore).shouldStart)
            #expect(makeOnboardingFlowCoordinator(userID: "@bob:example.org",
                                                  verificationState: .unverified,
                                                  decisionStore: decisionStore).shouldStart)
            #expect(!makeOnboardingFlowCoordinator(userID: "@bob:example.org",
                                                   verificationState: .verified,
                                                   decisionStore: decisionStore).shouldStart)
        }

        #expect(sharedUserDefaults.object(forKey: legacyKey) == nil)
    }

    @Test
    func verificationResetShowsPromptUnlessPermanentlyHidden() throws {
        let (userDefaults, suiteName) = try makeVerificationPromptUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let decisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let securityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified,
                                                                                          recoveryState: .enabled))
        let coordinator = makeOnboardingFlowCoordinator(userID: "@alice:example.org",
                                                        verificationState: .verified,
                                                        decisionStore: decisionStore,
                                                        securityStateSubject: securityStateSubject)

        #expect(!coordinator.shouldStart)
        securityStateSubject.send(.init(verificationState: .unverified, recoveryState: .enabled))
        #expect(coordinator.shouldStart)

        decisionStore.hidePermanently(for: "@alice:example.org")
        #expect(!coordinator.shouldStart)
    }

    @Test
    func currentIdentitySkipPersistsTheAccountDecision() throws {
        let (userDefaults, suiteName) = try makeVerificationPromptUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let decisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = makeOnboardingFlowCoordinator(userID: "@alice:example.org",
                                                        verificationState: .unverified,
                                                        decisionStore: decisionStore,
                                                        navigationStackCoordinator: navigationStackCoordinator)

        coordinator.start()
        let identityCoordinator = try #require(navigationStackCoordinator.rootCoordinator as? IdentityConfirmationScreenCoordinator)
        identityCoordinator.send(viewAction: .skip)

        #expect(decisionStore.isPermanentlyHidden(for: "@alice:example.org"))
    }

    @Test
    func staleIdentitySkipAfterVerificationDoesNotAdvanceOnboarding() async throws {
        let (userDefaults, suiteName) = try makeVerificationPromptUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let decisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let appSettings = AppSettings()
        let sharedUserDefaults = AppSettings.sharedUserDefaults
        let legacyKey = "hasRunIdentityConfirmationOnboarding"
        let previousLegacyObject = sharedUserDefaults.object(forKey: legacyKey)
        let previousAnalyticsConsentState = appSettings.analyticsConsentState
        let previousNotificationPermissionsValue = appSettings.hasRunNotificationPermissionsOnboarding
        defer {
            appSettings.analyticsConsentState = previousAnalyticsConsentState
            appSettings.hasRunNotificationPermissionsOnboarding = previousNotificationPermissionsValue
            if let previousLegacyObject {
                sharedUserDefaults.set(previousLegacyObject, forKey: legacyKey)
            } else {
                sharedUserDefaults.removeObject(forKey: legacyKey)
            }
        }

        let securityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unverified,
                                                                                          recoveryState: .enabled))
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = makeOnboardingFlowCoordinator(userID: "@alice:example.org",
                                                        verificationState: .unverified,
                                                        appSettings: appSettings,
                                                        decisionStore: decisionStore,
                                                        securityStateSubject: securityStateSubject,
                                                        navigationStackCoordinator: navigationStackCoordinator)
        var dismissCount = 0
        let actionCancellable = coordinator.actions.sink { action in
            guard case .dismiss = action else { return }
            dismissCount += 1
        }
        let firstDismiss = deferFulfillment(coordinator.actions) { action in
            if case .dismiss = action {
                return true
            }
            return false
        }

        coordinator.start()
        let staleIdentityCoordinator = try #require(navigationStackCoordinator.rootCoordinator as? IdentityConfirmationScreenCoordinator)
        securityStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        try await firstDismiss.fulfill()
        #expect(dismissCount == 1)

        staleIdentityCoordinator.send(viewAction: .skip)

        #expect(dismissCount == 1)
        #expect(!decisionStore.isPermanentlyHidden(for: "@alice:example.org"))
        withExtendedLifetime(actionCancellable) { }
    }

    @Test
    func verificationDecisionSurvivesUserSessionFlowRecreationAndRemainsAccountScoped() async throws {
        let (userDefaults, suiteName) = try makeVerificationPromptUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let decisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let appSettings = AppSettings()
        let previousAnalyticsConsentState = appSettings.analyticsConsentState
        let previousNotificationPermissionsValue = appSettings.hasRunNotificationPermissionsOnboarding
        defer {
            appSettings.analyticsConsentState = previousAnalyticsConsentState
            appSettings.hasRunNotificationPermissionsOnboarding = previousNotificationPermissionsValue
        }
        appSettings.analyticsConsentState = .optedOut
        appSettings.hasRunNotificationPermissionsOnboarding = true

        let firstSecurityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unknown,
                                                                                               recoveryState: .unknown))
        let firstRootCoordinator = NavigationRootCoordinator()
        var firstFlowCoordinator: UserSessionFlowCoordinator? = makeUserSessionFlowCoordinator(userID: "@alice:example.org",
                                                                                               securityStateSubject: firstSecurityStateSubject,
                                                                                               appSettings: appSettings,
                                                                                               decisionStore: decisionStore,
                                                                                               rootCoordinator: firstRootCoordinator)
        let firstTabCoordinator = try #require(firstRootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        let firstPresentation = deferFulfillment(firstTabCoordinator.observe(\.fullScreenCoverCoordinator)) { $0 != nil }

        firstFlowCoordinator?.start()
        firstSecurityStateSubject.send(.init(verificationState: .unverified, recoveryState: .enabled))
        try await firstPresentation.fulfill()

        decisionStore.hidePermanently(for: "@alice:example.org")
        weak var releasedFlowCoordinator = firstFlowCoordinator
        firstFlowCoordinator?.stop()
        firstRootCoordinator.setRootCoordinator(SplashScreenCoordinator())
        firstFlowCoordinator = nil
        #expect(releasedFlowCoordinator == nil)

        let aliceReloginSecurityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unknown,
                                                                                                      recoveryState: .unknown))
        let aliceReloginRootCoordinator = NavigationRootCoordinator()
        let aliceReloginDecisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let aliceReloginFlowCoordinator = makeUserSessionFlowCoordinator(userID: "@alice:example.org",
                                                                         securityStateSubject: aliceReloginSecurityStateSubject,
                                                                         appSettings: appSettings,
                                                                         decisionStore: aliceReloginDecisionStore,
                                                                         rootCoordinator: aliceReloginRootCoordinator)
        let aliceReloginTabCoordinator = try #require(aliceReloginRootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        let unexpectedAlicePresentation = deferFailure(aliceReloginTabCoordinator.observe(\.fullScreenCoverCoordinator),
                                                       timeout: .milliseconds(300)) { $0 != nil }

        aliceReloginFlowCoordinator.start()
        aliceReloginSecurityStateSubject.send(.init(verificationState: .unverified, recoveryState: .enabled))
        try await unexpectedAlicePresentation.fulfill()
        #expect(aliceReloginTabCoordinator.fullScreenCoverCoordinator == nil)

        let bobSecurityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unknown,
                                                                                             recoveryState: .unknown))
        let bobRootCoordinator = NavigationRootCoordinator()
        let bobDecisionStore = VerificationPromptDecisionStore(userDefaults: userDefaults)
        let bobFlowCoordinator = makeUserSessionFlowCoordinator(userID: "@bob:example.org",
                                                                securityStateSubject: bobSecurityStateSubject,
                                                                appSettings: appSettings,
                                                                decisionStore: bobDecisionStore,
                                                                rootCoordinator: bobRootCoordinator)
        let bobTabCoordinator = try #require(bobRootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        let bobPresentation = deferFulfillment(bobTabCoordinator.observe(\.fullScreenCoverCoordinator)) { $0 != nil }

        bobFlowCoordinator.start()
        bobSecurityStateSubject.send(.init(verificationState: .unverified, recoveryState: .enabled))
        try await bobPresentation.fulfill()
    }

    @Test
    mutating func homeTabsIncludeEntertainmentWhenEnabled() async throws {
        ServiceLocator.shared.settings.showEntertainmentTab = true
        try await Task.sleep(for: .milliseconds(100))
        let coordinators = try #require(tabCoordinator?.tabCoordinators)

        #expect(coordinators.count == 4)

        guard coordinators.count == 4 else {
            Issue.record("Expected chats, contacts, entertainment and spaces tabs.")
            return
        }

        #expect(coordinators[0] is NavigationSplitCoordinator)
        #expect((coordinators[1] as? NavigationStackCoordinator)?.rootCoordinator is ContactsScreenCoordinator)
        #expect((coordinators[2] as? NavigationStackCoordinator)?.rootCoordinator is EntertainmentScreenCoordinator)
        #expect(coordinators[3] is NavigationSplitCoordinator)
    }

    @Test
    mutating func settingsPresentation() async throws {
        try await process(route: .settings, expectedUserSessionState: .settingsScreen)
        #expect((tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SettingsScreenCoordinator)
    }

    @Test
    mutating func roomPresentation() async throws {
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(detailCoordinator != nil)
    }

    @Test
    mutating func incomingCallOverlayIsShownEvenWhenViewingTheSameRoom() async throws {
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))

        sendIncomingCall(roomID: "1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1")])
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is IncomingCallScreenCoordinator)
    }

    @Test
    mutating func incomingCallOverlayStaysVisibleWhenSameRoomBecomesOngoingBeforeAccepting() async throws {
        sendIncomingCall(roomID: "1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(tabCoordinator?.overlayCoordinator is IncomingCallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is IncomingCallScreenCoordinator)
    }

    @Test
    mutating func callScreenIsNotDismissedForTransientInactiveRoomSummary() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", hasOngoingCall: false, activeRoomCallParticipants: [])])
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)
        #expect(!elementCallService.tearDownCallSessionCalled)

        staticRoomListSubject.send([incomingCallRoomSummary(id: "1")])
        try await Task.sleep(for: .milliseconds(1200))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)
        #expect(!elementCallService.tearDownCallSessionCalled)
    }

    @Test
    mutating func repeatedSameRoomCallPresentationDuringSetupReusesTheOverlay() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { callScreenCoordinatorFactory.makeCount == 1 }
        let firstCoordinator = tabCoordinator?.overlayCoordinator

        #expect(ongoingCallRoomIDSubject.value == nil)
        #expect(firstCoordinator != nil)

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(callScreenCoordinatorFactory.makeCount == 1)
        #expect(tabCoordinator?.overlayCoordinator === firstCoordinator)
    }

    @Test
    mutating func rapidSameRoomPresentationIsRejectedBeforeRoomLookup() async throws {
        let defaultRoomLookup = try #require(clientProxy.roomForIdentifierClosure)
        let delayedLookup = SuspendedCallRoomLookup()
        clientProxy.roomForIdentifierClosure = { roomID in
            await delayedLookup.wait()
            return await defaultRoomLookup(roomID)
        }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { delayedLookup.hasRequest }
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(50))

        #expect(clientProxy.roomForIdentifierCallsCount == 1)

        delayedLookup.resume()
        try await waitUntil { callScreenCoordinatorFactory.makeCount == 1 }
    }

    @Test
    mutating func acceptedReplacementInSameRoomUsesItsExactIdentity() async throws {
        let firstIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "1", isVoiceCall: true)
        let replacementIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "1", isVoiceCall: true)
        let firstCoordinator = ControllableCallScreenCoordinator()
        let replacementCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.overrideClosure = { parameters in
            parameters.configuration.incomingCallIdentity == firstIdentity ? firstCoordinator : replacementCoordinator
        }

        elementCallService.acceptedIncomingCallIdentity = firstIdentity
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1",
                                                        isVoiceCall: true,
                                                        incomingCallIdentity: firstIdentity),
                                                  animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === firstCoordinator }

        elementCallService.acceptedIncomingCallIdentity = replacementIdentity
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1",
                                                        isVoiceCall: true,
                                                        incomingCallIdentity: replacementIdentity),
                                                  animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === replacementCoordinator }

        #expect(callScreenCoordinatorFactory.makeCount == 2)
        #expect(firstCoordinator.stopCallsCount == 1)
        #expect(replacementCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func supersededCallCoordinatorActionsCannotAffectReplacement() async throws {
        let firstCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.override = firstCoordinator
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === firstCoordinator }

        let replacementCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.override = replacementCoordinator
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "2", isVoiceCall: true), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === replacementCoordinator }

        #expect(firstCoordinator.stopCallsCount == 1)
        #expect(replacementCoordinator.stopCallsCount == 0)
        #expect(tabCoordinator?.overlayAllowsHitTesting == true)

        firstCoordinator.send(.pictureInPictureStarted)
        #expect(tabCoordinator?.overlayAllowsHitTesting == true)

        firstCoordinator.send(.pictureInPictureStopped)
        #expect(tabCoordinator?.overlayAllowsHitTesting == true)

        firstCoordinator.send(.dismiss)
        #expect(tabCoordinator?.overlayCoordinator === replacementCoordinator)
        #expect(replacementCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func replacementCallKeepsExistingOverlayUntilItsTeardownCompletes() async throws {
        let firstCoordinator = ControllableCallScreenCoordinator()
        firstCoordinator.suspendsTeardown = true
        callScreenCoordinatorFactory.override = firstCoordinator
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === firstCoordinator }

        let replacementCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.override = replacementCoordinator
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "2", isVoiceCall: true), animated: false)
        try await waitUntil { firstCoordinator.hasPendingTeardown }

        #expect(tabCoordinator?.overlayCoordinator === firstCoordinator)
        #expect(callScreenCoordinatorFactory.makeCount == 1)

        firstCoordinator.completeTeardown()
        try await waitUntil { tabCoordinator?.overlayCoordinator === replacementCoordinator }

        #expect(firstCoordinator.stopCallsCount == 1)
        #expect(replacementCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func delayedCallRouteLookupCannotReplaceNewerCall() async throws {
        let defaultRoomLookup = try #require(clientProxy.roomForIdentifierClosure)
        let delayedLookup = SuspendedCallRoomLookup()
        clientProxy.roomForIdentifierClosure = { roomID in
            if roomID == "1" {
                await delayedLookup.wait()
            }
            return await defaultRoomLookup(roomID)
        }

        let delayedCoordinator = ControllableCallScreenCoordinator()
        let currentCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.overrideClosure = { parameters in
            parameters.configuration.callRoomID == "1" ? delayedCoordinator : currentCoordinator
        }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { delayedLookup.hasRequest }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "2", isVoiceCall: true), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === currentCoordinator }

        delayedLookup.resume()
        try await Task.sleep(for: .milliseconds(50))

        #expect(tabCoordinator?.overlayCoordinator === currentCoordinator)
        #expect(callScreenCoordinatorFactory.makeCount == 1)
        #expect(delayedCoordinator.stopCallsCount == 0)
        #expect(currentCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func delayedAcceptedCallLookupSupersededByOutgoingCallClearsExactIdentity() async throws {
        let defaultRoomLookup = try #require(clientProxy.roomForIdentifierClosure)
        let delayedLookup = SuspendedCallRoomLookup()
        clientProxy.roomForIdentifierClosure = { roomID in
            if roomID == "1" {
                await delayedLookup.wait()
            }
            return await defaultRoomLookup(roomID)
        }

        let delayedIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "1", isVoiceCall: true)
        let callService = try #require(elementCallService)
        callService.acceptedIncomingCallIdentity = delayedIdentity
        callService.clearAcceptedIncomingCallIncomingCallIdentityClosure = { identity in
            guard callService.acceptedIncomingCallIdentity == identity else { return }
            callService.acceptedIncomingCallIdentity = nil
        }

        let delayedCoordinator = ControllableCallScreenCoordinator()
        let currentCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.overrideClosure = { parameters in
            parameters.configuration.callRoomID == "1" ? delayedCoordinator : currentCoordinator
        }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1",
                                                        isVoiceCall: true,
                                                        incomingCallIdentity: delayedIdentity),
                                                  animated: false)
        try await waitUntil { delayedLookup.hasRequest }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "2", isVoiceCall: false), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === currentCoordinator }

        delayedLookup.resume()
        try await waitUntil { callService.clearAcceptedIncomingCallIncomingCallIdentityCallsCount == 1 }

        #expect(callService.clearAcceptedIncomingCallIncomingCallIdentityReceivedIncomingCallIdentity == delayedIdentity)
        #expect(callService.acceptedIncomingCallIdentity == nil)
        #expect(tabCoordinator?.overlayCoordinator === currentCoordinator)
        #expect(callScreenCoordinatorFactory.makeCount == 1)
        #expect(delayedCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func delayedAcceptedCallLookupCannotClearReplacementAcceptedIdentity() async throws {
        let defaultRoomLookup = try #require(clientProxy.roomForIdentifierClosure)
        let delayedLookup = SuspendedCallRoomLookup()
        clientProxy.roomForIdentifierClosure = { roomID in
            if roomID == "1" {
                await delayedLookup.wait()
            }
            return await defaultRoomLookup(roomID)
        }

        let delayedIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "1", isVoiceCall: true)
        let replacementIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "2", isVoiceCall: false)
        let callService = try #require(elementCallService)
        callService.acceptedIncomingCallIdentity = delayedIdentity
        callService.clearAcceptedIncomingCallIncomingCallIdentityClosure = { identity in
            guard callService.acceptedIncomingCallIdentity == identity else { return }
            callService.acceptedIncomingCallIdentity = nil
        }

        let delayedCoordinator = ControllableCallScreenCoordinator()
        let replacementCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.overrideClosure = { parameters in
            parameters.configuration.incomingCallIdentity == delayedIdentity ? delayedCoordinator : replacementCoordinator
        }

        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1",
                                                        isVoiceCall: true,
                                                        incomingCallIdentity: delayedIdentity),
                                                  animated: false)
        try await waitUntil { delayedLookup.hasRequest }

        callService.acceptedIncomingCallIdentity = replacementIdentity
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "2",
                                                        isVoiceCall: false,
                                                        incomingCallIdentity: replacementIdentity),
                                                  animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === replacementCoordinator }

        delayedLookup.resume()
        try await waitUntil { callService.clearAcceptedIncomingCallIncomingCallIdentityCallsCount == 1 }

        #expect(callService.clearAcceptedIncomingCallIncomingCallIdentityReceivedIncomingCallIdentity == delayedIdentity)
        #expect(callService.acceptedIncomingCallIdentity == replacementIdentity)
        #expect(tabCoordinator?.overlayCoordinator === replacementCoordinator)
        #expect(callScreenCoordinatorFactory.makeCount == 1)
        #expect(delayedCoordinator.stopCallsCount == 0)
    }

    @Test
    mutating func delayedAcceptedCallLookupCannotReplaceNewerIncomingPushOverlay() async throws {
        let defaultRoomLookup = try #require(clientProxy.roomForIdentifierClosure)
        let delayedLookup = SuspendedCallRoomLookup()
        clientProxy.roomForIdentifierClosure = { roomID in
            if roomID == "1" {
                await delayedLookup.wait()
            }
            return await defaultRoomLookup(roomID)
        }

        let acceptedIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "1", isVoiceCall: true)
        elementCallService.acceptedIncomingCallIdentity = acceptedIdentity
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1",
                                                        isVoiceCall: true,
                                                        incomingCallIdentity: acceptedIdentity),
                                                  animated: false)
        try await waitUntil { delayedLookup.hasRequest }

        elementCallService.acceptedIncomingCallIdentity = nil
        let replacementIdentity = ElementCallIncomingCallIdentity(callKitID: UUID(), roomID: "2", isVoiceCall: true)
        incomingCallRoomIDSubject.send("2")
        incomingCallIdentitySubject.send(replacementIdentity)
        staticRoomListSubject.send([incomingCallRoomSummary(id: "2")])
        try await waitUntil { tabCoordinator?.overlayCoordinator is IncomingCallScreenCoordinator }
        let replacementOverlay = tabCoordinator?.overlayCoordinator

        delayedLookup.resume()
        try await Task.sleep(for: .milliseconds(50))

        #expect(tabCoordinator?.overlayCoordinator === replacementOverlay)
        #expect(callScreenCoordinatorFactory.makeCount == 0)
        #expect(incomingCallIdentitySubject.value == replacementIdentity)
    }

    @Test
    mutating func callScreenIsDismissedWhenOnlyOwnCallMembershipRemainsInDirectRoom() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: true, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])])
        try await Task.sleep(for: .milliseconds(100))

        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: true, activeRoomCallParticipants: ["hi@bob"])])
        try await Task.sleep(for: .milliseconds(1500))

        #expect(tabCoordinator?.overlayCoordinator == nil)
        #expect(elementCallService.tearDownCallSessionCalled)
    }

    @Test
    mutating func callScreenIsKeptWhenOnlyOwnCallMembershipRemainsInGroupRoom() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: false, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])])
        try await Task.sleep(for: .milliseconds(100))

        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: false, activeRoomCallParticipants: ["hi@bob"])])
        try await Task.sleep(for: .milliseconds(1500))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)
        #expect(!elementCallService.tearDownCallSessionCalled)
    }

    @Test
    mutating func callScreenIsKeptWhenAGroupCallEndsWithoutTheCreatorBeingJoined() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: false), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: false, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])])
        try await Task.sleep(for: .milliseconds(100))

        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", isDirect: false, hasOngoingCall: false, activeRoomCallParticipants: [])])
        try await Task.sleep(for: .milliseconds(1500))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)
        #expect(!elementCallService.tearDownCallSessionCalled)
    }

    @Test
    mutating func callScreenIsNotDismissedDuringInitialOwnOnlyCallMembershipSync() async throws {
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)

        ongoingCallRoomIDSubject.send("1")
        staticRoomListSubject.send([incomingCallRoomSummary(id: "1", activeRoomCallParticipants: ["hi@bob"])])
        try await Task.sleep(for: .milliseconds(1500))

        #expect(tabCoordinator?.overlayCoordinator is CallScreenCoordinator)
        #expect(!elementCallService.tearDownCallSessionCalled)
    }

    @Test
    mutating func lateHideRequestCannotMinimizeAfterPictureInPictureWillStop() async throws {
        let callScreenCoordinator = ControllableCallScreenCoordinator()
        callScreenCoordinatorFactory.override = callScreenCoordinator
        userSessionFlowCoordinator.handleAppRoute(.call(roomID: "1", isVoiceCall: true), animated: false)
        try await waitUntil { tabCoordinator?.overlayCoordinator === callScreenCoordinator }

        #expect(tabCoordinator?.overlayAllowsHitTesting == true)

        userSessionFlowCoordinator.hideCallScreenOverlay()
        try await waitUntil { callScreenCoordinator.hasPendingPictureInPictureRequest }

        callScreenCoordinator.send(.pictureInPictureStarted)
        #expect(tabCoordinator?.overlayAllowsHitTesting == false)

        callScreenCoordinator.send(.pictureInPictureStopped)
        #expect(tabCoordinator?.overlayAllowsHitTesting == true)

        callScreenCoordinator.completePictureInPictureRequest(with: .success(()))
        try await Task.sleep(for: .milliseconds(50))

        #expect(tabCoordinator?.overlayAllowsHitTesting == true)
    }

    @Test
    mutating func roomPresentationClearsSettings() async throws {
        try await process(route: .settings, expectedUserSessionState: .settingsScreen)
        #expect((tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SettingsScreenCoordinator)
        #expect(detailCoordinator == nil)

        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(detailCoordinator != nil)
    }

    @Test
    mutating func childRoomPresentation() async throws {
        try await process(route: .room(roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        let detailNavigationStack = try #require(detailNavigationStack, "There must be a navigation stack.")
        #expect(detailNavigationStack.rootCoordinator is RoomScreenCoordinator)
        #expect(detailCoordinator != nil)

        let deferred = deferFulfillment(detailNavigationStack.observe(\.stackCoordinators.count)) { $0 == 1 }
        try await process(route: .childRoom(roomID: "2", via: []))
        try await deferred.fulfill()
        #expect(detailNavigationStack.rootCoordinator is RoomScreenCoordinator)
        #expect(detailCoordinator != nil)
        #expect(detailNavigationStack.stackCoordinators.count == 1)
        #expect(detailNavigationStack.stackCoordinators.first is RoomScreenCoordinator)
    }

    @Test
    mutating func shareMediaRouteWithoutRoom() async throws {
        try await process(route: .settings, expectedUserSessionState: .settingsScreen)
        #expect((tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SettingsScreenCoordinator)
        #expect(chatsSplitCoordinator?.sheetCoordinator == nil)

        let sharePayload: ShareExtensionPayload = .mediaFiles(roomID: nil, mediaFiles: [.init(url: .picturesDirectory, suggestedName: nil)])
        try await process(route: .share(sharePayload),
                          expectedUserSessionState: .tabBar,
                          expectedChatsState: .shareExtensionRoomList(sharePayload: sharePayload))
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is RoomSelectionScreenCoordinator)
    }

    @Test
    mutating func shareMediaRouteWithRoom() async throws {
        try await process(route: .event(eventID: "1", roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(chatsSplitCoordinator?.sheetCoordinator == nil)

        let sharePayload: ShareExtensionPayload = .mediaFiles(roomID: "2", mediaFiles: [.init(url: .picturesDirectory, suggestedName: nil)])
        try await process(route: .share(sharePayload),
                          expectedChatsState: .roomList(detailState: .room(roomID: "2")))

        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is MediaUploadPreviewScreenCoordinator)
    }

    @Test
    mutating func shareTextRouteWithoutRoom() async throws {
        try await process(route: .settings, expectedUserSessionState: .settingsScreen)
        #expect((tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SettingsScreenCoordinator)
        #expect(chatsSplitCoordinator?.sheetCoordinator == nil)

        let sharePayload: ShareExtensionPayload = .text(roomID: nil, text: "Important Text")
        try await process(route: .share(sharePayload),
                          expectedUserSessionState: .tabBar,
                          expectedChatsState: .shareExtensionRoomList(sharePayload: sharePayload))
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect((chatsSplitCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is RoomSelectionScreenCoordinator)
    }

    @Test
    mutating func shareTextRouteWithRoom() async throws {
        try await process(route: .event(eventID: "1", roomID: "1", via: []), expectedChatsState: .roomList(detailState: .room(roomID: "1")))
        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(chatsSplitCoordinator?.sheetCoordinator == nil)

        let sharePayload: ShareExtensionPayload = .text(roomID: "2", text: "Important text")
        try await process(route: .share(sharePayload),
                          expectedChatsState: .roomList(detailState: .room(roomID: "2")))

        #expect(detailNavigationStack?.rootCoordinator is RoomScreenCoordinator)
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(chatsSplitCoordinator?.sheetCoordinator == nil, "The media upload sheet shouldn't be shown when sharing text.")
    }

    // MARK: Indicators

    @Test
    func reachabilityIndicators() async throws {
        // Given a flow in its initial state.
        try await Task.sleep(for: .milliseconds(100))

        // Then no reachability indicators should be shown.
        #expect(!userIndicatorController.submitIndicatorDelayCalled)
        #expect(retractReachabilityIndicatorCallsCount == 1) // The initial state removes the indicator.

        // When the homeserver becomes unreachable.
        homeserverReachabilitySubject.send(.unreachable)
        try await Task.sleep(for: .milliseconds(100))

        // Then a server unreachable indicator should be shown.
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 1)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.commonServerUnreachable)
        #expect(retractReachabilityIndicatorCallsCount == 1)

        // When the network also becomes unreachable.
        networkReachabilitySubject.send(.unreachable)
        try await Task.sleep(for: .milliseconds(100))

        // Then the server unreachable indicator should be replaced with an offline indicator.
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 2)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.commonOffline)
        #expect(retractReachabilityIndicatorCallsCount == 1)

        // When the homeserver becomes reachable again.
        homeserverReachabilitySubject.send(.reachable)
        try await Task.sleep(for: .milliseconds(100))

        // Then there should still be an offline indicator (as we don't yet support air-gapped servers on iOS).
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 3)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.commonOffline)
        #expect(retractReachabilityIndicatorCallsCount == 1)

        // When the network becomes reachable again.
        networkReachabilitySubject.send(.reachable)
        try await Task.sleep(for: .milliseconds(100))

        // Then the indicator should be hidden now as everything is back to normal
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 3)
        #expect(retractReachabilityIndicatorCallsCount == 2)
    }

    // MARK: - Helpers

    private mutating func process(route: AppRoute,
                                  expectedUserSessionState: UserSessionFlowCoordinator.State? = nil,
                                  expectedChatsState: ChatsTabFlowCoordinatorStateMachine.State? = nil) async throws {
        let deferredUserSession: DeferredFulfillment<UserSessionFlowCoordinator.State>? = if let expectedUserSessionState {
            deferFulfillment(stateMachineFactory.userSessionFlowStatePublisher.delay(for: .milliseconds(100), scheduler: DispatchQueue.main)) {
                $0 == expectedUserSessionState
            }
        } else {
            nil
        }

        let deferredChatsState: DeferredFulfillment<ChatsTabFlowCoordinatorStateMachine.State>? = if let expectedChatsState {
            deferFulfillment(stateMachineFactory.chatsTabFlowStatePublisher.delay(for: .milliseconds(100), scheduler: DispatchQueue.main)) {
                $0 == expectedChatsState
            }
        } else {
            nil
        }

        userSessionFlowCoordinator.handleAppRoute(route, animated: true)
        try await deferredUserSession?.fulfill()
        try await deferredChatsState?.fulfill()
    }

    private func waitUntil(_ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<100 {
            guard !condition() else { return }
            await Task.yield()
        }

        try #require(condition(), sourceLocation: sourceLocation)
    }

    /// Other services retract indicators, so this filters based on the reachability ID.
    private var retractReachabilityIndicatorCallsCount: Int {
        userIndicatorController
            .retractIndicatorWithIdReceivedInvocations
            .filter { $0 == "io.element.elementx.reachability.notification" }
            .count
    }

    private func incomingCallRoomSummary(id: String,
                                         isDirect: Bool = true,
                                         hasOngoingCall: Bool = true,
                                         activeRoomCallParticipants: [String] = ["@caller:junchat.yyzs120.cn"]) -> RoomSummary {
        RoomSummary(room: RoomSDKMock(),
                    id: id,
                    joinRequestType: nil,
                    name: "测试用户 2",
                    isDirect: isDirect,
                    isSpace: false,
                    avatarURL: nil,
                    heroes: [],
                    activeMembersCount: 2,
                    lastMessage: nil,
                    lastMessageDate: .mock,
                    lastMessageState: nil,
                    unreadMessagesCount: 0,
                    unreadMentionsCount: 0,
                    unreadNotificationsCount: 0,
                    notificationMode: .allMessages,
                    canonicalAlias: nil,
                    alternativeAliases: [],
                    hasOngoingCall: hasOngoingCall,
                    activeCallIntent: .audio,
                    activeRoomCallParticipants: activeRoomCallParticipants,
                    isMarkedUnread: false,
                    isFavourite: false,
                    isTombstoned: false)
    }

    private func sendIncomingCall(roomID: String) {
        incomingCallRoomIDSubject.send(roomID)
        incomingCallIdentitySubject.send(.init(callKitID: UUID(), roomID: roomID, isVoiceCall: true))
    }

    private func makeCommonFlowParameters(userSession: UserSessionProtocol,
                                          appSettings: AppSettings,
                                          elementCallService: ElementCallServiceProtocol? = nil) -> CommonFlowParameters {
        CommonFlowParameters(userSession: userSession,
                             bugReportService: BugReportServiceMock(.init()),
                             elementCallService: elementCallService ?? ElementCallServiceMock(.init()),
                             timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                             emojiProvider: EmojiProvider(appSettings: appSettings),
                             linkMetadataProvider: LinkMetadataProvider(),
                             appMediator: AppMediatorMock.default,
                             appSettings: appSettings,
                             appHooks: AppHooks(),
                             analytics: AnalyticsService(client: AnalyticsClientMock(), appSettings: appSettings),
                             userIndicatorController: UserIndicatorControllerMock(),
                             notificationManager: NotificationManagerMock(),
                             stateMachineFactory: PublishedStateMachineFactory())
    }

    private func makeUserSessionFlowCoordinator(userID: String,
                                                securityStateSubject: CurrentValueSubject<SessionSecurityState, Never>,
                                                appSettings: AppSettings,
                                                decisionStore: VerificationPromptDecisionStoreProtocol,
                                                rootCoordinator: NavigationRootCoordinator) -> UserSessionFlowCoordinator {
        let clientProxy = ClientProxyMock(.init(userID: userID,
                                                deviceID: "DEVICEID",
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.homeserverReachabilityPublisher = homeserverReachabilitySubject.asCurrentValuePublisher()
        let staticRoomSummaryProvider = RoomSummaryProviderMock()
        staticRoomSummaryProvider.roomListPublisher = CurrentValueSubject<[RoomSummary], Never>([]).asCurrentValuePublisher()
        staticRoomSummaryProvider.statePublisher = CurrentValueSubject<RoomSummaryProviderState, Never>(.loaded(totalNumberOfRooms: 0)).asCurrentValuePublisher()
        clientProxy.staticRoomSummaryProvider = staticRoomSummaryProvider

        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        userSession.sessionSecurityStatePublisher = securityStateSubject.asCurrentValuePublisher()

        return UserSessionFlowCoordinator(isNewLogin: false,
                                          navigationRootCoordinator: rootCoordinator,
                                          appLockService: AppLockServiceMock(),
                                          flowParameters: makeCommonFlowParameters(userSession: userSession,
                                                                                   appSettings: appSettings,
                                                                                   elementCallService: elementCallService),
                                          verificationPromptDecisionStore: decisionStore)
    }

    private func makeOnboardingFlowCoordinator(userID: String,
                                               verificationState: SessionVerificationState,
                                               appSettings: AppSettings = AppSettings(),
                                               decisionStore: VerificationPromptDecisionStoreProtocol,
                                               securityStateSubject: CurrentValueSubject<SessionSecurityState, Never>? = nil,
                                               navigationStackCoordinator: NavigationStackCoordinator? = nil) -> OnboardingFlowCoordinator {
        appSettings.analyticsConsentState = .optedOut
        appSettings.hasRunNotificationPermissionsOnboarding = true

        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: userID))))
        let resolvedSecurityStateSubject = securityStateSubject ?? .init(.init(verificationState: verificationState,
                                                                               recoveryState: .enabled))
        let resolvedNavigationStackCoordinator = navigationStackCoordinator ?? NavigationStackCoordinator()
        userSession.sessionSecurityStatePublisher = resolvedSecurityStateSubject.asCurrentValuePublisher()

        return OnboardingFlowCoordinator(isNewLogin: false,
                                         appLockService: AppLockServiceMock(),
                                         navigationStackCoordinator: resolvedNavigationStackCoordinator,
                                         flowParameters: makeCommonFlowParameters(userSession: userSession,
                                                                                  appSettings: appSettings),
                                         verificationPromptDecisionStore: decisionStore)
    }

    private func makeVerificationPromptUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "io.element.elementx.onboarding-verification-tests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }
}

@MainActor
private final class CallScreenCoordinatorTestFactory {
    var override: (any CallScreenCoordinatorProtocol)?
    var overrideClosure: ((CallScreenCoordinatorParameters) -> any CallScreenCoordinatorProtocol)?
    private(set) var makeCount = 0

    func make(parameters: CallScreenCoordinatorParameters) -> any CallScreenCoordinatorProtocol {
        makeCount += 1
        return overrideClosure?(parameters) ?? override ?? CallScreenCoordinator(parameters: parameters)
    }
}

@MainActor
private final class SuspendedCallRoomLookup {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasRequest: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ControllableCallScreenCoordinator: CallScreenCoordinatorProtocol {
    private let actionsSubject = PassthroughSubject<CallScreenCoordinatorAction, Never>()
    private var pictureInPictureRequestContinuation: CheckedContinuation<Result<Void, CallScreenError>, Never>?
    private var teardownContinuation: CheckedContinuation<Void, Never>?
    private var hasStopped = false

    private(set) var stopCallsCount = 0
    var suspendsTeardown = false

    var actions: AnyPublisher<CallScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    var hasPendingPictureInPictureRequest: Bool {
        pictureInPictureRequestContinuation != nil
    }

    var hasPendingTeardown: Bool {
        teardownContinuation != nil
    }

    func requestPictureInPicture() async -> Result<Void, CallScreenError> {
        await withCheckedContinuation { pictureInPictureRequestContinuation = $0 }
    }

    func stopPictureInPicture() { }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        stopCallsCount += 1
    }

    func stopAndWaitForTeardown() async {
        stop()
        guard suspendsTeardown else { return }
        await withCheckedContinuation { teardownContinuation = $0 }
    }

    func send(_ action: CallScreenCoordinatorAction) {
        actionsSubject.send(action)
    }

    func completePictureInPictureRequest(with result: Result<Void, CallScreenError>) {
        pictureInPictureRequestContinuation?.resume(returning: result)
        pictureInPictureRequestContinuation = nil
    }

    func completeTeardown() {
        teardownContinuation?.resume()
        teardownContinuation = nil
    }
}
