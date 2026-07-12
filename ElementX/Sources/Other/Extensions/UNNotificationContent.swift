//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreFoundation
import Foundation
import UserNotifications

extension UNNotificationContent {
    @objc var receiverID: String? {
        userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] as? String
    }

    @objc var roomID: String? {
        userInfo[NotificationConstants.UserInfoKey.roomIdentifier] as? String
    }
    
    @objc var eventID: String? {
        userInfo[NotificationConstants.UserInfoKey.eventIdentifier] as? String
    }

    @objc var pusherNotificationClientIdentifier: String? {
        userInfo[NotificationConstants.UserInfoKey.pusherNotificationClientIdentifier] as? String
    }
    
    @objc var threadRootEventID: String? {
        userInfo[NotificationConstants.UserInfoKey.threadRootEventIdentifier] as? String
    }
    
    var unreadCount: Int? {
        userInfo[NotificationConstants.UserInfoKey.unreadCount] as? Int
    }
    
    var badgeForDelivery: NSNumber? {
        if userInfo[NotificationConstants.UserInfoKey.badgeContract] as? String == NotificationConstants.BadgeContract.identifier,
           let badgeTotal = Self.validBadgeNumber(userInfo[NotificationConstants.UserInfoKey.badgeTotal],
                                                  maximum: NotificationConstants.BadgeContract.maximumSafeInteger) {
            return badgeTotal
        }
        
        if let badge = Self.validBadgeNumber(badge) {
            return badge
        }
        
        return unreadCount as NSNumber?
    }
    
    func normalizedMutableContentForBadgeDelivery() -> UNMutableNotificationContent? {
        guard let content = mutableCopy() as? UNMutableNotificationContent else {
            return nil
        }
        
        content.badge = badgeForDelivery
        return content
    }
    
    var badgeReplacementContentForDelivery: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.userInfo = validBadgeContractMetadata
        content.badge = badgeForDelivery
        return content
    }
    
    private var validBadgeContractMetadata: [AnyHashable: Any] {
        guard userInfo[NotificationConstants.UserInfoKey.badgeContract] as? String == NotificationConstants.BadgeContract.identifier,
              let badgeTotal = Self.validBadgeNumber(userInfo[NotificationConstants.UserInfoKey.badgeTotal],
                                                     maximum: NotificationConstants.BadgeContract.maximumSafeInteger) else {
            return [:]
        }
        
        return [NotificationConstants.UserInfoKey.badgeContract: NotificationConstants.BadgeContract.identifier,
                NotificationConstants.UserInfoKey.badgeTotal: badgeTotal]
    }
    
    private static func validBadgeNumber(_ value: Any?, maximum: Int64? = nil) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        
        let integerValue = number.int64Value
        guard integerValue >= 0,
              number.compare(NSNumber(value: integerValue)) == .orderedSame else {
            return nil
        }
        
        if let maximum, integerValue > maximum {
            return nil
        }
        
        return number
    }
}

extension UNMutableNotificationContent {
    override var receiverID: String? {
        get {
            userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] as? String
        }
        set {
            userInfo[NotificationConstants.UserInfoKey.receiverIdentifier] = newValue
        }
    }
    
    override var roomID: String? {
        get {
            userInfo[NotificationConstants.UserInfoKey.roomIdentifier] as? String
        }
        set {
            userInfo[NotificationConstants.UserInfoKey.roomIdentifier] = newValue
        }
    }
    
    override var eventID: String? {
        get {
            userInfo[NotificationConstants.UserInfoKey.eventIdentifier] as? String
        }
        set {
            userInfo[NotificationConstants.UserInfoKey.eventIdentifier] = newValue
        }
    }
    
    override var threadRootEventID: String? {
        get {
            userInfo[NotificationConstants.UserInfoKey.threadRootEventIdentifier] as? String
        }
        set {
            userInfo[NotificationConstants.UserInfoKey.threadRootEventIdentifier] = newValue
        }
    }
}
