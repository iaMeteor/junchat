//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Dispatch
import MatrixRustSDK
import UserNotifications

final class NotificationContentCompletion: @unchecked Sendable {
    typealias ContentFinalizer = (UNNotificationContent,
                                  @escaping (UNNotificationContent) -> Void,
                                  @escaping (UNNotificationContent) -> Void) -> Void

    private let lock = NSCondition()
    private var bestAttemptContent: UNNotificationContent?
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var completionHook: (() -> Void)?
    private var contentFinalizer: ContentFinalizer?
    private var isFinalizing = false
    private var isDelivering = false

    init(bestAttemptContent: UNNotificationContent,
         contentFinalizer: @escaping ContentFinalizer = { content, _, contentHandler in contentHandler(content) },
         completionHook: (() -> Void)? = nil,
         contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.bestAttemptContent = bestAttemptContent
        self.contentHandler = contentHandler
        self.contentFinalizer = contentFinalizer
        self.completionHook = completionHook
    }

    func complete(with content: UNNotificationContent? = nil) {
        lock.lock()
        guard !isFinalizing,
              contentHandler != nil,
              let contentFinalizer,
              let content = content ?? bestAttemptContent else {
            lock.unlock()
            return
        }

        bestAttemptContent = content
        isFinalizing = true
        lock.unlock()

        contentFinalizer(content,
                         { [weak self] updatedContent in
                             self?.updateBestAttemptContent(updatedContent)
                         },
                         { [weak self] finalizedContent in
                             self?.deliver(finalizedContent)
                         })
    }

    @discardableResult
    func prepare(bestAttemptContent: UNNotificationContent,
                 contentFinalizer: @escaping ContentFinalizer) -> Bool {
        lock.withLock {
            guard self.contentHandler != nil, !isFinalizing else {
                return false
            }

            self.bestAttemptContent = bestAttemptContent
            self.contentFinalizer = contentFinalizer
            return true
        }
    }

    func expire() {
        lock.lock()
        while isDelivering {
            lock.wait()
        }
        guard let content = bestAttemptContent else {
            lock.unlock()
            return
        }
        lock.unlock()

        deliver(content)
    }

    private func updateBestAttemptContent(_ content: UNNotificationContent) {
        lock.lock()
        defer { lock.unlock() }
        guard contentHandler != nil else { return }
        bestAttemptContent = content.copy() as? UNNotificationContent ?? content
    }

    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        guard let contentHandler else {
            lock.unlock()
            return
        }

        let completionHook = completionHook
        isDelivering = true
        bestAttemptContent = nil
        self.contentHandler = nil
        contentFinalizer = nil
        self.completionHook = nil
        lock.unlock()

        contentHandler(content)

        lock.lock()
        isDelivering = false
        lock.broadcast()
        lock.unlock()

        completionHook?()
    }
}

enum NSEBadgeContentFinalizer {
    typealias BadgeSetter = (Int, @escaping (Error?) -> Void) -> Void
    private static let maximumReassertionCount = 4

    static func finalize(_ content: UNNotificationContent,
                         userID: String?,
                         ledger: NotificationBadgeRoomLedger,
                         authoritativeBadgeClaim: NSEAuthoritativeBadgeSequencer.Claim? = nil,
                         authoritativeBadgeSequencer: NSEAuthoritativeBadgeSequencer? = nil,
                         badgeSetter: @escaping BadgeSetter = { count, completion in
                             UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: completion)
                         },
                         contentUpdate: @escaping (UNNotificationContent) -> Void = { _ in },
                         delivery: @escaping (UNNotificationContent) -> Void) {
        let submitAndDeliver: (NSNumber?, Bool) -> Void = { badge, shouldReassertLedger in
            guard let content = content.mutableCopy() as? UNMutableNotificationContent else {
                delivery(content)
                return
            }
            content.overrideBadgeForDelivery(badge)
            contentUpdate(content)

            guard let badge else {
                delivery(content)
                return
            }

            func submit(_ badge: NSNumber, remainingReassertions: Int) {
                badgeSetter(badge.intValue) { error in
                    if let error {
                        MXLog.error("Failed submitting the final notification badge: \(error)")
                        delivery(content)
                        return
                    }

                    guard shouldReassertLedger else {
                        MXLog.info("Submitted the final authoritative notification badge: \(badge)")
                        delivery(content)
                        return
                    }

                    ledger.withCurrentBadge(userID: userID, fallback: nil) { latestBadge in
                        guard let latestBadge, latestBadge != badge else {
                            MXLog.info("Submitted the final notification badge: \(badge)")
                            delivery(content)
                            return
                        }

                        content.overrideBadgeForDelivery(latestBadge)
                        contentUpdate(content)
                        guard remainingReassertions > 0 else {
                            MXLog.error("Notification badge kept changing while the extension was finishing")
                            delivery(content)
                            return
                        }

                        submit(latestBadge, remainingReassertions: remainingReassertions - 1)
                    }
                }
            }

            submit(badge, remainingReassertions: Self.maximumReassertionCount)
        }

        if userID == nil,
           content.hasAuthoritativeBadgeForDelivery,
           let authoritativeBadgeClaim,
           let authoritativeBadgeSequencer {
            guard let content = content.mutableCopy() as? UNMutableNotificationContent else {
                delivery(content)
                return
            }

            func deliverLatestContent() {
                authoritativeBadgeSequencer.deliverLatest(replacing: authoritativeBadgeClaim) { claim in
                    content.overrideBadgeForDelivery(NSNumber(value: claim.badge))
                    contentUpdate(content)
                    delivery(content)
                }
            }

            func submit(_ proposedClaim: NSEAuthoritativeBadgeSequencer.Claim, remainingReassertions: Int) {
                let claim = authoritativeBadgeSequencer.latestClaim(replacing: proposedClaim)
                content.overrideBadgeForDelivery(NSNumber(value: claim.badge))
                contentUpdate(content)

                badgeSetter(claim.badge) { error in
                    if let error {
                        MXLog.error("Failed submitting the final authoritative notification badge: \(error)")
                        deliverLatestContent()
                        return
                    }

                    let latestClaim = authoritativeBadgeSequencer.latestClaim(replacing: claim)
                    guard latestClaim != claim else {
                        if authoritativeBadgeSequencer.deliverIfCurrent(latestClaim, delivery: { delivery(content) }) {
                            MXLog.info("Submitted the final authoritative notification badge: \(claim.badge)")
                            return
                        }

                        guard remainingReassertions > 0 else {
                            MXLog.error("Authoritative notification badge kept changing while the extension was finishing")
                            deliverLatestContent()
                            return
                        }

                        submit(authoritativeBadgeSequencer.latestClaim(replacing: latestClaim),
                               remainingReassertions: remainingReassertions - 1)
                        return
                    }

                    guard remainingReassertions > 0 else {
                        MXLog.error("Authoritative notification badge kept changing while the extension was finishing")
                        deliverLatestContent()
                        return
                    }

                    submit(latestClaim, remainingReassertions: remainingReassertions - 1)
                }
            }

            submit(authoritativeBadgeClaim, remainingReassertions: Self.maximumReassertionCount)
        } else if userID == nil, content.hasAuthoritativeBadgeForDelivery {
            submitAndDeliver(content.badgeForDelivery, false)
        } else {
            ledger.withCurrentBadge(userID: userID, fallback: content.badgeForDelivery) { badge in
                submitAndDeliver(badge, true)
            }
        }
    }
}

final class NSEAuthoritativeBadgeSequencer: @unchecked Sendable {
    struct Claim: Equatable {
        fileprivate let scope: String
        fileprivate let generation: UInt64
        let badge: Int
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latestClaims = [String: Claim]()

    func claim(for content: UNNotificationContent, resolvedReceiverID: String?) -> Claim? {
        guard resolvedReceiverID == nil,
              content.hasAuthoritativeBadgeForDelivery,
              let badge = content.badgeForDelivery?.intValue else {
            return nil
        }

        let scope = content.pusherNotificationClientIdentifier ?? "unscoped"
        return lock.withLock {
            generation &+= 1
            let claim = Claim(scope: scope, generation: generation, badge: badge)
            latestClaims[scope] = claim
            return claim
        }
    }

    func latestClaim(replacing claim: Claim) -> Claim {
        lock.withLock { latestClaims[claim.scope] ?? claim }
    }

    func deliverIfCurrent(_ claim: Claim, delivery: () -> Void) -> Bool {
        lock.withLock {
            guard latestClaims[claim.scope] == claim else {
                return false
            }

            delivery()
            return true
        }
    }

    func deliverLatest(replacing claim: Claim, delivery: (Claim) -> Void) {
        lock.withLock {
            delivery(latestClaims[claim.scope] ?? claim)
        }
    }
}

final class NotificationContentCompletionRegistry: @unchecked Sendable {
    private let lock = NSCondition()
    private var completions = [UUID: NotificationContentCompletion]()
    private var hasExpired = false

    var inFlightCount: Int {
        lock.withLock { completions.count }
    }

    @discardableResult
    func register(bestAttemptContent: UNNotificationContent,
                  contentFinalizer: @escaping NotificationContentCompletion.ContentFinalizer = { content, _, contentHandler in contentHandler(content) },
                  contentHandler: @escaping (UNNotificationContent) -> Void) -> NotificationContentCompletion {
        let identifier = UUID()
        let completion = NotificationContentCompletion(bestAttemptContent: bestAttemptContent,
                                                       contentFinalizer: contentFinalizer,
                                                       completionHook: { [weak self] in
                                                           self?.remove(identifier)
                                                       },
                                                       contentHandler: contentHandler)
        let shouldExpire = lock.withLock {
            completions[identifier] = completion
            return hasExpired
        }
        if shouldExpire {
            completion.expire()
        }
        return completion
    }

    func completeAll() {
        lock.lock()
        hasExpired = true
        let snapshot = Array(completions.values)
        lock.unlock()

        snapshot.forEach { completion in
            DispatchQueue.global().async {
                completion.expire()
            }
        }

        lock.lock()
        while !completions.isEmpty {
            lock.wait()
        }
        lock.unlock()
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        if completions.removeValue(forKey: identifier) != nil {
            lock.broadcast()
        }
        lock.unlock()
    }
}

enum NSEBadgeDeliveryNormalizer {
    static func normalizedContent(_ content: UNNotificationContent,
                                  userID: String?,
                                  ledger: NotificationBadgeRoomLedger) -> UNMutableNotificationContent? {
        guard let mutableContent = content.normalizedMutableContentForBadgeDelivery() else {
            return nil
        }

        guard userID != nil || !content.hasAuthoritativeBadgeForDelivery else {
            return mutableContent
        }

        let reconciledBadge = ledger.applyNotification(userID: userID,
                                                       roomID: content.roomID,
                                                       contributesToBadge: content.badgeContribution,
                                                       isAuthoritative: content.hasAuthoritativeBadgeForDelivery,
                                                       fallback: mutableContent.badgeForDelivery)
        mutableContent.overrideBadgeForDelivery(reconciledBadge)
        return mutableContent
    }
}

final class NSEFirstNotificationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var hasClaimedFirstNotification = false

    func claim() -> Bool {
        lock.withLock {
            guard !hasClaimedFirstNotification else {
                return false
            }

            hasClaimedFirstNotification = true
            return true
        }
    }
}

enum NSERequestPolicy {
    enum Action: Equatable {
        case deliverOfflineNotification
        case deliverOfflineReplacement
        case missingRoomID
        case missingEventID
        case missingClientID
        case process(roomID: String, eventID: String, clientID: String)
    }

    static func offlineAction(firstNotificationTracker: NSEFirstNotificationTracker) -> Action {
        firstNotificationTracker.claim() ? .deliverOfflineNotification : .deliverOfflineReplacement
    }

    static func configuredAction(shouldDeliverOffline: Bool, content: UNNotificationContent) -> Action {
        guard !shouldDeliverOffline else {
            return .deliverOfflineNotification
        }

        guard let roomID = content.roomID else {
            return .missingRoomID
        }

        guard let eventID = content.eventID else {
            return .missingEventID
        }

        guard let clientID = content.pusherNotificationClientIdentifier else {
            return .missingClientID
        }

        return .process(roomID: roomID, eventID: eventID, clientID: clientID)
    }

    static func offlineCompletionContent(for content: UNNotificationContent) -> UNMutableNotificationContent {
        content.badgeReplacementContentForDelivery
    }
}

// The lifecycle of the NSE looks something like the following:
//  1)  App receives notification
//  2)  System creates an instance of the extension class
//      and calls `didReceive` in the background
//  3)  Extension processes messages / displays whatever
//      notifications it needs to
//  4)  Extension notifies its work is complete by calling
//      the contentHandler
//  5)  If the extension takes too long to perform its work
//      (more than 30s), it will be notified and immediately
//      terminated
//
// Note that the NSE does *not* always spawn a new process to
// handle a new notification and will also try and process notifications
// in parallel. `didReceive` could be called twice for the same process,
// but it will always be called on different threads. It may or may not be
// called on the same instance of `NotificationService` as a previous
// notification.

/// The details of an already delivered notification needed to recognise a duplicate of it.
struct DeliveredNotificationSummary: Equatable {
    let identifier: String
    let eventID: String?
}

class NotificationServiceExtension: UNNotificationServiceExtension {
    static let receivedWhileOfflineNotificationID = "io.element.elementx.receivedWhileOfflineNotification"

    private static var targetConfiguration: Target.ConfigurationResult?

    private static let firstNotificationThreshold: TimeInterval = 15 * 60
    private static let notificationContentCompletions = NotificationContentCompletionRegistry()
    private static let authoritativeBadgeSequencer = NSEAuthoritativeBadgeSequencer()
    private static let firstNotificationTracker = NSEFirstNotificationTracker()

    private let settings: CommonSettingsProtocol = AppSettings()
    private let appHooks: AppHooks

    private let keychainController = KeychainController(service: .sessions,
                                                        accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)

    private var cancellables: Set<AnyCancellable> = []

    /// We can make the whole NSE a MainActor after https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md
    /// otherwise we wouldn't be able to log the tag in the deinit.
    deinit {
        ExtensionLogger.logMemory(with: tag)
        MXLog.info("\(tag) deinit")
    }

    override init() {
        appHooks = AppHooks()
        appHooks.setUp()

        // If the device is still locked then we can't write to the app group container and
        // the target configuration will fail. We could call exit(0) here, however with the
        // notification filtering entitlement that results in the notification being discarded
        // so we need to wait for the delegate method to be called and bail out there instead.
        if !BootDetectionManager.isDeviceLockedAfterReboot(containerURL: URL.appGroupContainerDirectory),
           Self.targetConfiguration == nil {
            Self.targetConfiguration = Target.nse.configure(logLevel: settings.logLevel,
                                                            traceLogPacks: settings.traceLogPacks,
                                                            sentryURL: nil,
                                                            rageshakeURL: settings.bugReportRageshakeURL,
                                                            appHooks: appHooks)
        }

        super.init()
    }

    /// The already delivered notifications that describe the same event as `content`.
    ///
    /// The homeserver pushes an event once per registered pusher, so a user who still has sessions
    /// from an earlier login can receive more than one copy. Removing matching delivered requests
    /// keeps sequential copies from accumulating in Notification Center. This is a best-effort
    /// client-side cleanup: it cannot suppress a banner or sound that already appeared, concurrent
    /// delivery can race this lookup, and notification centers belonging to another app bundle are
    /// outside this extension's sandbox.
    static func deliveredNotificationIdentifiers(matching content: UNNotificationContent,
                                                 in delivered: [DeliveredNotificationSummary]) -> [String] {
        guard let eventID = content.eventID else {
            return []
        }

        return delivered
            .filter { $0.eventID == eventID }
            .map(\.identifier)
    }

    private func removeDuplicateDeliveredNotifications(for content: UNNotificationContent) {
        guard content.eventID != nil else {
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let delivered = notifications.map {
                DeliveredNotificationSummary(identifier: $0.request.identifier, eventID: $0.request.content.eventID)
            }
            let matchingIdentifiers = Self.deliveredNotificationIdentifiers(matching: content, in: delivered)

            guard !matchingIdentifiers.isEmpty else {
                return
            }

            center.removeDeliveredNotifications(withIdentifiers: matchingIdentifiers)
        }
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let completion = Self.notificationContentCompletions.register(bestAttemptContent: request.content.badgeReplacementContentForDelivery,
                                                                      contentHandler: contentHandler)
        removeDuplicateDeliveredNotifications(for: request.content)

        let receiverID = resolvedReceiverID(for: request.content)
        let authoritativeBadgeClaim = Self.authoritativeBadgeSequencer.claim(for: request.content,
                                                                             resolvedReceiverID: receiverID)
        let mutableContent = NSEBadgeDeliveryNormalizer.normalizedContent(request.content,
                                                                          userID: receiverID,
                                                                          ledger: settings.notificationBadgeRoomLedger)
        let normalizedContent = mutableContent ?? request.content.badgeReplacementContentForDelivery
        let bestAttemptContent = normalizedContent.copy() as? UNNotificationContent
            ?? request.content.badgeReplacementContentForDelivery
        guard completion.prepare(bestAttemptContent: bestAttemptContent,
                                 contentFinalizer: { [settings, receiverID] content, contentUpdate, contentHandler in
                                     NSEBadgeContentFinalizer.finalize(content,
                                                                       userID: receiverID,
                                                                       ledger: settings.notificationBadgeRoomLedger,
                                                                       authoritativeBadgeClaim: authoritativeBadgeClaim,
                                                                       authoritativeBadgeSequencer: Self.authoritativeBadgeSequencer,
                                                                       contentUpdate: contentUpdate,
                                                                       delivery: contentHandler)
                                 }) else {
            return
        }

        guard let mutableContent else {
            completion.complete()
            return
        }

        Task { await handle(request, notificationContent: mutableContent, receiverID: receiverID, completion: completion) }
    }

    private func handle(_ request: UNNotificationRequest,
                        notificationContent: UNMutableNotificationContent,
                        receiverID: String?,
                        completion: NotificationContentCompletion) async {
        let roomID: String
        let eventID: String
        let clientID: String
        let isTargetConfigured = Self.targetConfiguration != nil
        let action = if isTargetConfigured {
            NSERequestPolicy.configuredAction(shouldDeliverOffline: shouldDeliverReceivedWhileOfflineNotification(),
                                              content: request.content)
        } else {
            NSERequestPolicy.offlineAction(firstNotificationTracker: Self.firstNotificationTracker)
        }

        switch action {
        case .deliverOfflineNotification:
            // Don't log until the app hooks have been run:
            // swiftlint:disable:next print_deprecation
            print(isTargetConfigured ? "Device is unlocked but may have missed notifications while offline." : "Device is locked after reboot.")
            let offlineCompletionContent = NSERequestPolicy.offlineCompletionContent(for: notificationContent)
            deliverReceivedWhileOfflineNotification(for: notificationContent)
            return completion.complete(with: offlineCompletionContent)
        case .deliverOfflineReplacement:
            // MXLog isn't configured:
            // swiftlint:disable:next print_deprecation
            print("Device is locked after reboot.")
            let offlineCompletionContent = NSERequestPolicy.offlineCompletionContent(for: notificationContent)
            return completion.complete(with: offlineCompletionContent)
        case .missingRoomID:
            // Don't log until the app hooks have been run:
            // swiftlint:disable:next print_deprecation
            print("Missing roomID, bailing out.")
            return completion.complete()
        case .missingEventID:
            // Don't log until the app hooks have been run:
            // swiftlint:disable:next print_deprecation
            print("Missing eventID, bailing out.")
            return completion.complete()
        case .missingClientID:
            // Don't log until the app hooks have been run:
            // swiftlint:disable:next print_deprecation
            print("Missing clientID, bailing out.")
            return completion.complete()
        case .process(let resolvedRoomID, let resolvedEventID, let resolvedClientID):
            roomID = resolvedRoomID
            eventID = resolvedEventID
            clientID = resolvedClientID
        }

        guard let credentials = keychainController.restorationTokens().first(where: { $0.restorationToken.pusherNotificationClientIdentifier == clientID }) else {
            // Don't log until the app hooks have been run:
            // swiftlint:disable:next print_deprecation
            print("Credentials not found, bailing out.")
            return completion.complete()
        }

        let homeserverURL = credentials.restorationToken.session.homeserverUrl
        await appHooks.remoteSettingsHook.loadCache(forHomeserver: homeserverURL, applyingTo: settings)

        MXLog.info("\(tag) #########################################")

        ExtensionLogger.logMemory(with: tag)

        let hasBadgeContract = request.content.userInfo[NotificationConstants.UserInfoKey.badgeContract] as? String
            == NotificationConstants.BadgeContract.identifier
        MXLog.info("\(tag) Received notification metadata for event \(eventID) in room \(roomID), badge contract: \(hasBadgeContract)")

        do {
            let userSession = try await NSEUserSession(credentials: credentials,
                                                       roomID: roomID,
                                                       clientSessionDelegate: keychainController,
                                                       appHooks: appHooks,
                                                       appSettings: settings)

            let notificationHandler = NotificationHandler(userSession: userSession,
                                                          settings: settings,
                                                          contentHandler: completion.complete(with:),
                                                          notificationContent: notificationContent,
                                                          receiverID: receiverID,
                                                          tag: tag)

            ExtensionLogger.logMemory(with: tag)
            MXLog.info("\(tag) Configured user session")

            await notificationHandler.processEvent(eventID, roomID: roomID)
        } catch {
            MXLog.error("Failed creating user session with error: \(error)")
            completion.complete()
        }
    }

    private func resolvedReceiverID(for content: UNNotificationContent) -> String? {
        guard Self.targetConfiguration != nil,
              let clientID = content.pusherNotificationClientIdentifier else {
            return content.receiverID
        }

        return keychainController.restorationTokens()
            .first { $0.restorationToken.pusherNotificationClientIdentifier == clientID }?
            .userID ?? content.receiverID
    }

    override func serviceExtensionTimeWillExpire() {
        Self.notificationContentCompletions.completeAll()
    }

    // MARK: - Boot handling

    /// The APNs servers only store the most recent notification when delivery fails. So when the user first boots
    /// their phone we need to use some approximations to decide whether or not the first notification may potentially
    /// represent more than one message. When that appears possible we replace the notification's content with the special
    /// "received while offline" notification as a more prominent prompt for to the user to open the app and check all their chats.
    ///
    /// Note that this only handles the first-boot case. When the SDK is able to compute the unread count, we should start to use the NSE,
    /// remote-notifications (content-available) and background app refreshes to fetch and deliver our notifications as a more robust solution.
    private func shouldDeliverReceivedWhileOfflineNotification() -> Bool {
        guard Self.firstNotificationTracker.claim() else {
            return false
        }

        guard let currentBootTime = BootDetectionManager.systemBootTime() else {
            // There's not much we can do if the boot time is unknown, so don't show the offline notification.
            return false
        }

        guard let lastKnownBootTime = settings.lastNotificationBootTime else {
            // Assume a missing boot time indicates a fresh installation…
            // So store the current boot time but let the notification through.
            settings.lastNotificationBootTime = currentBootTime
            return false
        }

        if abs(lastKnownBootTime - currentBootTime) < 1 {
            return false
        }

        // This is the first notification since boot, store the boot time.
        settings.lastNotificationBootTime = currentBootTime

        // At this point it becomes a trade-off. Once the device has been powered on for a long enough amount
        // of time it is a reasonable assumption that the device has now connected to a network and that any
        // notification is actually new rather than having been sent whilst the device was powered off.
        //
        // Note: We could actually solve this by having Sygnal add a timestamp to the notification payload 🤔
        if Date.now.timeIntervalSince(Date(timeIntervalSince1970: currentBootTime)) > Self.firstNotificationThreshold {
            return false
        } else {
            return true
        }
    }

    /// Delivers a generic notification informing the user that they have one or more new messages.
    ///
    /// Note: it is safe to call this method multiple times as it simply replaces any existing instance of the notification
    /// with a fresh copy, meaning it won't queue multiple copies but will still re-play the notification sound.
    private func deliverReceivedWhileOfflineNotification(for contentForDelivery: UNNotificationContent) {
        // This is intended to be called before the app hooks have been run, so don't log:
        // swiftlint:disable:next print_deprecation
        print("Delivering the 'received while offline' notification.")

        NSEBadgeContentFinalizer.finalize(contentForDelivery,
                                          userID: contentForDelivery.receiverID,
                                          ledger: settings.notificationBadgeRoomLedger) { [settings] finalizedContent in
            let content = finalizedContent.badgeReplacementContentForDelivery
            content.body = L10n.notificationReceivedWhileOfflineIos
            content.sound = .init(named: settings.notificationSoundName.publisher.value)

            let request = UNNotificationRequest(identifier: Self.receivedWhileOfflineNotificationID, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Logging

    private var tag: String {
        "[NSE][\(Unmanaged.passUnretained(self).toOpaque())][\(Unmanaged.passUnretained(Thread.current).toOpaque())][\(ProcessInfo.processInfo.processIdentifier)]"
    }
}
