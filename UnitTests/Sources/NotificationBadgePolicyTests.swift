//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//

import CryptoKit
import Dispatch
@testable import ElementX
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
    func localBadgeOverrideUpdatesTheContractTotal() {
        let content = makeContent(contract: expectedBadgeContract, total: 3, badge: 3)

        content.overrideBadgeForDelivery(1)

        #expect(content.badgeForDelivery == 1)
        #expect(content.userInfo["badge_total"] as? NSNumber == 1)
    }

    @Test
    func localBadgeOverrideUpdatesAndClearsLegacyUnreadCount() {
        let content = makeContent(unreadCount: 3, badge: 3)

        content.overrideBadgeForDelivery(1)

        #expect(content.badgeForDelivery == 1)
        #expect(content.userInfo["unread_count"] as? NSNumber == 1)

        content.overrideBadgeForDelivery(nil)

        #expect(content.badgeForDelivery == nil)
        #expect(content.userInfo["unread_count"] == nil)
    }

    @Test
    func badgeContributionRequiresTheKnownContractAndABoolean() {
        let contributing = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                                  "badge_total": 1,
                                                  "junchat_badge_contribution": true])
        let nonContributing = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                                     "badge_total": 1,
                                                     "junchat_badge_contribution": false])
        let unknownContract = makeContent(userInfo: ["badge_contract": "junchat.notification-badge/v2",
                                                     "badge_total": 1,
                                                     "junchat_badge_contribution": true])
        let missingTotal = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                                  "junchat_badge_contribution": true])
        let malformedTotal = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                                    "badge_total": "1",
                                                    "junchat_badge_contribution": true])
        let numericLookalike = makeContent(userInfo: ["badge_contract": expectedBadgeContract,
                                                      "badge_total": 1,
                                                      "junchat_badge_contribution": 1])

        #expect(contributing.badgeContribution == true)
        #expect(nonContributing.badgeContribution == false)
        #expect(unknownContract.badgeContribution == nil)
        #expect(missingTotal.badgeContribution == nil)
        #expect(malformedTotal.badgeContribution == nil)
        #expect(numericLookalike.badgeContribution == nil)
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
    func completionFinalizerRefreshesReverseOrderedSnapshots() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 1)
            .normalizedMutableContentForBadgeDelivery())
        let secondContent = try #require(makeContent(contract: expectedBadgeContract, total: 2)
            .normalizedMutableContentForBadgeDelivery())
        let latestBadge = NSNumber(value: 2)
        var deliveredBadges = [NSNumber?]()
        let finalizer: NotificationContentCompletion.ContentFinalizer = { content, contentUpdate, contentHandler in
            let content = content.mutableCopy() as? UNMutableNotificationContent
            content?.overrideBadgeForDelivery(latestBadge)
            if let content {
                contentUpdate(content)
            }
            contentHandler(content ?? UNMutableNotificationContent())
        }
        let firstCompletion = NotificationContentCompletion(bestAttemptContent: firstContent,
                                                            contentFinalizer: finalizer) { content in
            deliveredBadges.append(content.badge)
        }
        let secondCompletion = NotificationContentCompletion(bestAttemptContent: secondContent,
                                                             contentFinalizer: finalizer) { content in
            deliveredBadges.append(content.badge)
        }

        secondCompletion.complete()
        firstCompletion.complete()

        #expect(deliveredBadges == [NSNumber(value: 2), NSNumber(value: 2)])
    }

    @Test
    func offlineDeliveryFinalizerUsesTheLatestLedgerBadge() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        let content = sensitiveContentWithBadge(total: 3)
        var offlineContent: UNNotificationContent?

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: "@alice:example.org",
                                          ledger: fixture.ledger,
                                          badgeSetter: { _, completion in completion(nil) },
                                          delivery: { content in
                                              offlineContent = NSERequestPolicy.offlineCompletionContent(for: content)
                                          })

        #expect(offlineContent?.badge == 1)
    }

    @Test
    func finalizerSubmitsTheResolvedBadgeBeforeDelivery() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        let content = makeContent(badge: 0)
        var operations = [String]()

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              operations.append("set:\(count)")
                                              completion(nil)
                                          },
                                          delivery: { content in
                                              operations.append("deliver:\(content.badge?.intValue ?? -1)")
                                          })

        #expect(operations == ["set:1", "deliver:1"])
    }

    @Test
    func finalizerPreservesAnAuthoritativeBadgeWithoutAResolvedUser() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])
        let content = makeContent(contract: expectedBadgeContract, total: 1)
        var submittedBadge: Int?
        var deliveredBadge: Int?

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              submittedBadge = count
                                              completion(nil)
                                          },
                                          delivery: { content in
                                              deliveredBadge = content.badge?.intValue
                                          })

        #expect(submittedBadge == 1)
        #expect(deliveredBadge == 1)
    }

    @Test
    func reverseAuthoritativeCompletionsCannotRestoreAnOlderBadge() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        let sequencer = NSEAuthoritativeBadgeSequencer()
        let olderContent = makeContent(contract: expectedBadgeContract, total: 2)
        olderContent.userInfo["pusher_notification_client_identifier"] = "client"
        let olderClaim = try #require(sequencer.claim(for: olderContent, resolvedReceiverID: nil))
        var submissions = [(count: Int, completion: (Error?) -> Void)]()
        var deliveredBadges = [Int]()

        NSEBadgeContentFinalizer.finalize(olderContent,
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          authoritativeBadgeClaim: olderClaim,
                                          authoritativeBadgeSequencer: sequencer,
                                          badgeSetter: { count, completion in
                                              submissions.append((count, completion))
                                          },
                                          delivery: { content in
                                              deliveredBadges.append(content.badge?.intValue ?? -1)
                                          })
        #expect(submissions.map(\.count) == [2])

        let newerContent = makeContent(contract: expectedBadgeContract, total: 1)
        newerContent.userInfo["pusher_notification_client_identifier"] = "client"
        let newerClaim = try #require(sequencer.claim(for: newerContent, resolvedReceiverID: nil))
        NSEBadgeContentFinalizer.finalize(newerContent,
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          authoritativeBadgeClaim: newerClaim,
                                          authoritativeBadgeSequencer: sequencer,
                                          badgeSetter: { count, completion in
                                              submissions.append((count, completion))
                                          },
                                          delivery: { content in
                                              deliveredBadges.append(content.badge?.intValue ?? -1)
                                          })
        #expect(submissions.map(\.count) == [2, 1])

        submissions[1].completion(nil)
        #expect(deliveredBadges == [1])

        submissions[0].completion(nil)
        #expect(submissions.map(\.count) == [2, 1, 1])
        #expect(deliveredBadges == [1])

        submissions[2].completion(nil)
        #expect(deliveredBadges == [1, 1])
    }

    @Test
    func resolvedAndDifferentPusherBadgesDoNotSupersedeAnUnresolvedClaim() throws {
        let sequencer = NSEAuthoritativeBadgeSequencer()
        let unresolvedContent = makeContent(contract: expectedBadgeContract, total: 2)
        unresolvedContent.userInfo["pusher_notification_client_identifier"] = "first-client"
        let unresolvedClaim = try #require(sequencer.claim(for: unresolvedContent, resolvedReceiverID: nil))

        let resolvedContent = makeContent(contract: expectedBadgeContract, total: 9)
        resolvedContent.userInfo["pusher_notification_client_identifier"] = "first-client"
        #expect(sequencer.claim(for: resolvedContent, resolvedReceiverID: "@alice:example.org") == nil)

        let otherContent = makeContent(contract: expectedBadgeContract, total: 7)
        otherContent.userInfo["pusher_notification_client_identifier"] = "second-client"
        #expect(sequencer.claim(for: otherContent, resolvedReceiverID: nil) != nil)
        #expect(sequencer.latestClaim(replacing: unresolvedClaim) == unresolvedClaim)
    }

    @Test
    func deliveryNormalizerPreservesAnAuthoritativeBadgeWithoutAResolvedUser() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: [])
        let content = makeContent(contract: expectedBadgeContract, total: 1)

        let normalizedContent = try #require(NSEBadgeDeliveryNormalizer.normalizedContent(content,
                                                                                          userID: nil,
                                                                                          ledger: fixture.ledger))

        #expect(normalizedContent.badge == 1)
        #expect(normalizedContent.userInfo["badge_total"] as? NSNumber == 1)
    }

    @Test
    func finalizerReassertsANewerLedgerBadgeAfterSubmissionCompletes() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        let content = makeContent(badge: 0)
        var submissions = [(count: Int, completion: (Error?) -> Void)]()
        var deliveredBadges = [Int]()

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: "@alice:example.org",
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              submissions.append((count, completion))
                                          },
                                          delivery: { content in
                                              deliveredBadges.append(content.badge?.intValue ?? -1)
                                          })
        #expect(submissions.map(\.count) == [1])

        _ = fixture.ledger.markRoomRead(userID: "@alice:example.org", roomID: "!real:example.org")
        let initialCompletion = submissions[0].completion
        initialCompletion(nil)

        #expect(submissions.map(\.count) == [1, 0])
        #expect(deliveredBadges.isEmpty)

        let reassertionCompletion = submissions[1].completion
        reassertionCompletion(nil)

        #expect(deliveredBadges == [0])
    }

    @Test
    func legacyFinalizerReassertsTheLedgerWithoutAResolvedUser() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!real:example.org"])
        let content = makeContent(badge: 0)
        var submissions = [(count: Int, completion: (Error?) -> Void)]()
        var deliveredBadges = [Int]()

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              submissions.append((count, completion))
                                          },
                                          delivery: { content in
                                              deliveredBadges.append(content.badge?.intValue ?? -1)
                                          })
        #expect(submissions.map(\.count) == [1])

        _ = fixture.ledger.markRoomRead(userID: "@alice:example.org", roomID: "!real:example.org")
        submissions[0].completion(nil)

        #expect(submissions.map(\.count) == [1, 0])
        #expect(deliveredBadges.isEmpty)

        submissions[1].completion(nil)

        #expect(deliveredBadges == [0])
    }

    @Test
    func finalizerConvergesAcrossMultipleLedgerChanges() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!one:example.org"])
        let content = makeContent(badge: 0)
        var submissions = [(count: Int, completion: (Error?) -> Void)]()
        var deliveredBadges = [Int]()

        NSEBadgeContentFinalizer.finalize(content,
                                          userID: "@alice:example.org",
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              submissions.append((count, completion))
                                          },
                                          delivery: { content in
                                              deliveredBadges.append(content.badge?.intValue ?? -1)
                                          })
        #expect(submissions.map(\.count) == [1])

        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!one:example.org", "!two:example.org"])
        submissions[0].completion(nil)
        #expect(submissions.map(\.count) == [1, 2])

        _ = fixture.ledger.reconcile(userID: "@alice:example.org",
                                     unreadRoomIDs: ["!one:example.org", "!two:example.org", "!three:example.org"])
        submissions[1].completion(nil)
        #expect(submissions.map(\.count) == [1, 2, 3])
        #expect(deliveredBadges.isEmpty)

        submissions[2].completion(nil)

        #expect(deliveredBadges == [3])
    }

    @Test
    func finalizerLeavesTheSystemBadgeUnchangedWithoutAResolvedValue() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        var submittedBadge: Int?
        var deliveredContent: UNNotificationContent?

        NSEBadgeContentFinalizer.finalize(UNMutableNotificationContent(),
                                          userID: nil,
                                          ledger: fixture.ledger,
                                          badgeSetter: { count, completion in
                                              submittedBadge = count
                                              completion(nil)
                                          },
                                          delivery: { content in
                                              deliveredContent = content
                                          })

        #expect(submittedBadge == nil)
        #expect(deliveredContent?.badge == nil)
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
    func registryCompletesRegistrationsAfterExpirationImmediately() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 6)
            .normalizedMutableContentForBadgeDelivery())
        let recorder = LockedBadgeRecorder()
        let delivered = DispatchSemaphore(value: 0)
        let registry = NotificationContentCompletionRegistry()

        registry.completeAll()
        registry.register(bestAttemptContent: content) { content in
            recorder.append(content.badge)
            delivered.signal()
        }

        #expect(delivered.wait(timeout: .now()) == .success)
        #expect(recorder.badges == [6])
        #expect(registry.inFlightCount == 0)
    }

    @Test
    func registryDoesNotMissRegistrationInterleavedWithExpiration() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 7)
            .normalizedMutableContentForBadgeDelivery())
        let secondContent = try #require(makeContent(contract: expectedBadgeContract, total: 8)
            .normalizedMutableContentForBadgeDelivery())
        let recorder = LockedBadgeRecorder()
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let expirationFinished = DispatchSemaphore(value: 0)
        let secondDelivered = DispatchSemaphore(value: 0)
        let registry = NotificationContentCompletionRegistry()
        defer { releaseFirstDelivery.signal() }

        registry.register(bestAttemptContent: firstContent) { content in
            recorder.append(content.badge)
            firstDeliveryStarted.signal()
            releaseFirstDelivery.wait()
        }
        DispatchQueue.global().async {
            registry.completeAll()
            expirationFinished.signal()
        }

        try #require(firstDeliveryStarted.wait(timeout: .now() + 2) == .success)

        registry.register(bestAttemptContent: secondContent) { content in
            recorder.append(content.badge)
            secondDelivered.signal()
        }

        #expect(secondDelivered.wait(timeout: .now()) == .success)
        releaseFirstDelivery.signal()
        try #require(expirationFinished.wait(timeout: .now() + 2) == .success)
        #expect(recorder.badges.count == 2)
        #expect(Set(recorder.badges) == Set([7, 8]))
        #expect(registry.inFlightCount == 0)
    }

    @Test
    func immediatelyRegisteredFallbackSurvivesStalledPreparation() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 9)
            .normalizedMutableContentForBadgeDelivery())
        let delivered = DispatchSemaphore(value: 0)
        let expirationFinished = DispatchSemaphore(value: 0)
        let registry = NotificationContentCompletionRegistry()
        let completion = registry.register(bestAttemptContent: content) { _ in
            delivered.signal()
        }

        DispatchQueue.global().async {
            registry.completeAll()
            expirationFinished.signal()
        }

        try #require(delivered.wait(timeout: .now() + 2) == .success)
        try #require(expirationFinished.wait(timeout: .now() + 2) == .success)
        #expect(!completion.prepare(bestAttemptContent: makeContent(badge: 10)) { content, _, delivery in
            delivery(content)
        })
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
    func registryTracksFinalizationAndExpirationForcesOneDelivery() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 7)
            .normalizedMutableContentForBadgeDelivery())
        var finishFinalization: ((UNNotificationContent) -> Void)?
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()
        let completion = registry.register(bestAttemptContent: content,
                                           contentFinalizer: { _, _, delivery in
                                               finishFinalization = delivery
                                           },
                                           contentHandler: { content in
                                               recorder.append(content.badge)
                                           })

        completion.complete()

        #expect(registry.inFlightCount == 1)
        #expect(recorder.badges.isEmpty)

        registry.completeAll()

        #expect(registry.inFlightCount == 0)
        #expect(recorder.badges == [7])

        let lateContent = makeContent(contract: expectedBadgeContract, total: 99)
        finishFinalization?(lateContent)

        #expect(recorder.badges == [7])
    }

    @Test
    func expirationUsesTheBadgePreparedByTheFinalizer() throws {
        let fixture = try NotificationBadgeFinalizerFixture()
        fixture.ledger.prepare(for: "@alice:example.org")
        _ = fixture.ledger.reconcile(userID: "@alice:example.org", unreadRoomIDs: ["!one:example.org", "!two:example.org"])
        let content = makeContent(badge: 1)
        var submittedBadges = [Int]()
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()
        let completion = registry.register(bestAttemptContent: content,
                                           contentFinalizer: { content, contentUpdate, delivery in
                                               NSEBadgeContentFinalizer.finalize(content,
                                                                                 userID: "@alice:example.org",
                                                                                 ledger: fixture.ledger,
                                                                                 badgeSetter: { count, _ in
                                                                                     submittedBadges.append(count)
                                                                                 },
                                                                                 contentUpdate: contentUpdate,
                                                                                 delivery: delivery)
                                           },
                                           contentHandler: { content in
                                               recorder.append(content.badge)
                                           })

        completion.complete()

        #expect(submittedBadges == [2])
        #expect(recorder.badges.isEmpty)

        registry.completeAll()

        #expect(recorder.badges == [2])
    }

    @Test
    func registryRemainsTrackedUntilTheContentHandlerReturns() throws {
        let content = try #require(makeContent(contract: expectedBadgeContract, total: 8)
            .normalizedMutableContentForBadgeDelivery())
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let completionFinished = DispatchSemaphore(value: 0)
        let expirationFinished = DispatchSemaphore(value: 0)
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()
        let completion = registry.register(bestAttemptContent: content) { content in
            recorder.append(content.badge)
            handlerStarted.signal()
            releaseHandler.wait()
        }
        defer { releaseHandler.signal() }

        DispatchQueue.global().async {
            completion.complete()
            completionFinished.signal()
        }
        try #require(handlerStarted.wait(timeout: .now() + 2) == .success)

        #expect(registry.inFlightCount == 1)
        DispatchQueue.global().async {
            registry.completeAll()
            expirationFinished.signal()
        }
        #expect(expirationFinished.wait(timeout: .now() + 0.1) == .timedOut)

        releaseHandler.signal()
        try #require(completionFinished.wait(timeout: .now() + 2) == .success)
        try #require(expirationFinished.wait(timeout: .now() + 2) == .success)

        #expect(registry.inFlightCount == 0)
        #expect(recorder.badges == [8])
    }

    @Test
    func aBlockedHandlerDoesNotDelayAnotherExpirationFallback() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 9)
            .normalizedMutableContentForBadgeDelivery())
        let secondContent = try #require(makeContent(contract: expectedBadgeContract, total: 10)
            .normalizedMutableContentForBadgeDelivery())
        let firstHandlerStarted = DispatchSemaphore(value: 0)
        let releaseFirstHandler = DispatchSemaphore(value: 0)
        let secondDelivered = DispatchSemaphore(value: 0)
        let expirationFinished = DispatchSemaphore(value: 0)
        let recorder = LockedBadgeRecorder()
        let registry = NotificationContentCompletionRegistry()
        let firstCompletion = registry.register(bestAttemptContent: firstContent) { content in
            recorder.append(content.badge)
            firstHandlerStarted.signal()
            releaseFirstHandler.wait()
        }
        registry.register(bestAttemptContent: secondContent) { content in
            recorder.append(content.badge)
            secondDelivered.signal()
        }
        defer { releaseFirstHandler.signal() }

        DispatchQueue.global().async {
            firstCompletion.complete()
        }
        try #require(firstHandlerStarted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            registry.completeAll()
            expirationFinished.signal()
        }

        try #require(secondDelivered.wait(timeout: .now() + 2) == .success)
        #expect(expirationFinished.wait(timeout: .now() + 0.1) == .timedOut)

        releaseFirstHandler.signal()
        try #require(expirationFinished.wait(timeout: .now() + 2) == .success)

        #expect(Set(recorder.badges) == Set([9, 10]))
    }

    @Test
    func registrationDuringExpirationJoinsTheOutstandingBarrier() throws {
        let firstContent = try #require(makeContent(contract: expectedBadgeContract, total: 11)
            .normalizedMutableContentForBadgeDelivery())
        let expirationProbeContent = try #require(makeContent(contract: expectedBadgeContract, total: 12)
            .normalizedMutableContentForBadgeDelivery())
        let lateContent = try #require(makeContent(contract: expectedBadgeContract, total: 13)
            .normalizedMutableContentForBadgeDelivery())
        let firstHandlerStarted = DispatchSemaphore(value: 0)
        let releaseFirstHandler = DispatchSemaphore(value: 0)
        let expirationStarted = DispatchSemaphore(value: 0)
        let lateHandlerStarted = DispatchSemaphore(value: 0)
        let releaseLateHandler = DispatchSemaphore(value: 0)
        let lateRegistrationFinished = DispatchSemaphore(value: 0)
        let expirationFinished = DispatchSemaphore(value: 0)
        let registry = NotificationContentCompletionRegistry()
        let firstCompletion = registry.register(bestAttemptContent: firstContent) { _ in
            firstHandlerStarted.signal()
            releaseFirstHandler.wait()
        }
        registry.register(bestAttemptContent: expirationProbeContent) { _ in
            expirationStarted.signal()
        }
        defer {
            releaseFirstHandler.signal()
            releaseLateHandler.signal()
        }

        DispatchQueue.global().async {
            firstCompletion.complete()
        }
        try #require(firstHandlerStarted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            registry.completeAll()
            expirationFinished.signal()
        }
        try #require(expirationStarted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            registry.register(bestAttemptContent: lateContent) { _ in
                lateHandlerStarted.signal()
                releaseLateHandler.wait()
            }
            lateRegistrationFinished.signal()
        }
        try #require(lateHandlerStarted.wait(timeout: .now() + 2) == .success)

        releaseFirstHandler.signal()
        #expect(expirationFinished.wait(timeout: .now() + 0.1) == .timedOut)

        releaseLateHandler.signal()
        try #require(lateRegistrationFinished.wait(timeout: .now() + 2) == .success)
        try #require(expirationFinished.wait(timeout: .now() + 2) == .success)

        #expect(registry.inFlightCount == 0)
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
                                                       completionHook: { [completionToken] in
                                                           _ = completionToken
                                                       },
                                                       contentHandler: { [callbackToken] _ in
                                                           _ = callbackToken
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
    func firstLockedOfflineRequestBypassesMissingIdentifiersWithBadgeOnlyCompletion() {
        let content = sensitiveContentWithBadge(total: 9)
        let tracker = NSEFirstNotificationTracker()

        let action = NSERequestPolicy.offlineAction(firstNotificationTracker: tracker)
        let completionContent = NSERequestPolicy.offlineCompletionContent(for: content)

        #expect(action == .deliverOfflineNotification)
        expectBadgeOnlyCompletion(completionContent, total: 9)
    }

    @Test
    func repeatedLockedOfflineRequestBypassesMissingIdentifiersWithBadgeOnlyCompletion() {
        let content = sensitiveContentWithBadge(total: 10)
        let tracker = NSEFirstNotificationTracker()

        _ = NSERequestPolicy.offlineAction(firstNotificationTracker: tracker)
        let action = NSERequestPolicy.offlineAction(firstNotificationTracker: tracker)
        let completionContent = NSERequestPolicy.offlineCompletionContent(for: content)

        #expect(action == .deliverOfflineReplacement)
        expectBadgeOnlyCompletion(completionContent, total: 10)
    }

    @Test
    func lockedLegacyCountOnlyRequestUsesOfflineFallbackBeforeIdentifierValidation() {
        let content = makeContent(unreadCount: 11)
        content.body = "Sensitive legacy message"
        let tracker = NSEFirstNotificationTracker()

        let action = NSERequestPolicy.offlineAction(firstNotificationTracker: tracker)
        let completionContent = NSERequestPolicy.offlineCompletionContent(for: content)

        #expect(action == .deliverOfflineNotification)
        #expect(completionContent.badge == 11)
        #expect(completionContent.userInfo.isEmpty)
        #expect(completionContent.body.isEmpty)
    }

    @Test
    func configuredBootFallbackPrecedesMissingIdentifiers() {
        let content = sensitiveContentWithBadge(total: 12)

        let action = NSERequestPolicy.configuredAction(shouldDeliverOffline: true, content: content)
        let completionContent = NSERequestPolicy.offlineCompletionContent(for: content)

        #expect(action == .deliverOfflineNotification)
        expectBadgeOnlyCompletion(completionContent, total: 12)
    }

    @Test
    func offlineFallbackUsesTheLocallyCorrectedBadge() {
        let content = sensitiveContentWithBadge(total: 12)
        content.overrideBadgeForDelivery(1)

        let completionContent = NSERequestPolicy.offlineCompletionContent(for: content)

        expectBadgeOnlyCompletion(completionContent, total: 1)
    }

    @Test
    func firstNotificationTrackerAllowsOnlyOneConcurrentClaim() {
        let tracker = NSEFirstNotificationTracker()
        let claims = LockedBadgeRecorder()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if tracker.claim() {
                claims.append(NSNumber(value: 1))
            }
        }

        #expect(claims.badges == [1])
    }

    @Test
    func configuredRequestsKeepRoomEventClientValidationOrder() {
        let content = makeContent()

        #expect(NSERequestPolicy.configuredAction(shouldDeliverOffline: false,
                                                  content: content) == .missingRoomID)

        content.userInfo["room_id"] = "!room:example.org"
        #expect(NSERequestPolicy.configuredAction(shouldDeliverOffline: false,
                                                  content: content) == .missingEventID)

        content.userInfo["event_id"] = "$event"
        #expect(NSERequestPolicy.configuredAction(shouldDeliverOffline: false,
                                                  content: content) == .missingClientID)

        content.userInfo["pusher_notification_client_identifier"] = "client"
        #expect(NSERequestPolicy.configuredAction(shouldDeliverOffline: false,
                                                  content: content) == .process(roomID: "!room:example.org",
                                                                                eventID: "$event",
                                                                                clientID: "client"))
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

    private func sensitiveContentWithBadge(total: Int) -> UNMutableNotificationContent {
        let content = makeContent(contract: expectedBadgeContract, total: total)
        content.title = "Sensitive title"
        content.body = "Sensitive message"
        content.sound = .default
        return content
    }

    private func expectBadgeOnlyCompletion(_ content: UNNotificationContent, total: Int) {
        #expect(content.badge == NSNumber(value: total))
        #expect(content.userInfo.count == 2)
        #expect(content.userInfo["badge_contract"] as? String == expectedBadgeContract)
        #expect(content.userInfo["badge_total"] as? NSNumber == NSNumber(value: total))
        #expect(content.title.isEmpty)
        #expect(content.body.isEmpty)
        #expect(content.sound == nil)
        #expect(content.roomID == nil)
        #expect(content.eventID == nil)
    }
}

private final class NotificationBadgePolicyFixtureToken { }

private final class NotificationBadgeFinalizerFixture {
    let ledger: NotificationBadgeRoomLedger

    private let suiteName: String
    private let userDefaults: UserDefaults
    private let directoryURL: URL

    init() throws {
        let identifier = UUID().uuidString
        suiteName = "NotificationBadgeFinalizerFixture.\(identifier)"
        userDefaults = try #require(UserDefaults(suiteName: suiteName))
        directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "NotificationBadgeFinalizerFixture")
            .appending(component: identifier)
        ledger = NotificationBadgeRoomLedger(userDefaults: userDefaults,
                                             lockFileURL: directoryURL.appending(component: "ledger.lock"))
    }

    deinit {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

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
