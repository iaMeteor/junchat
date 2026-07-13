//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import LoremSwiftum
import MatrixRustSDK
import MatrixRustSDKMocks

struct EventTimelineItemSDKMockConfiguration {
    var eventID: String = UUID().uuidString
    var isRemote = true
    var eventOrTransactionID: EventOrTransactionId?
    var sender = ""
    var senderProfile: ProfileDetails?
    var forwarder: String?
    var forwarderProfile: ProfileDetails?
    var isOwn = false
    var content: TimelineItemContent = .msgLike(content: .init(kind: .redacted,
                                                               reactions: [],
                                                               inReplyTo: nil,
                                                               threadRoot: nil,
                                                               threadSummary: nil))
    var latestJSON: String?
}

extension EventTimelineItem {
    init(configuration: EventTimelineItemSDKMockConfiguration) {
        let eventOrTransactionID = configuration.eventOrTransactionID
            ?? (configuration.isRemote ? .eventId(eventId: configuration.eventID) : .transactionId(transactionId: configuration.eventID))
        let lazyProvider = LazyTimelineItemProviderSDKMock()
        lazyProvider.containsOnlyEmojisReturnValue = false
        lazyProvider.getShieldsStrictReturnValue = ShieldState.none
        lazyProvider.latestJsonReturnValue = configuration.latestJSON

        self.init(isRemote: configuration.isRemote,
                  eventOrTransactionId: eventOrTransactionID,
                  sender: configuration.sender,
                  senderProfile: configuration.senderProfile ?? .pending,
                  forwarder: configuration.forwarder,
                  forwarderProfile: configuration.forwarderProfile,
                  isOwn: configuration.isOwn,
                  isEditable: false,
                  content: configuration.content,
                  eventTypeRaw: nil,
                  timestamp: 0,
                  localSendState: nil,
                  localCreatedAt: nil,
                  readReceipts: [:],
                  origin: nil,
                  canBeRepliedTo: false,
                  lazyProvider: lazyProvider)
    }
    
    static var mockMessage: EventTimelineItem {
        mockMessage(configuration: .init())
    }

    static func mockMessage(configuration: EventTimelineItemSDKMockConfiguration) -> EventTimelineItem {
        let body = Lorem.sentences(Int.random(in: 1...5))
        let messageType = MessageType.text(content: .init(body: body, formatted: nil))
        
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: messageType,
                                                                                               body: body,
                                                                                               isEdited: false,
                                                                                               mentions: nil)),
                                                                 reactions: [],
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        
        var configuration = configuration
        configuration.content = content
        return .init(configuration: configuration)
    }
    
    static func mockCallInvite(sender: String) -> EventTimelineItem {
        .init(configuration: .init(sender: sender, content: .callInvite))
    }
}
