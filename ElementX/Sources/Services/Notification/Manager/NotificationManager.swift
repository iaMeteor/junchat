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
    
    private var userSession: UserSessionProtocol?
    
    private var cancellables = Set<AnyCancellable>()
    private var notificationsEnabled = false
    
    init(notificationCenter: UserNotificationCenterProtocol,
         appSettings: AppSettings) {
        self.notificationCenter = notificationCenter
        self.appSettings = appSettings
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

    func register(with deviceToken: Data) async -> Bool {
        guard let userSession else {
            return false
        }
        return await setPusher(with: deviceToken, clientProxy: userSession.clientProxy)
    }

    func setUserSession(_ userSession: UserSessionProtocol?) {
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
        Task { [weak self] in
            guard let self else { return }

            if let expectedUserID {
                let authorizationStatus = await notificationCenter.authorizationStatus()
                if userSession?.clientProxy.userID == expectedUserID,
                   authorizationStatus == .authorized,
                   appSettings.enableNotifications {
                    await MainActor.run { [weak self] in
                        guard self?.userSession?.clientProxy.userID == expectedUserID else { return }
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
        if let authoritativeCount = snapshot.recentAuthoritativeCount {
            return authoritativeCount
        }
        if snapshot.isReconciled {
            return snapshot.count
        }
        return shouldClearUnreconciledBadge ? 0 : nil
    }

    private func synchronizeBadgeCountAfterLifecycleChange() {
        Task { [weak self] in
            await self?.synchronizeBadgeCountWithActiveSession()
        }
    }
    
    private func removeReceivedWhileOfflineNotification() {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [NotificationServiceExtension.receivedWhileOfflineNotificationID])
    }

    private func setPusher(with deviceToken: Data, clientProxy: ClientProxyProtocol) async -> Bool {
        do {
            let defaultPayload = APNSPayload(aps: APSInfo(mutableContent: 1,
                                                          alert: APSAlert(locKey: "Notification",
                                                                          locArgs: []),
                                                          sound: "junchat-message.caf"),
                                             pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier)

            let configuration = try await PusherConfiguration(identifiers: .init(pushkey: deviceToken.base64EncodedString(),
                                                                                 appId: appSettings.pusherAppID),
                                                              kind: .http(data: .init(url: appSettings.pushGatewayNotifyEndpoint.absoluteString,
                                                                                      format: .eventIdOnly,
                                                                                      defaultPayload: defaultPayload.toJsonString())),
                                                              appDisplayName: "\(InfoPlistReader.main.bundleDisplayName) (iOS)",
                                                              deviceDisplayName: UIDevice.current.name,
                                                              profileTag: pusherProfileTag(),
                                                              lang: Bundle.junchatPreferredLocalizations.first ?? Bundle.junchatSimplifiedChineseLocalization)
            try await clientProxy.setPusher(with: configuration)
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
