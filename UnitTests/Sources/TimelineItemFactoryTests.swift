//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import Testing

@MainActor
struct TimelineItemFactoryTests {
    @Test
    func callInvite() throws {
        let ownUserID = "@alice:matrix.org"
        let senderUserID = "@bob:matrix.org"

        let factory = RoomTimelineItemFactory(userID: ownUserID,
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: ownUserID))
        
        let eventTimelineItem = EventTimelineItem.mockCallInvite(sender: senderUserID)
        
        let eventTimelineItemProxy = EventTimelineItemProxy(item: eventTimelineItem, uniqueID: .init("0"))
                
        let item = try #require(factory.buildTimelineItem(for: eventTimelineItemProxy, isDM: false) as? CallInviteRoomTimelineItem,
                                "Incorrect item type")
        
        #expect(item.isReactable == false)
        #expect(item.canBeRepliedTo == false)
        #expect(item.isEditable == false)
        #expect(item.sender == TimelineItemSender(id: senderUserID))
        #expect(item.properties.isEdited == false)
        #expect(item.properties.reactions == [])
        #expect(item.properties.deliveryStatus == nil)
    }

    @Test
    func privacyEvidencePropagatesThroughFreshFactoryReconstruction() throws {
        let firstItem = try buildPrivacyControlledTimelineItem(uniqueID: .init("first"))
        let restoredItem = try buildPrivacyControlledTimelineItem(uniqueID: .init("restored"))

        #expect(firstItem.properties.isPrivacyControlled)
        #expect(restoredItem.properties.isPrivacyControlled)
    }

    private func buildPrivacyControlledTimelineItem(uniqueID: TimelineItemIdentifier.UniqueID) throws -> TextRoomTimelineItem {
        let ownUserID = "@alice:matrix.org"
        let factory = RoomTimelineItemFactory(userID: ownUserID,
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: ownUserID))
        let event = EventTimelineItem.mockMessage(configuration: .init(latestJSON: """
        {
          "content": { "msgtype": "m.text", "body": "cached message" },
          "unsigned": {
            "com.heyujk.junchat.privacy_mode": true,
            "com.heyujk.junchat.privacy_mode.read_based": true
          }
        }
        """))
        let proxy = EventTimelineItemProxy(item: event, uniqueID: uniqueID)

        return try #require(factory.buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
    }
}
