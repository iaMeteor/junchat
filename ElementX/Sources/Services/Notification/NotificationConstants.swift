//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NotificationConstants {
    enum UserInfoKey {
        static let roomIdentifier = "room_id"
        static let eventIdentifier = "event_id"
        static let threadRootEventIdentifier = "thread_root_event_id"
        static let unreadCount = "unread_count"
        static let badgeContract = "badge_contract"
        static let badgeTotal = "badge_total"
        static let badgeContribution = "junchat_badge_contribution"
        static let pusherNotificationClientIdentifier = "pusher_notification_client_identifier"
        static let receiverIdentifier = "receiver_id"
    }

    enum BadgeContract {
        static let identifier = "junchat.notification-badge/v1"
        static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    }

    enum Category {
        static let message = "message"
        static let invite = "invite"
    }

    enum Action {
        static let inlineReply = "inline-reply"
    }
}
