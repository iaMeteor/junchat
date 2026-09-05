//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit
import UserNotifications

final class NotificationManager: NSObject, NotificationManagerProtocol {
    private let notificationCenter: UserNotificationCenterProtocol
    private let appSettings: AppSettings
    private let orderedBadgeSnapshotsEnabled: Bool
    @MainActor private var badgeSessionGeneration = UUID()
    @MainActor private var badgeRefreshTask: Task<Void, Never>?
    @MainActor private var pusherDeviceToken: Data?
    @MainActor private var registeredPusher: (deviceToken: Data, endpoint: URL)?
    @MainActor private var pusherRegistrationTask: Task<Bool, Never>?
    @MainActor private var pusherRegistrationID = UUID()
    
    private var userSession: UserSessionProtocol?
    
    private var cancellables = Set<AnyCancellable>()
    private var notificationsEnabled = false
    
    init(notificationCenter: UserNotificationCenterProtocol,
         appSettings: AppSettings,
         orderedBadgeSnapshotsEnabled: Bool = false) {
        self.notificationCenter = notificationCenter
        self.appSettings = appSettings
        self.orderedBadgeSnapshotsEnabled = orderedBadgeSnapshotsEnabled
        super.init()
    }

    // MARK: NotificationManagerProtocol

    weak var delegate: NotificationManagerDelegate?
    
    func start() {
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
        notificationCenter.setNotificationCategories([messageCategory, inviteCategory])
        notificationCenter.delegate = self
        
        notificationsEnabled = appSettings.enableNotifications
        MXLog.info("App setting 'enableNotifications' is '\(notificationsEnabled)'")
        
        // Listen for changes to AppSettings.enableNotifications
        appSettings.$enableNotifications
            .sink { [weak self] newValue in
                self?.enableNotifications(newValue)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                removeReceivedWhileOfflineNotification()
                synchronizeBadgeCountAfterLifecycleChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.synchronizeBadgeCountAfterLifecycleChange()
            }
            .store(in: &cancellables)
    }
    
    func requestAuthorization() {
        guard appSettings.enableNotifications, !userSession.isNil else { return }
        Task {
            do {
                let permissionGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                MXLog.info("Permission granted: \(permissionGranted)")
                await MainActor.run {
                    if permissionGranted {
                        self.delegate?.registerForRemoteNotifications()
                    }
                }
            } catch {
                MXLog.error("Request authorization failed: \(error)")
            }
        }
    }

    @MainActor func register(with deviceToken: Data) async -> Bool {
        guard userSession != nil else { return false }
        let generation = badgeSessionGeneration
        pusherDeviceToken = deviceToken
        registeredPusher = nil
        await refreshServerBadgeSnapshot()
        guard isCurrentRegistration(deviceToken: deviceToken, generation: generation) else { return false }
        return await synchronizePusherRegistration()
    }

    func unregisterPusher(for userSession: UserSessionProtocol) async {
        guard let pushKey = appSettings.pusherPushKey else { return }

        do {
            try await userSession.clientProxy.deletePusher(identifiers: .init(pushkey: pushKey,
                                                                              appId: appSettings.pusherAppID))
            if appSettings.pusherPushKey == pushKey {
                appSettings.pusherPushKey = nil
            }
            MXLog.info("Deleted pusher during session teardown")
        } catch {
            MXLog.error("Failed deleting pusher during session teardown: \(error)")
        }
    }

    @MainActor func setUserSession(_ userSession: UserSessionProtocol?) {
        badgeRefreshTask?.cancel()
        badgeRefreshTask = nil
        badgeSessionGeneration = UUID()
        pusherRegistrationTask?.cancel()
        pusherRegistrationTask = nil
        pusherRegistrationID = UUID()
        pusherDeviceToken = nil
        registeredPusher = nil
        let previousUserID = self.userSession?.clientProxy.userID
        self.userSession = userSession
        let userID = userSession?.clientProxy.userID

        if let userID {
            appSettings.notificationBadgeRoomLedger.prepare(for: userID)
        } else {
            appSettings.notificationBadgeRoomLedger.reset()
        }

        if previousUserID != userID {
            let shouldClearUnreconciledBadge = previousUserID != nil
            Task { [weak self] in
                await self?.synchronizeBadgeCountWithActiveSession(shouldClearUnreconciledBadge: shouldClearUnreconciledBadge)
            }
        }
        
        // If notification permissions were given previously then attempt re-registering
        // for remote notifications on startup. Otherwise let the onboarding flow handle it
        let expectedUserID = userID
        let expectedGeneration = badgeSessionGeneration
        Task { [weak self] in
            guard let self else { return }

            if let expectedUserID {
                let authorizationStatus = await notificationCenter.authorizationStatus()
                if userSession?.clientProxy.userID == expectedUserID,
                   authorizationStatus == .authorized,
                   appSettings.enableNotifications {
                    await MainActor.run { [weak self] in
                        guard self?.badgeSessionGeneration == expectedGeneration,
                              self?.userSession?.clientProxy.userID == expectedUserID else { return }
                        self?.delegate?.registerForRemoteNotifications()
                    }
                }
            }
            
            let settings = await notificationCenter.notificationSettings()
            MXLog.info("Notification settings: authorization=\(settings.authorizationStatus.rawValue), badges=\(settings.badgeSetting == .enabled), sounds=\(settings.soundSetting == .enabled)")
        }
    }

    func registrationFailed(with error: Error) {
        MXLog.error("Device token registration failed with error: \(error)")
    }

    func showLocalNotification(with title: String, subtitle: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        let request = UNNotificationRequest(identifier: ProcessInfo.processInfo.globallyUniqueString,
                                            content: content,
                                            trigger: nil)
        do {
            try await notificationCenter.add(request)
            MXLog.info("Show local notification succeeded")
        } catch {
            MXLog.error("Show local notification failed: \(error)")
        }
    }
    
    func removeDeliveredMessageNotifications(for roomID: String) async {
        guard let userID = userSession?.clientProxy.userID else { return }

        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { $0.request.content.roomID == roomID }
            .map(\.request.identifier)
        guard !Task.isCancelled,
              userSession?.clientProxy.userID == userID else {
            return
        }

        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)

        guard appSettings.notificationBadgeRoomLedger.markRoomRead(userID: userID,
                                                                   roomID: roomID) != nil else {
            return
        }

        await synchronizeBadgeCountWithActiveSession()
    }
    
    func removeDeliveredNotificationsForFullyReadRooms(_ rooms: [RoomSummary], userID: String) async {
        guard userSession?.clientProxy.userID == userID else { return }
        guard rooms.allSatisfy(\.hasLoadedDetails) else {
            // An incomplete SDK list cannot authorize clearing notifications.
            await synchronizeBadgeCountWithActiveSession()
            return
        }

        let roomsToLastMessageDates = rooms
            .filter { $0.hasUnreadMessages == false && $0.joinRequestType?.isInvite != true }
            .reduce(into: [:]) { partialResult, roomSummary in
                partialResult[roomSummary.id] = roomSummary.lastMessageDate
            }
        
        let notificationsIdentifiers = await notificationCenter
            .deliveredNotifications()
            .filter { notification in
                guard let roomID = notification.request.content.roomID,
                      let lastMessageDate = roomsToLastMessageDates[roomID] else {
                    return false
                }
                    
                return notification.date <= lastMessageDate
            }
            .map(\.request.identifier)
        guard !Task.isCancelled,
              userSession?.clientProxy.userID == userID else {
            return
        }

        notificationCenter.removeDeliveredNotifications(withIdentifiers: notificationsIdentifiers)

        let unreadCountsByRoom = rooms.reduce(into: [String: Int]()) { counts, room in
            if room.joinRequestType?.isInvite == true {
                counts[room.id] = 1
            } else if room.unreadNotificationsCount > 0 {
                counts[room.id] = room.unreadNotificationsCount > UInt(Int.max)
                    ? Int.max
                    : Int(room.unreadNotificationsCount)
            }
        }
        guard appSettings.notificationBadgeRoomLedger.reconcile(userID: userID,
                                                                unreadCountsByRoom: unreadCountsByRoom) != nil else {
            return
        }

        await synchronizeBadgeCountWithActiveSession()
    }

    func synchronizeBadgeCount() async {
        await synchronizeBadgeCountWithActiveSession()
    }

    private func synchronizeBadgeCountWithActiveSession(shouldClearUnreconciledBadge: Bool = false) async {
        await refreshServerBadgeSnapshot()
        await synchronizeOrderedPusherRegistration()
        guard userSession?.clientProxy.userID != nil else {
            if shouldClearUnreconciledBadge {
                do {
                    try await notificationCenter.setBadgeCount(0)
                    MXLog.info("Cleared app badge after removing the active user session")
                } catch {
                    MXLog.error("Failed clearing app badge after removing the active user session: \(error)")
                }
                return
            }

            MXLog.info("Skipped app badge synchronization without an active user session")
            return
        }

        var shouldClearStaleBadge = shouldClearUnreconciledBadge
        for _ in 0..<8 {
            let userID = userSession?.clientProxy.userID
            let snapshot: NotificationBadgeSnapshot?
            let badgeCount: Int
            if let userID {
                guard let resolvedSnapshot = appSettings.notificationBadgeRoomLedger.snapshot(for: userID) else {
                    MXLog.error("Skipped app badge synchronization because the ledger snapshot is unavailable")
                    return
                }
                guard let resolvedBadgeCount = resolvedBadgeCount(for: resolvedSnapshot,
                                                                  shouldClearUnreconciledBadge: shouldClearStaleBadge) else {
                    MXLog.info("Skipped app badge synchronization until the room list has reconciled")
                    return
                }
                badgeCount = resolvedBadgeCount
                snapshot = resolvedSnapshot
            } else {
                snapshot = nil
                badgeCount = 0
            }

            do {
                try await notificationCenter.setBadgeCount(badgeCount)
            } catch {
                MXLog.error("Failed synchronizing app badge: \(error)")
                return
            }

            let currentUserID = userSession?.clientProxy.userID
            let currentSnapshot = currentUserID.flatMap { appSettings.notificationBadgeRoomLedger.snapshot(for: $0) }
            if currentUserID == userID, currentSnapshot == snapshot {
                MXLog.info("Synchronized app badge from visible unread rooms: \(badgeCount)")
                return
            }
            shouldClearStaleBadge = true
        }

        MXLog.error("App badge state kept changing during synchronization")
    }

    private func resolvedBadgeCount(for snapshot: NotificationBadgeSnapshot,
                                    shouldClearUnreconciledBadge: Bool) -> Int? {
        if snapshot.isReconciled {
            return snapshot.count
        }
        if let authoritativeCount = snapshot.recentAuthoritativeCount {
            return authoritativeCount
        }
        return shouldClearUnreconciledBadge ? 0 : nil
    }

    @MainActor private func refreshServerBadgeSnapshot() async {
        guard let clientProxy = userSession?.clientProxy,
              orderedBadgeSnapshotsEnabled || appSettings.notificationBadgeRoomLedger.serverSnapshot(for: clientProxy.userID) != nil else { return }
        if let badgeRefreshTask {
            await badgeRefreshTask.value
            return
        }
        let sessionGeneration = badgeSessionGeneration
        let generation = appSettings.notificationBadgeRoomLedger.serverSnapshot(for: clientProxy.userID)?.generation
        let task = Task { [weak self] in
            guard let snapshot = await clientProxy.junchatBadgeSnapshot(),
                  !Task.isCancelled, let self,
                  badgeSessionGeneration == sessionGeneration else { return }
            _ = appSettings.notificationBadgeRoomLedger.reconcileServerSnapshot(snapshot, expectedGeneration: generation)
        }
        badgeRefreshTask = task
        await task.value
        if badgeSessionGeneration == sessionGeneration {
            badgeRefreshTask = nil
        }
    }

    func handleBackgroundBadgeSnapshot(_ payload: [AnyHashable: Any]) async -> Bool {
        let ledger = appSettings.notificationBadgeRoomLedger
        guard let snapshot = NotificationBadgeServerSnapshot(payload: payload),
              ledger.serverSnapshot(for: snapshot.userID) != nil else { return false }
        _ = ledger.applyNotification(userID: snapshot.userID, roomID: nil, contributesToBadge: nil,
                                     isAuthoritative: true, serverSnapshot: snapshot, fallback: nil)
        for _ in 0..<8 {
            guard let current = ledger.snapshot(for: snapshot.userID) else {
                await synchronizeBadgeCountWithActiveSession(shouldClearUnreconciledBadge: true)
                return true
            }
            do {
                try await notificationCenter.setBadgeCount(current.count)
            } catch {
                return false
            }
            if ledger.snapshot(for: snapshot.userID) == current {
                return true
            }
        }
        return false
    }

    private func synchronizeBadgeCountAfterLifecycleChange() {
        Task { [weak self] in
            await self?.synchronizeBadgeCountWithActiveSession()
        }
    }
    
    private func removeReceivedWhileOfflineNotification() {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [NotificationServiceExtension.receivedWhileOfflineNotificationID])
    }

    @MainActor private func synchronizeOrderedPusherRegistration() async {
        guard appSettings.enableNotifications,
              let userID = userSession?.clientProxy.userID,
              appSettings.notificationBadgeRoomLedger.serverSnapshot(for: userID) != nil else { return }
        _ = await synchronizePusherRegistration()
    }

    @MainActor private func synchronizePusherRegistration() async -> Bool {
        guard let deviceToken = pusherDeviceToken, let clientProxy = userSession?.clientProxy else { return false }
        let generation = badgeSessionGeneration
        // Token rotations and a late bootstrap must not finish in reverse order.
        while let pusherRegistrationTask {
            _ = await pusherRegistrationTask.value
            guard isCurrentRegistration(deviceToken: deviceToken, generation: generation) else { return false }
        }
        let endpoint = pushGatewayEndpoint(for: clientProxy.userID)
        if registeredPusher?.deviceToken == deviceToken, registeredPusher?.endpoint == endpoint {
            return true
        }
        let requestID = UUID()
        let task = Task {
            let success = await setPusher(with: deviceToken, clientProxy: clientProxy, endpoint: endpoint, sessionGeneration: generation)
            if badgeSessionGeneration == generation, pusherRegistrationID == requestID {
                pusherRegistrationTask = nil
                if success {
                    registeredPusher = (deviceToken, endpoint)
                }
            }
            return success
        }
        pusherRegistrationID = requestID
        pusherRegistrationTask = task
        let success = await task.value
        return success && isCurrentRegistration(deviceToken: deviceToken, generation: generation)
    }

    @MainActor private func isCurrentRegistration(deviceToken: Data, generation: UUID) -> Bool {
        !Task.isCancelled && badgeSessionGeneration == generation && pusherDeviceToken == deviceToken
    }

    @MainActor private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol,
                                      endpoint: URL, sessionGeneration: UUID) async -> Bool {
        do {
            guard isCurrentRegistration(deviceToken: deviceToken, generation: sessionGeneration) else { return false }
            let pushKey = deviceToken.base64EncodedString()
            let profileTag = pusherProfileTag()
            let previousPushKey = appSettings.pusherPushKey

            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "Notification",
                                                                          locArgs: []),
                                                          sound: "junchat-message.caf"),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: pushKey,
                                                                                 appId: appSettings.pusherAppID),
                                                              kind: .http(data: .init(url: endpoint.absoluteString,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: profileTag,
                                                              lang: Bundle.junchatPreferredLocalizations.first ?? Bundle.junchatSimplifiedChineseLocalization)
            guard isCurrentRegistration(deviceToken: deviceToken, generation: sessionGeneration) else { return false }
            try await clientProxy.setPusher(with: configuration)
            guard isCurrentRegistration(deviceToken: deviceToken, generation: sessionGeneration) else { return false }
            appSettings.pusherPushKey = pushKey

            if let previousPushKey,
               previousPushKey != pushKey {
                do {
                    try await clientProxy.deletePusher(identifiers: .init(pushkey: previousPushKey,
                                                                          appId: appSettings.pusherAppID))
                    MXLog.info("Deleted superseded APNs pusher")
                } catch {
                    MXLog.error("Failed deleting superseded APNs pusher: \(error)")
                }
            }

            guard isCurrentRegistration(deviceToken: deviceToken, generation: sessionGeneration) else { return false }
            do {
                try await clientProxy.deleteSupersededPushers(appID: appSettings.pusherAppID,
                                                              pushKey: pushKey,
                                                              profileTag: profileTag)
            } catch {
                MXLog.error("Failed deleting superseded installation pushers: \(error)")
            }

            guard isCurrentRegistration(deviceToken: deviceToken, generation: sessionGeneration) else { return false }
            MXLog.info("Set pusher succeeded")
            return true
        } catch {
            MXLog.error("Set pusher failed: \(error)")
            return false
        }
    }

    private func pusherProfileTag() -> String {
        if let currentTag = appSettings.pusherProfileTag {
            return currentTag
        }
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let newTag = (0..<16).map { _ in
            let offset = Int.random(in: 0..<chars.count)
            return String(chars[chars.index(chars.startIndex, offsetBy: offset)])
        }.joined()

        appSettings.pusherProfileTag = newTag
        return newTag
    }

    private func pushGatewayEndpoint(for userID: String) -> URL {
        let url = appSettings.pushGatewayNotifyEndpoint
        guard appSettings.notificationBadgeRoomLedger.serverSnapshot(for: userID) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var query = (components.queryItems ?? []).filter { !["junchat-badge", "junchat-badge-order"].contains($0.name) }
        query.append(.init(name: "junchat-badge", value: "messages-v1"))
        query.append(.init(name: "junchat-badge-order", value: "state-v1"))
        components.queryItems = query
        return components.url ?? url
    }
    
    private func enableNotifications(_ enable: Bool) {
        guard notificationsEnabled != enable else { return }
        notificationsEnabled = enable
        MXLog.info("App setting 'enableNotifications' changed to '\(enable)'")
        if enable {
            requestAuthorization()
        } else {
            delegate?.unregisterForRemoteNotifications()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard appSettings.enableInAppNotifications else {
            return []
        }
        guard let delegate else {
            return [.badge, .sound, .list, .banner]
        }

        guard delegate.shouldDisplayInAppNotification(content: notification.request.content) else {
            return []
        }

        return [.badge, .sound, .list, .banner]
    }

    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case NotificationConstants.Action.inlineReply:
            guard let response = response as? UNTextInputNotificationResponse else {
                return
            }
            await delegate?.handleInlineReply(self,
                                              content: response.notification.request.content,
                                              replyText: response.userText)
        case UNNotificationDefaultActionIdentifier:
            await delegate?.notificationTapped(content: response.notification.request.content)
        default:
            break
        }
    }
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol { }
