//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import NotificationCenter
import Testing

@MainActor
final class NotificationManagerTests {
    var notificationManager: NotificationManager!
    private let clientProxy = ClientProxyMock(.init(userID: "@test:user.net"))
    private lazy var mockUserSession = UserSessionMock(.init(clientProxy: clientProxy))
    private var notificationCenter: UserNotificationCenterMock!
    private var authorizationStatusWasGranted = false
    private var shouldDisplayInAppNotificationReturnValue = false
    private var handleInlineReplyDelegateCalled = false
    private var notificationTappedDelegateCalled = false
    private var registerForRemoteNotificationsDelegateCalled: (() -> Void)?
    
    private var appSettings: AppSettings {
        ServiceLocator.shared.settings
    }

    init() async {
        AppSettings.resetAllSettings()
        notificationCenter = UserNotificationCenterMock()
        notificationCenter.requestAuthorizationOptionsReturnValue = true
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationCenter.deliveredNotificationsReturnValue = []
        notificationCenter.notificationSettingsClosure = { await UNUserNotificationCenter.current().notificationSettings() }
        
        notificationManager = NotificationManager(notificationCenter: notificationCenter, appSettings: appSettings)
        notificationManager.start()
        await waitForConfirmation("initial session tasks should finish", timeout: .seconds(10)) { confirm in
            notificationCenter.notificationSettingsClosure = {
                confirm()
                return await UNUserNotificationCenter.current().notificationSettings()
            }
            notificationManager.setUserSession(mockUserSession)
        }
        notificationCenter.setBadgeCountClosure = nil
        notificationCenter.notificationSettingsClosure = { await UNUserNotificationCenter.current().notificationSettings() }
        notificationCenter.setBadgeCountCallsCount = 0
    }
    
    deinit {
        notificationCenter = nil
        notificationManager = nil
    }
    
    @Test
    func whenRegistered_pusherIsCalled() async {
        _ = await notificationManager.register(with: Data())
        
        #expect(clientProxy.setPusherWithCalled)
        #expect(!clientProxy.junchatBadgeSnapshotCalled)
    }

    @Test
    func orderedBackgroundBadgesRejectOldClearsWithoutRequiringRestoredSession() async throws {
        notificationManager = NotificationManager(notificationCenter: notificationCenter,
                                                  appSettings: appSettings, orderedBadgeSnapshotsEnabled: true)
        let userID = clientProxy.userID
        let ledger = appSettings.notificationBadgeRoomLedger
        ledger.prepare(for: userID)
        let state: [String: Any] = ["user_id": userID,
                                    "generation": "16a85460-6ed5-4cf9-ae72-f53689a2f831", "revision": "1"]
        let initial = try #require(NotificationBadgeServerSnapshot(payload: ["badge_total": 1, "junchat_badge_state": state]))
        _ = ledger.reconcileServerSnapshot(initial, expectedGeneration: nil)
        var newer = state
        newer["revision"] = "3"
        #expect(await notificationManager.handleBackgroundBadgeSnapshot(["badge_total": 4, "junchat_badge_state": newer]))
        #expect(notificationCenter.setBadgeCountReceivedCount == 4)
        #expect(await notificationManager.handleBackgroundBadgeSnapshot(["badge_total": 0, "junchat_badge_state": state]))
        #expect(notificationCenter.setBadgeCountReceivedCount == 4)
        ledger.reset()
        #expect(await notificationManager.handleBackgroundBadgeSnapshot(["badge_total": 4, "junchat_badge_state": newer]) == false)
    }

    @Test
    func registrationOnlyOptsInAfterAuthenticatedSnapshot() async throws {
        notificationManager = NotificationManager(notificationCenter: notificationCenter,
                                                  appSettings: appSettings, orderedBadgeSnapshotsEnabled: true)
        clientProxy.junchatBadgeSnapshotReturnValue = try #require(NotificationBadgeServerSnapshot(payload: [
            "badge_total": 4, "junchat_badge_state": ["user_id": clientProxy.userID,
                                                      "generation": "16a85460-6ed5-4cf9-ae72-f53689a2f831", "revision": "1"]
        ]))
        notificationManager.setUserSession(mockUserSession)
        #expect(await notificationManager.register(with: Data()))
        let configuration = try #require(clientProxy.setPusherWithReceivedInvocations.last)
        guard case .http(let data) = configuration.kind else {
            Issue.record("Expected HTTP pusher")
            return
        }
        let url = try #require(URL(string: data.url))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "junchat-badge-order", value: "state-v1")))
        #expect(appSettings.notificationBadgeRoomLedger.snapshot(for: clientProxy.userID)?.count == 4)
    }
    
    @Test
    func whenRegisteredSuccess_completionSuccessIsCalled() async {
        let success = await notificationManager.register(with: Data())
        #expect(success)
    }

    @Test
    func whenRegisteredAndPusherThrowsError_completionFalseIsCalled() async {
        enum TestError: Error {
            case someError
        }
        
        clientProxy.setPusherWithThrowableError = TestError.someError
        let success = await notificationManager.register(with: Data())
        #expect(!success)
    }

    @Test
    func whenRegistered_pusherIsCalledWithCorrectValues() async throws {
        let pushkeyData = Data("1234".utf8)
        _ = await notificationManager.register(with: pushkeyData)
        
        guard let configuration = clientProxy.setPusherWithReceivedInvocations.first else {
            Issue.record("Invalid pusher configuration sent")
            return
        }
        
        #expect(configuration.identifiers.pushkey == pushkeyData.base64EncodedString())
        #expect(configuration.identifiers.appId == appSettings.pusherAppID)
        #expect(configuration.appDisplayName == "\(InfoPlistReader.main.bundleDisplayName) (iOS)")
        #expect(configuration.deviceDisplayName == UIDevice.current.name)
        #expect(configuration.profileTag != nil)
        #expect(configuration.lang == Bundle.junchatSimplifiedChineseLocalization)
        guard case let .http(data) = configuration.kind else {
            Issue.record("Http kind expected")
            return
        }
        #expect(data.url == appSettings.pushGatewayNotifyEndpoint.absoluteString)
        #expect(data.format == .eventIdOnly)
        let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                      alert: APSAlert(locKey: "Notification",
                                                                      locArgs: []),
                                                      sound: "junchat-message.caf"),
                                         pusherNotificationClientIdentifier: nil)
        #expect(try data.defaultPayload == (defaultPayload.toJsonString()))
    }

    @Test
    func whenRegisteredAndPusherTagNotSetInSettings_tagGeneratedAndSavedInSettings() async {
        appSettings.pusherProfileTag = nil
        _ = await notificationManager.register(with: Data())
        #expect(appSettings.pusherProfileTag != nil)
    }

    @Test
    func whenRegisteredAndPusherTagIsSetInSettings_tagNotGenerated() async {
        appSettings.pusherProfileTag = "12345"
        _ = await notificationManager.register(with: Data())
        #expect(appSettings.pusherProfileTag == "12345")
    }

    @Test
    func registrationRemovesOnlySupersededPushersForThisInstallation() async throws {
        appSettings.pusherProfileTag = "installation-profile"
        let pushKey = Data("current-token".utf8).base64EncodedString()

        _ = await notificationManager.register(with: Data("current-token".utf8))
        let arguments = try #require(clientProxy.deleteSupersededPushersAppIDPushKeyProfileTagReceivedArguments)

        #expect(arguments.appID == appSettings.pusherAppID)
        #expect(arguments.pushKey == pushKey)
        #expect(arguments.profileTag == "installation-profile")
    }

    @Test
    func registrationRemainsSuccessfulWhenSupersededPusherCleanupFails() async {
        enum TestError: Error {
            case cleanupFailed
        }

        let newToken = Data("new-token".utf8)
        clientProxy.deleteSupersededPushersAppIDPushKeyProfileTagThrowableError = TestError.cleanupFailed

        let success = await notificationManager.register(with: newToken)

        #expect(success)
        #expect(clientProxy.setPusherWithCalled)
        #expect(appSettings.pusherPushKey == newToken.base64EncodedString())
    }

    @Test
    func registeringRotatedTokenDeletesPreviousPusher() async throws {
        appSettings.pusherPushKey = Data("old-token".utf8).base64EncodedString()
        let newToken = Data("new-token".utf8)

        let success = await notificationManager.register(with: newToken)
        let identifiers = try #require(clientProxy.deletePusherIdentifiersReceivedIdentifiers)

        #expect(success)
        #expect(identifiers.pushkey == Data("old-token".utf8).base64EncodedString())
        #expect(identifiers.appId == appSettings.pusherAppID)
        #expect(appSettings.pusherPushKey == newToken.base64EncodedString())
    }

    @Test
    func failedTokenRegistrationKeepsPreviousPusher() async {
        enum TestError: Error {
            case registrationFailed
        }

        let previousPushKey = Data("old-token".utf8).base64EncodedString()
        appSettings.pusherPushKey = previousPushKey
        clientProxy.setPusherWithThrowableError = TestError.registrationFailed

        let success = await notificationManager.register(with: Data("new-token".utf8))

        #expect(!success)
        #expect(!clientProxy.deletePusherIdentifiersCalled)
        #expect(clientProxy.deleteSupersededPushersAppIDPushKeyProfileTagCallsCount == 0)
        #expect(appSettings.pusherPushKey == previousPushKey)
    }

    @Test
    func unregisteringSessionDeletesCurrentPusher() async throws {
        let pushKey = Data("registered-token".utf8).base64EncodedString()
        appSettings.pusherPushKey = pushKey

        await notificationManager.unregisterPusher(for: mockUserSession)
        let identifiers = try #require(clientProxy.deletePusherIdentifiersReceivedIdentifiers)

        #expect(identifiers.pushkey == pushKey)
        #expect(identifiers.appId == appSettings.pusherAppID)
        #expect(appSettings.pusherPushKey == nil)
    }

    @Test
    func whenRemovingNotificationsForFullyReadRoomsAndAllRoomsAreRead_badgeIsCleared() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: false),
            roomSummary(id: "2", hasUnreadMessages: false)
        ], userID: clientProxy.userID)
        
        #expect(notificationCenter.setBadgeCountReceivedCount == 0)
    }

    @Test
    func whenRemovingNotificationsForFullyReadRoomsAndSomeRoomsAreUnread_badgeMatchesUnreadRooms() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: false),
            roomSummary(id: "2", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        
        #expect(notificationCenter.setBadgeCountReceivedCount == 1)
    }

    @Test
    func whenOneRoomHasFourUnreadNotifications_badgeIsFour() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true, unreadNotificationsCount: 4)
        ], userID: clientProxy.userID)

        #expect(notificationCenter.setBadgeCountReceivedCount == 4)
    }

    @Test
    func whenRemovingNotificationsForFullyReadRoomsAndAnInviteIsPending_badgeIncludesTheInvite() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: false),
            roomSummary(id: "2", hasUnreadMessages: false, joinRequestType: .invite(inviter: nil))
        ], userID: clientProxy.userID)

        #expect(notificationCenter.setBadgeCountReceivedCount == 1)
    }

    @Test
    func whenUnreadRoomDoesNotNotify_badgeDoesNotIncludeIt() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true, hasUnreadNotifications: false, isMarkedUnread: true),
            roomSummary(id: "2", hasUnreadMessages: false)
        ], userID: clientProxy.userID)

        #expect(notificationCenter.setBadgeCountReceivedCount == 0)
    }

    @Test
    func whenSynchronizingBadgeCount_badgeMatchesTheReconciledLedger() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true),
            roomSummary(id: "2", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        notificationCenter.setBadgeCountCallsCount = 0

        await notificationManager.synchronizeBadgeCount()

        #expect(notificationCenter.setBadgeCountCallsCount == 1)
        #expect(notificationCenter.setBadgeCountReceivedCount == 2)
    }

    @Test
    func whenLifecycleSynchronizesBadgeCount_staleAuthoritativeCountDoesNotReplaceConfirmedEvents() async throws {
        let ledger = appSettings.notificationBadgeRoomLedger
        _ = ledger.reconcile(userID: clientProxy.userID, unreadRoomIDs: [])
        for eventID in ["$event-1", "$event-2", "$event-3", "$event-4"] {
            _ = ledger.applyNotification(userID: clientProxy.userID,
                                         roomID: "!room:example.org",
                                         eventID: eventID,
                                         contributesToBadge: true,
                                         isAuthoritative: true,
                                         fallback: 1)
        }
        let snapshot = try #require(ledger.snapshot(for: clientProxy.userID))
        #expect(snapshot.count == 4)
        #expect(snapshot.recentAuthoritativeCount == 1)
        notificationCenter.setBadgeCountCallsCount = 0

        await notificationManager.synchronizeBadgeCount()

        #expect(notificationCenter.setBadgeCountCallsCount == 1)
        #expect(notificationCenter.setBadgeCountReceivedCount == 4)
    }

    @Test
    func whenSynchronizingWithoutAnActiveSession_badgeIsNotCleared() async {
        let startupNotificationCenter = UserNotificationCenterMock()
        let startupNotificationManager = NotificationManager(notificationCenter: startupNotificationCenter, appSettings: appSettings)
        startupNotificationManager.start()

        await startupNotificationManager.synchronizeBadgeCount()

        #expect(startupNotificationCenter.setBadgeCountCallsCount == 0)
    }

    @Test
    func whenTheActiveSessionLedgerIsUnavailable_badgeIsNotCleared() async {
        appSettings.notificationBadgeRoomLedger.prepare(for: "@other:user.net")
        notificationCenter.setBadgeCountCallsCount = 0

        await notificationManager.synchronizeBadgeCount()

        #expect(notificationCenter.setBadgeCountCallsCount == 0)
    }

    @Test
    func whenTheActiveSessionLedgerIsNotReconciled_badgeIsNotCleared() async {
        notificationCenter.setBadgeCountCallsCount = 0

        await notificationManager.synchronizeBadgeCount()

        #expect(notificationCenter.setBadgeCountCallsCount == 0)
    }

    @Test
    func whenRestoringTheInitialSession_badgeIsRestoredFromThePersistedLedger() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        let startupNotificationCenter = UserNotificationCenterMock()
        startupNotificationCenter.authorizationStatusReturnValue = .denied
        startupNotificationCenter.notificationSettingsClosure = { await UNUserNotificationCenter.current().notificationSettings() }
        let startupNotificationManager = NotificationManager(notificationCenter: startupNotificationCenter, appSettings: appSettings)
        startupNotificationManager.start()

        await waitForConfirmation("badge should be restored", timeout: .seconds(10)) { confirm in
            startupNotificationCenter.setBadgeCountClosure = { count in
                guard count == 1 else { return }
                confirm()
            }
            startupNotificationManager.setUserSession(mockUserSession)
        }

        #expect(startupNotificationCenter.setBadgeCountReceivedCount == 1)
    }

    @Test
    func whenEnteringBackground_badgeIsResynchronized() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        notificationCenter.setBadgeCountCallsCount = 0

        await waitForConfirmation("badge should be synchronized", timeout: .seconds(10)) { confirm in
            notificationCenter.setBadgeCountClosure = { count in
                guard count == 1 else { return }
                confirm()
            }
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        #expect(notificationCenter.setBadgeCountReceivedCount == 1)
        #expect(notificationCenter.setBadgeCountCallsCount == 1)
    }

    @Test
    func whenBecomingActive_badgeIsResynchronized() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        notificationCenter.setBadgeCountCallsCount = 0

        await waitForConfirmation("badge should be synchronized", timeout: .seconds(10)) { confirm in
            notificationCenter.setBadgeCountClosure = { count in
                guard count == 1 else { return }
                confirm()
            }
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        #expect(notificationCenter.setBadgeCountReceivedCount == 1)
        #expect(notificationCenter.setBadgeCountCallsCount == 1)
    }

    @Test
    func whenOpeningAReconciledUnreadRoom_badgeRemovesTheRoom() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true),
            roomSummary(id: "2", hasUnreadMessages: true)
        ], userID: clientProxy.userID)
        await notificationManager.removeDeliveredMessageNotifications(for: "1")

        #expect(notificationCenter.setBadgeCountReceivedCount == 1)
    }

    @Test
    func staleRoomSnapshotFromAnotherAccountIsIgnored() async {
        await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
            roomSummary(id: "1", hasUnreadMessages: true)
        ], userID: "@stale:user.net")

        #expect(notificationCenter.setBadgeCountCallsCount == 0)
    }

    @Test
    func accountSwitchCorrectsAnInFlightOldAccountBadgeWrite() async throws {
        let (writeStarted, writeStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        var releaseWrite: CheckedContinuation<Void, Never>?
        var shouldSuspend = true
        notificationCenter.setBadgeCountClosure = { count in
            guard count == 1, shouldSuspend else { return }
            shouldSuspend = false
            writeStartedContinuation.yield()
            await withCheckedContinuation { releaseWrite = $0 }
        }

        let oldAccountWrite = Task {
            await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
                roomSummary(id: "1", hasUnreadMessages: true)
            ], userID: clientProxy.userID)
        }
        for await _ in writeStarted {
            break
        }

        let newClientProxy = ClientProxyMock(.init(userID: "@other:user.net"))
        let newUserSession = UserSessionMock(.init(clientProxy: newClientProxy))
        notificationManager.setUserSession(newUserSession)
        releaseWrite?.resume()
        await oldAccountWrite.value
        await Task.yield()

        let lastBadge = try #require(notificationCenter.setBadgeCountReceivedInvocations.last)
        #expect(lastBadge == 0)
    }

    @Test
    func authoritativePushCorrectsAnInFlightAccountSwitchClear() async throws {
        let (clearStarted, clearStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        var releaseClear: CheckedContinuation<Void, Never>?
        var shouldSuspend = true
        notificationCenter.setBadgeCountClosure = { count in
            guard count == 0, shouldSuspend else { return }
            shouldSuspend = false
            clearStartedContinuation.yield()
            await withCheckedContinuation { releaseClear = $0 }
        }

        let newClientProxy = ClientProxyMock(.init(userID: "@other:user.net"))
        let newUserSession = UserSessionMock(.init(clientProxy: newClientProxy))
        notificationManager.setUserSession(newUserSession)
        for await _ in clearStarted {
            break
        }

        _ = appSettings.notificationBadgeRoomLedger.applyNotification(userID: newClientProxy.userID,
                                                                      roomID: "!new:example.org",
                                                                      contributesToBadge: true,
                                                                      isAuthoritative: true,
                                                                      fallback: 1)
        try await notificationCenter.setBadgeCount(1)

        await waitForConfirmation("new account badge should replace the stale clear", timeout: .seconds(10)) { confirm in
            notificationCenter.setBadgeCountClosure = { count in
                guard count == 1 else { return }
                confirm()
            }
            releaseClear?.resume()
        }

        let lastBadge = try #require(notificationCenter.setBadgeCountReceivedInvocations.last)
        #expect(lastBadge == 1)
    }

    @Test
    func sessionRemovalCorrectsAnInFlightOldAccountBadgeWrite() async throws {
        let (writeStarted, writeStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        var releaseWrite: CheckedContinuation<Void, Never>?
        var shouldSuspend = true
        notificationCenter.setBadgeCountClosure = { count in
            guard count == 1, shouldSuspend else { return }
            shouldSuspend = false
            writeStartedContinuation.yield()
            await withCheckedContinuation { releaseWrite = $0 }
        }

        let oldAccountWrite = Task {
            await notificationManager.removeDeliveredNotificationsForFullyReadRooms([
                roomSummary(id: "1", hasUnreadMessages: true)
            ], userID: clientProxy.userID)
        }
        for await _ in writeStarted {
            break
        }

        notificationManager.setUserSession(nil)
        releaseWrite?.resume()
        await oldAccountWrite.value
        await Task.yield()

        let lastBadge = try #require(notificationCenter.setBadgeCountReceivedInvocations.last)
        #expect(lastBadge == 0)
    }

    @Test
    func whenShowLocalNotification_notificationRequestGetsAdded() async throws {
        await notificationManager.showLocalNotification(with: "Title", subtitle: "Subtitle")
        let request = try #require(notificationCenter.addReceivedRequest)
        #expect(request.content.title == "Title")
        #expect(request.content.subtitle == "Subtitle")
    }
    
    @Test
    func whenStart_notificationCategoriesAreSet() {
        let replyAction = UNTextInputNotificationAction(identifier: NotificationConstants.Action.inlineReply,
                                                        title: L10n.actionQuickReply,
                                                        options: [])
        let messageCategory = UNNotificationCategory(identifier: NotificationConstants.Category.message,
                                                     actions: [replyAction],
                                                     intentIdentifiers: [],
                                                     options: [])
        
        let inviteCategory = UNNotificationCategory(identifier: NotificationConstants.Category.invite,
                                                    actions: [],
                                                    intentIdentifiers: [],
                                                    options: [])
        #expect(notificationCenter.setNotificationCategoriesReceivedCategories == [messageCategory, inviteCategory])
    }

    @Test
    func whenStart_delegateIsSet() throws {
        let delegate = try #require(notificationCenter.delegate)
        #expect(delegate.isEqual(notificationManager))
    }

    @Test
    func whenStart_requestAuthorizationCalledWithCorrectParams() async {
        await waitForConfirmation("requestAuthorization should be called", timeout: .seconds(10)) { confirm in
            notificationCenter.requestAuthorizationOptionsClosure = { _ in
                confirm()
                return true
            }
            notificationManager.requestAuthorization()
        }
        #expect(notificationCenter.requestAuthorizationOptionsReceivedOptions == [.alert, .sound, .badge])
    }

    @Test
    func whenStartAndAuthorizationGranted_delegateCalled() async {
        authorizationStatusWasGranted = false
        notificationManager.delegate = self
        await waitForConfirmation("registerForRemoteNotifications delegate function should be called", timeout: .seconds(10)) { confirm in
            registerForRemoteNotificationsDelegateCalled = {
                confirm()
            }
            notificationManager.requestAuthorization()
        }
        #expect(authorizationStatusWasGranted)
    }
    
    @Test
    func whenStartAndAuthorizedAndNotificationDisabled_registerForRemoteNotificationsNotCalled() async throws {
        appSettings.enableNotifications = false
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationManager.delegate = self
        
        notificationManager.setUserSession(UserSessionMock(.init()))
        try await Task.sleep(for: .seconds(1))
        
        #expect(!authorizationStatusWasGranted)
    }
    
    @Test
    func whenStartAndAuthorized_registerForRemoteNotificationsCalled() async {
        appSettings.enableNotifications = true
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationManager.delegate = self
        
        await waitForConfirmation("registerForRemoteNotifications delegate function should be called", timeout: .seconds(10)) { confirm in
            registerForRemoteNotificationsDelegateCalled = {
                confirm()
            }
            notificationManager.setUserSession(UserSessionMock(.init()))
        }
        
        #expect(authorizationStatusWasGranted)
    }

    @Test
    func authorizationCompletingAfterSessionRemovalDoesNotRegisterForRemoteNotifications() async {
        notificationCenter.authorizationStatusReturnValue = .authorized
        notificationManager.delegate = self
        var releaseAuthorization: CheckedContinuation<UNAuthorizationStatus, Never>?

        await waitForConfirmation("authorization check should start", timeout: .seconds(10)) { confirm in
            notificationCenter.authorizationStatusClosure = {
                confirm()
                return await withCheckedContinuation { releaseAuthorization = $0 }
            }
            notificationManager.setUserSession(mockUserSession)
        }

        await waitForConfirmation("session tasks should finish", expectedCount: 2, timeout: .seconds(10)) { confirm in
            notificationCenter.notificationSettingsClosure = {
                confirm()
                return await UNUserNotificationCenter.current().notificationSettings()
            }
            notificationManager.setUserSession(nil)
            guard let releaseAuthorization else {
                Issue.record("Authorization continuation should exist")
                return
            }
            releaseAuthorization.resume(returning: .authorized)
        }

        #expect(!authorizationStatusWasGranted)
    }

    @Test
    func whenWillPresentNotificationsDelegateNotSet_CorrectPresentationOptionsReturned() async throws {
        let archiver = MockCoder(requiringSecureCoding: false)
        let notification = try #require(UNNotification(coder: archiver))
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        #expect(options == [.badge, .sound, .list, .banner])
    }

    @Test
    func whenWillPresentNotificationsDelegateSetAndNotificationsShoudNotBeDisplayed_CorrectPresentationOptionsReturned() async throws {
        shouldDisplayInAppNotificationReturnValue = false
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        #expect(options == [])
    }

    @Test
    func whenWillPresentNotificationsDelegateSetAndNotificationsShoudBeDisplayed_CorrectPresentationOptionsReturned() async throws {
        shouldDisplayInAppNotificationReturnValue = true
        notificationManager.delegate = self

        let notification = try UNNotification.with(userInfo: [AnyHashable: Any]())
        let options = await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), willPresent: notification)
        #expect(options == [.badge, .sound, .list, .banner])
    }

    @Test
    func whenNotificationCenterReceivedResponseInLineReply_delegateIsCalled() async throws {
        handleInlineReplyDelegateCalled = false
        notificationManager.delegate = self
        let response = try UNTextInputNotificationResponse.with(userInfo: [AnyHashable: Any](), actionIdentifier: NotificationConstants.Action.inlineReply)
        await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), didReceive: response)
        #expect(handleInlineReplyDelegateCalled)
    }

    @Test
    func whenNotificationCenterReceivedResponseWithActionIdentifier_delegateIsCalled() async throws {
        notificationTappedDelegateCalled = false
        notificationManager.delegate = self
        let response = try UNTextInputNotificationResponse.with(userInfo: [AnyHashable: Any](), actionIdentifier: UNNotificationDefaultActionIdentifier)
        await notificationManager.userNotificationCenter(UNUserNotificationCenter.current(), didReceive: response)
        #expect(notificationTappedDelegateCalled)
    }
}

extension NotificationManagerTests: @MainActor NotificationManagerDelegate {
    func registerForRemoteNotifications() {
        authorizationStatusWasGranted = true
        registerForRemoteNotificationsDelegateCalled?()
    }
    
    func unregisterForRemoteNotifications() {
        authorizationStatusWasGranted = false
    }
    
    func shouldDisplayInAppNotification(content: UNNotificationContent) -> Bool {
        shouldDisplayInAppNotificationReturnValue
    }
    
    func notificationTapped(content: UNNotificationContent) async {
        notificationTappedDelegateCalled = true
    }
    
    func handleInlineReply(_ service: ElementX.NotificationManagerProtocol, content: UNNotificationContent, replyText: String) async {
        handleInlineReplyDelegateCalled = true
    }
}

private func roomSummary(id: String,
                         hasUnreadMessages: Bool,
                         hasUnreadNotifications: Bool? = nil,
                         unreadNotificationsCount: UInt? = nil,
                         isMarkedUnread: Bool? = nil,
                         joinRequestType: RoomSummary.JoinRequestType? = nil) -> RoomSummary {
    RoomSummary(room: .init(noHandle: .init()),
                id: id,
                joinRequestType: joinRequestType,
                name: id,
                isDirect: false,
                isSpace: false,
                avatarURL: nil,
                heroes: [],
                activeMembersCount: 0,
                lastMessage: nil,
                lastMessageDate: .mock,
                lastMessageState: nil,
                unreadMessagesCount: hasUnreadMessages ? 1 : 0,
                unreadMentionsCount: 0,
                unreadNotificationsCount: unreadNotificationsCount ?? ((hasUnreadNotifications ?? hasUnreadMessages) ? 1 : 0),
                notificationMode: .allMessages,
                canonicalAlias: nil,
                alternativeAliases: [],
                hasOngoingCall: false,
                activeCallIntent: nil,
                isMarkedUnread: isMarkedUnread ?? hasUnreadMessages,
                isFavourite: false,
                isTombstoned: false)
}
