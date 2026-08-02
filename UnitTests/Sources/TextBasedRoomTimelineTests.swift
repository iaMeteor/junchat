//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import SwiftUI
import Testing

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

    @Test @MainActor
    func outgoingURLMessageCanBeRedacted() throws {
        let url = try #require(URL(string: "https://example.com/path"))
        var formattedBody = AttributedString(url.absoluteString)
        formattedBody.link = url
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: .mock,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: "@alice:example.com"),
                                                content: .init(body: url.absoluteString, formattedBody: formattedBody))
        let actions = try #require(TimelineItemMenuActionProvider(timelineItem: timelineItem,
                                                                  canCurrentUserSendMessage: true,
                                                                  canCurrentUserRedactSelf: true,
                                                                  canCurrentUserRedactOthers: false,
                                                                  canCurrentUserPin: false,
                                                                  pinnedEventIDs: [],
                                                                  isDM: true,
                                                                  isViewSourceEnabled: false,
                                                                  areThreadsEnabled: false,
                                                                  timelineKind: .live,
                                                                  emojiProvider: EmojiProvider(appSettings: AppSettings()))
                .makeActions())

        #expect(timelineItem.links == [url])
        #expect(actions.actions.contains(.copyLink(url)))
        #expect(actions.actions.contains(.setLinkPresentation(.text)))
        #expect(actions.secondaryActions.contains(.redact))
    }

    @Test @MainActor
    func URLMessageMenuCanToggleBackToCard() throws {
        let url = try #require(URL(string: "https://example.com/path"))
        let timelineItem = TextRoomTimelineItem(id: .randomEvent,
                                                timestamp: .mock,
                                                isOutgoing: true,
                                                isEditable: true,
                                                canBeRepliedTo: true,
                                                sender: .init(id: "@alice:example.com"),
                                                content: .init(body: url.absoluteString))
        let actions = try #require(TimelineItemMenuActionProvider(timelineItem: timelineItem,
                                                                  canCurrentUserSendMessage: true,
                                                                  canCurrentUserRedactSelf: true,
                                                                  canCurrentUserRedactOthers: false,
                                                                  canCurrentUserPin: false,
                                                                  pinnedEventIDs: [],
                                                                  isDM: true,
                                                                  isViewSourceEnabled: false,
                                                                  areThreadsEnabled: false,
                                                                  timelineKind: .live,
                                                                  emojiProvider: EmojiProvider(appSettings: AppSettings()),
                                                                  linkPresentationOverride: .text)
                .makeActions())

        #expect(actions.actions.contains(.copyLink(url)))
        #expect(actions.actions.contains(.setLinkPresentation(.card)))
    }

    @Test
    func linkPresentationIsEncodedWithoutChangingTheFallbackBody() throws {
        let plain = "News <today> https://example.com/path?a=1&b=2"
        let formattedBody = try #require(JunchatLinkPresentation.formattedBody(plain: plain,
                                                                               html: nil,
                                                                               presentation: .text))

        #expect(JunchatLinkPresentation.encodedPresentation(in: formattedBody) == .text)
        #expect(formattedBody.contains("data-junchat-link-presentation=\"text\""))
        #expect(formattedBody.contains("News &lt;today&gt;"))
        #expect(formattedBody.contains("<a href=\"https://example.com/path?a=1&amp;b=2\">"))
        #expect(JunchatLinkPresentation.formattedBody(plain: plain, html: nil, presentation: .card) == nil)
    }

    @Test
    func shareCardRecognisesShortBareDomainsWithoutWhitespaceWorkarounds() throws {
        let card = try #require(JunchatShareCard.parse(body: "junchat.yyzs120.cn"))

        #expect(card.url.host == "junchat.yyzs120.cn")
        #expect(card.shouldReplaceBody)
    }

    @Test
    func shareCardKeepsMessageTextVisibleAlongsideTheCard() throws {
        let body = "First line\nSecond line\nThird line\nFourth line\nhttps://example.com/news"
        let card = try #require(JunchatShareCard.parse(body: body))

        #expect(!card.shouldReplaceBody)
    }

    @Test
    func multipleURLMessageKeepsEveryLinkVisible() throws {
        let body = "https://example.com/one\nhttps://example.com/two"
        let card = try #require(JunchatShareCard.parse(body: body))

        #expect(!card.shouldReplaceBody)
    }

    @Test
    func URLPreviewsRequireTheExplicitPreferenceAndRemainBounded() throws {
        let links = try [
            #require(URL(string: "https://example.com/one")),
            #require(URL(string: "https://example.com/two")),
            #require(URL(string: "https://example.com/three"))
        ]

        #expect(TextRoomTimelineView.linkPreviewURLs(links: links, enabled: false).isEmpty)
        #expect(TextRoomTimelineView.linkPreviewURLs(links: links, enabled: true) == Array(links.prefix(2)))
        #expect(TextRoomTimelineView.metadataURLs(links: links,
                                                  enabled: true,
                                                  presentation: .text,
                                                  shareCardURL: links[0]).isEmpty)
        #expect(TextRoomTimelineView.metadataURLs(links: links,
                                                  enabled: false,
                                                  presentation: .card,
                                                  shareCardURL: links[0]).isEmpty)
        #expect(TextRoomTimelineView.metadataURLs(links: links,
                                                  enabled: true,
                                                  presentation: .card,
                                                  shareCardURL: links[0]) == [links[0]])
    }
}
