//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import LinkPresentation
import SwiftUI
import Testing
import UIKit

struct TextBasedRoomTimelineTests {
    @Test
    func textRoomTimelineItemWhitespaceEnd() {
        let timestamp = Calendar.current.startOfDay(for: .now).addingTimeInterval(60 * 60) // 1:00 am
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        #expect(timelineItem.additionalWhitespaces() == timestamp.formattedTime().count + 1)
    }

    @Test
    func textRoomTimelineItemWhitespaceEndLonger() {
        let timestamp = Calendar.current.startOfDay(for: .now).addingTimeInterval(-60) // 11:59 pm
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        #expect(timelineItem.additionalWhitespaces() == timestamp.formattedTime().count + 1)
    }

    @Test
    func textRoomTimelineItemWhitespaceEndWithEdit() {
        let timestamp = Date.mock
        var timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        timelineItem.properties.isEdited = true
        let editedCount = L10n.commonEditedSuffix.count
        #expect(timelineItem.additionalWhitespaces() == timestamp.formattedTime().count + editedCount + 2)
    }

    @Test
    func textRoomTimelineItemWhitespaceEndWithEditAndAlert() {
        let timestamp = Date.mock
        var timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: timestamp,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: UUID().uuidString),
                                                content: .init(body: "Test"))
        timelineItem.properties.isEdited = true
        timelineItem.properties.deliveryStatus = .sendingFailed(.unknown)
        let editedCount = L10n.commonEditedSuffix.count
        #expect(timelineItem.additionalWhitespaces() == timestamp.formattedTime().count + editedCount + 5)
    }

    @Test
    func timelineSendInfoUsesSeparateLayoutForLargeDynamicTypeSizes() {
        #expect(!DynamicTypeSize.large.junchatUsesSeparateTimelineSendInfo)
        #expect(!DynamicTypeSize.xLarge.junchatUsesSeparateTimelineSendInfo)
        #expect(DynamicTypeSize.xxLarge.junchatUsesSeparateTimelineSendInfo)
        #expect(DynamicTypeSize.xxxLarge.junchatUsesSeparateTimelineSendInfo)
        #expect(DynamicTypeSize.accessibility1.junchatUsesSeparateTimelineSendInfo)
        #expect(DynamicTypeSize.accessibility5.junchatUsesSeparateTimelineSendInfo)
    }

    @Test
    func junchatShareCardParsesTitleSummaryAndURL() throws {
        let card = try #require(JunchatShareCard.parse(body: """
        直播日照：张一鸣，再当中国首富
        据彭博社报道，字节跳动估值上涨
        https://www.toutiao.com/article/123
        """))

        #expect(card.title == "直播日照：张一鸣，再当中国首富")
        #expect(card.summary == "据彭博社报道，字节跳动估值上涨")
        #expect(card.host == "toutiao.com")
        #expect(card.shouldReplaceBody)
    }

    @Test
    func junchatShareCardParsesSingleLineShare() throws {
        let card = try #require(JunchatShareCard.parse(body: "可以看看这个 https://example.com/news?id=1"))

        #expect(card.title == "可以看看这个")
        #expect(card.host == "example.com")
        #expect(card.shouldReplaceBody)
    }

    @Test
    func junchatShareCardIgnoresPlainText() {
        #expect(JunchatShareCard.parse(body: "没有链接的普通消息") == nil)
    }

    @Test
    func junchatShareCardFallsBackToHostForURLOnly() throws {
        let card = try #require(JunchatShareCard.parse(body: "https://www.example.com/path"))

        #expect(card.title == "example.com")
        #expect(card.summary == nil)
        #expect(card.shouldReplaceBody)
    }

    @Test
    func junchatSharePreviewImageLoadsMetadataImageProvider() async {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 2, height: 2)))
        }
        let metadata = LPLinkMetadata()
        metadata.imageProvider = NSItemProvider(object: image)

        let previewImage = await JunchatSharePreviewImage.load(from: metadata)

        #expect(previewImage != nil)
    }
}
