//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//

@testable import ElementX
import Foundation
import Testing
import UserNotifications

struct NotificationDuplicateSuppressionTests {
    private func content(eventID: String?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.eventID = eventID
        return content
    }

    @Test
    func copiesOfTheSameEventAreRemoved() {
        // A user with sessions left behind by an earlier login gets one push per pusher. They land
        // on the same device under different request identifiers, so the earlier ones are dropped.
        let delivered = [DeliveredNotificationSummary(identifier: "apns-1", eventID: "$event1"),
                         DeliveredNotificationSummary(identifier: "apns-2", eventID: "$event1")]

        let duplicates = NotificationServiceExtension.duplicateNotificationIdentifiers(of: content(eventID: "$event1"),
                                                                                       in: delivered)

        #expect(duplicates == ["apns-1", "apns-2"])
    }

    @Test
    func notificationsForOtherEventsAreKept() {
        let delivered = [DeliveredNotificationSummary(identifier: "apns-1", eventID: "$event1"),
                         DeliveredNotificationSummary(identifier: "apns-2", eventID: "$event2")]

        let duplicates = NotificationServiceExtension.duplicateNotificationIdentifiers(of: content(eventID: "$event2"),
                                                                                       in: delivered)

        #expect(duplicates == ["apns-2"])
    }

    @Test
    func notificationsWithoutAnEventAreNeverTreatedAsDuplicates() {
        // Badge only pushes carry no event, so they must not remove unrelated notifications.
        let delivered = [DeliveredNotificationSummary(identifier: "apns-1", eventID: nil),
                         DeliveredNotificationSummary(identifier: "apns-2", eventID: "$event1")]

        let duplicates = NotificationServiceExtension.duplicateNotificationIdentifiers(of: content(eventID: nil),
                                                                                       in: delivered)

        #expect(duplicates.isEmpty)
    }

    @Test
    func deliveredNotificationsWithoutAnEventAreLeftAlone() {
        let delivered = [DeliveredNotificationSummary(identifier: "apns-1", eventID: nil)]

        let duplicates = NotificationServiceExtension.duplicateNotificationIdentifiers(of: content(eventID: "$event1"),
                                                                                       in: delivered)

        #expect(duplicates.isEmpty)
    }
}
