//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//

import CryptoKit
@testable import ElementX
import Dispatch
import Foundation
import Testing
import UserNotifications

struct NotificationBadgePolicyTests {
    private let expectedFixtureChecksum = "8c19a3a915656a320fb77e184716c35632ef601ee6da33641b461fceae5c61a3"
    private let expectedFixtureSchema = "junchat.notification-badge-fixtures/v1"
    private let expectedBadgeContract = "junchat.notification-badge/v1"
    private let preservedBadge = NSNumber(value: 23)
    
    @Test
    func canonicalFixturePolicyExpectations() throws {
        let fixtureURL = try #require(Bundle(for: NotificationBadgePolicyFixtureToken.self)
            .url(forResource: "notification-badge-v1", withExtension: "json"))
        let data = try Data(contentsOf: fixtureURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(checksum == expectedFixtureChecksum)
        
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["schema"] as? String == expectedFixtureSchema)
        #expect(manifest["schema_version"] as? Int == 1)
        #expect(manifest["badge_contract"] as? String == expectedBadgeContract)
        
        let cases = try #require(manifest["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        
        for fixtureCase in cases {
            let identifier = try #require(fixtureCase["id"] as? String)
            let expected = try #require(fixtureCase["expected"] as? [String: Any])
            let payload = try #require(expected["normalized_payload"] as? [String: Any])
            let client = try #require(expected["client"] as? [String: Any])
            let badgeAction = try #require(client["badge_action"] as? String)
            let timeoutAction = try #require(client["nse_timeout_action"] as? String)
            
            if let contract = payload["badge_contract"] {
                #expect(contract as? String == expectedBadgeContract, "Unexpected marker in \(identifier)")
            }
            #expect(client["adds_components"] as? Bool == false, "Components must not be added in \(identifier)")
            
            let content = makeContent(userInfo: payload, badge: preservedBadge)
            switch badgeAction {
            case "set":
                let expectedTotal = try #require(client["badge_total"] as? NSNumber)
                #expect(content.badgeForDelivery == expectedTotal, "Unexpected total in \(identifier)")
                #expect(timeoutAction == "use_preserved_badge_total", "Unexpected timeout policy in \(identifier)")
            case "preserve":
                #expect(content.badgeForDelivery == preservedBadge, "Existing badge was not preserved in \(identifier)")
                #expect(timeoutAction == "preserve_existing_badge", "Unexpected timeout policy in \(identifier)")
            default:
                Issue.record("Unexpected badge action \(badgeAction) in \(identifier)")
            }
        }
    }
    
    @Test
    func maximumSafeContractTotalIsAuthoritative() {
        let maximumSafeInteger = NSNumber(value: Int64(9_007_199_254_740_991))
        let content = makeContent(contract: expectedBadgeContract,
                                  total: maximumSafeInteger,
                                  unreadCount: 8,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == maximumSafeInteger)
    }
    
    @Test
    func existingAPNsBadgePrecedesLegacyUnreadCount() {
        let content = makeContent(unreadCount: 4, badge: 9)
        
        #expect(content.badgeForDelivery == 9)
    }
    
    @Test
    func largeExistingAPNsBadgeIsPreserved() {
        let badge = NSNumber(value: Int64(9_007_199_254_740_992))
        let content = makeContent(unreadCount: 4, badge: badge)

        #expect(content.badgeForDelivery == badge)
    }

    @Test
    func legacyUnreadCountIsTheFinalFallback() {
        let content = makeContent(unreadCount: 4)
        
        #expect(content.badgeForDelivery == 4)
    }

    @Test
    func booleanLegacyUnreadCountIsRejected() {
        let content = makeContent(unreadCount: true)

        #expect(content.badgeForDelivery == nil)
    }

    @Test
    func negativeAndFractionalLegacyUnreadCountsAreRejected() {
        #expect(makeContent(unreadCount: -1).badgeForDelivery == nil)
        #expect(makeContent(unreadCount: NSNumber(value: 1.5)).badgeForDelivery == nil)
    }
    
    @Test
    func missingBadgeInputsReturnNil() {
        #expect(makeContent().badgeForDelivery == nil)
    }
    
    @Test
    func unknownContractMarkerPreservesExistingBadge() {
        let content = makeContent(contract: "junchat.notification-badge/v2",
                                  total: 3,
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func malformedContractTotalPreservesExistingBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: "3",
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func negativeContractTotalPreservesExistingBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: -1,
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func fractionalContractTotalPreservesExistingBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: NSNumber(value: 1.5),
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func booleanContractTotalPreservesExistingBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: true,
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func overflowingContractTotalPreservesExistingBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: NSNumber(value: Int64(9_007_199_254_740_992)),
                                  unreadCount: 2,
                                  badge: 7)
        
        #expect(content.badgeForDelivery == 7)
    }
    
    @Test
    func authoritativeZeroClearsTheBadge() {
        let content = makeContent(contract: expectedBadgeContract,
                                  total: 0,
                                  unreadCount: 12,
                                  badge: 11)
        
        #expect(content.badgeForDelivery == NSNumber(value: 0))
    }
    
    @Test
    func countOnlyContentIsNormalizedForEarlyFallback() throws {
        let content = makeContent(contract: expectedBadgeContract, total: 6)
        let normalizedContent = try #require(content.normalizedMutableContentForBadgeDelivery())

        #expect(normalizedContent.badge == 6)
        #expect(normalizedContent.roomID == nil)
        #expect(normalizedContent.eventID == nil)
    }

    @Test
    func timeoutBeforeHandlerDeliversNormalizedBestAttempt() throws {
        let content = makeContent(contract: expectedBadgeContract, total: 7)
        let normalizedContent = try #require(content.normalizedMutableContentForBadgeDelivery())
        var deliveredContent: UNNotificationContent?
        let completion = NotificationContentCompletion(bestAttemptContent: normalizedContent) { content in
            deliveredContent = content
        }

        completion.complete()

        #expect(deliveredContent?.badge == 7)
    }

    @Test
    func notificationContentCompletionDeliversOnlyOnce() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 1)
            .normalizedMutableContentForBadgeDelivery())
        let laterContent = makeContent(contract: expectedBadgeContract, total: 2).badgeReplacementContentForDelivery
        var deliveredBadges = [NSNumber?]()
        let completion = NotificationContentCompletion(bestAttemptContent: firstContent) { content in
            deliveredBadges.append(content.badge)
        }

        completion.complete()
        completion.complete(with: laterContent)

        #expect(deliveredBadges == [NSNumber(value: 1)])
    }

    @Test
    func notificationContentCompletionIsOneShotUnderConcurrency() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 3)
            .normalizedMutableContentForBadgeDelivery())
        let recorder = LockedBadgeRecorder()
        let completion = NotificationContentCompletion(bestAttemptContent: content) { content in
            recorder.append(content.badge)
        }

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            completion.complete()
        }

        #expect(recorder.badges == [3])
    }

    @Test
    func registryTimeoutCompletesEveryInFlightRequest() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 4)
            .normalizedMutableContentForBadgeDelivery())
        let secondContent = try #require(makeContent(contract: expectedBadgeContract, total: 5)
            .normalizedMutableContentForBadgeDelivery())
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()

        registry.register(bestAttemptContent: firstContent) { content in
            recorder.append(content.badge)
        }
        registry.register(bestAttemptContent: secondContent) { content in
            recorder.append(content.badge)
        }

        registry.completeAll()

        #expect(recorder.badges.count == 2)
        #expect(Set(recorder.badges) == Set([4, 5]))
        #expect(registry.inFlightCount == 0)
    }

    @Test
    func registryRemovesCompletedRequests() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 6)
            .normalizedMutableContentForBadgeDelivery())
        let registry = NotificationContentCompletionRegistry()
        let completion = registry.register(bestAttemptContent: content) { _ in }

        #expect(registry.inFlightCount == 1)

        completion.complete()

        #expect(registry.inFlightCount == 0)
        registry.completeAll()
    }

    @Test
    func completionReleasesDeliveryStateAfterInvocation() throws {
        weak var weakContent: UNNotificationContent?
        weak var weakCallbackToken: ReferenceToken?
        weak var weakCompletionToken: ReferenceToken?
        let completion: NotificationContentCompletion

        do {
            let content = try #require(makeContent(contract: expectedBadgeContract, total: 7)
                .normalizedMutableContentForBadgeDelivery())
            let callbackToken = ReferenceToken()
            let completionToken = ReferenceToken()
            weakContent = content
            weakCallbackToken = callbackToken
            weakCompletionToken = completionToken
            completion = NotificationContentCompletion(bestAttemptContent: content,
                                                        contentHandler: { [callbackToken] _ in
                                                            _ = callbackToken
                                                        },
                                                        completionHook: { [completionToken] in
                                                            _ = completionToken
                                                        })
        }

        #expect(weakContent != nil)
        #expect(weakCallbackToken != nil)
        #expect(weakCompletionToken != nil)

        completion.complete()

        #expect(weakContent == nil)
        #expect(weakCallbackToken == nil)
        #expect(weakCompletionToken == nil)
    }

    @Test
    func registryTimeoutUsesImmutableBestAttemptSnapshot() throws {
        let processingContent = try #require(makeContent(contract: expectedBadgeContract, total: 8)
            .normalizedMutableContentForBadgeDelivery())
        let bestAttemptContent = try #require(processingContent.copy() as? UNNotificationContent)
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()
        registry.register(bestAttemptContent: bestAttemptContent) { content in
            recorder.append(content.badge)
        }

        processingContent.badge = 99
        processingContent.userInfo["badge_total"] = 99
        registry.completeAll()

        #expect(recorder.badges == [8])
    }

    @Test
    func replacementContentCopiesOnlyValidContractMetadata() {
        let content = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                             "badge_total": 5,
                                             "room_id": "!room:example.org",
                                             "event_id": "$event",
                                             "unread_count": 9,
                                             "custom": "value"],
                                  badge: 12)
        let replacementContent = content.badgeReplacementContentForDelivery

        #expect(replacementContent.badge == 5)
        #expect(replacementContent.userInfo.count == 2)
        #expect(replacementContent.userInfo["badge_contract"] as? String == expectedBadgeContract)
        #expect(replacementContent.userInfo["badge_total"] as? Int == 5)
        #expect(replacementContent.roomID == nil)
        #expect(replacementContent.eventID == nil)
    }

    @Test
    func replacementContentDoesNotCopyInvalidContractMetadata() {
        let content = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                             "badge_total": "5",
                                             "room_id": "!room:example.org",
                                             "event_id": "$event"],
                                  badge: 12)
        let replacementContent = content.badgeReplacementContentForDelivery

        #expect(replacementContent.badge == 12)
        #expect(replacementContent.userInfo.isEmpty)
    }

    private func makeContent(userInfo: [String: Any] = [:], badge: NSNumber? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.userInfo = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        content.badge = badge
        return content
    }
    
    private func makeContent(contract: Any? = nil,
                             total: Any? = nil,
                             unreadCount: Any? = nil,
                             badge: NSNumber? = nil) -> UNMutableNotificationContent {
        var userInfo = [String: Any]()
        userInfo["badge_contract"] = contract
        userInfo["badge_total"] = total
        userInfo["unread_count"] = unreadCount
        return makeContent(userInfo: userInfo, badge: badge)
    }
}

private final class NotificationBadgePolicyFixtureToken { }

private final class LockedBadgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBadges = [Int]()

    var badges: [Int] {
        lock.withLock { storedBadges }
    }

    func append(_ badge: NSNumber?) {
        lock.withLock {
            storedBadges.append(badge?.intValue ?? -1)
        }
    }
}

private final class ReferenceToken { }
