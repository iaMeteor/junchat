//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import OrderedCollections
import SwiftUI
import UIKit

struct TextRoomTimelineView: View, TextBasedRoomTimelineViewProtocol {
    private struct MetadataTaskID: Hashable {
        let presentation: JunchatLinkPresentation
        let shareCardURL: URL?
        let links: [URL]
    }

    static let maxLinkPreviewsToRender = 2

    @Environment(\.timelineContext) private var context
    let timelineItem: TextRoomTimelineItem

    @State private var linkMetadata: OrderedDictionary<URL, LinkMetadataProviderItem>

    init(timelineItem: TextRoomTimelineItem, linkMetadata: OrderedDictionary<URL, LinkMetadataProviderItem> = [:]) {
        self.timelineItem = timelineItem
        self.linkMetadata = linkMetadata
    }

    static func linkPreviewURLs(links: [URL], enabled: Bool) -> [URL] {
        guard enabled else {
            return []
        }

        return Array(links.prefix(maxLinkPreviewsToRender))
    }

    static func metadataURLs(links: [URL],
                             enabled: Bool,
                             presentation: JunchatLinkPresentation,
                             shareCardURL: URL?) -> [URL] {
        guard presentation == .card, enabled else {
            return []
        }

        if let shareCardURL {
            return [shareCardURL]
        }

        return linkPreviewURLs(links: links, enabled: true)
    }

    var body: some View {
        let shareCard = JunchatShareCard.parse(body: timelineItem.body, links: timelineItem.links)
        let presentation = context?.viewState.linkPresentationOverrides[timelineItem.id]
            ?? JunchatLinkPresentation.encodedPresentation(in: timelineItem.content.formattedBodyHTMLString)
        let previewURLs = Self.metadataURLs(links: timelineItem.links,
                                            enabled: context?.viewState.linkPreviewsEnabled ?? false,
                                            presentation: presentation,
                                            shareCardURL: shareCard?.url)
        let renderedPreviewURLs = previewURLs.filter { linkMetadata[$0] != nil }
        let shareCardMetadata = shareCard.flatMap {
            linkMetadata[$0.url]?.metadata ?? context?.viewState.linkMetadataProvider?.metadataItems[$0.url]?.metadata
        }
        let metadataTaskID = MetadataTaskID(presentation: presentation,
                                            shareCardURL: shareCard?.url,
                                            links: timelineItem.links)

        TimelineStyler(timelineItem: timelineItem) {
            VStack(alignment: .leading, spacing: 8) {
                if let shareCard, presentation == .card, shareCard.shouldReplaceBody {
                    JunchatShareCardView(card: shareCard, metadata: shareCardMetadata) {
                        UIApplication.shared.open(shareCard.url)
                    }
                } else {
                    messageBody

                    if let shareCard, presentation == .card {
                        JunchatShareCardView(card: shareCard, metadata: shareCardMetadata) {
                            UIApplication.shared.open(shareCard.url)
                        }
                    } else if !renderedPreviewURLs.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(renderedPreviewURLs, id: \.absoluteString) { url in
                                let metadata = linkMetadata[url]?.metadata ?? context?.viewState.linkMetadataProvider?.metadataItems[url]?.metadata
                                LinkPreviewView(url: url, metadata: metadata)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .task(id: metadataTaskID) { await fetchLinkPreviews() }
    }

    @ViewBuilder
    private var messageBody: some View {
        if let attributedString = timelineItem.content.formattedBody {
            FormattedBodyText(attributedString: attributedString,
                              additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                              boostFontSize: timelineItem.shouldBoost)
        } else {
            FormattedBodyText(text: timelineItem.body,
                              additionalWhitespacesCount: timelineItem.additionalWhitespaces(),
                              boostFontSize: timelineItem.shouldBoost)
        }
    }

    private func fetchLinkPreviews() async {
        guard let metadataProvider = context?.viewState.linkMetadataProvider else {
            return
        }

        let shareCard = JunchatShareCard.parse(body: timelineItem.body, links: timelineItem.links)
        let presentation = context?.viewState.linkPresentationOverrides[timelineItem.id]
            ?? JunchatLinkPresentation.encodedPresentation(in: timelineItem.content.formattedBodyHTMLString)
        let linkPreviewsEnabled = context?.viewState.linkPreviewsEnabled ?? false
        let urls = Self.metadataURLs(links: timelineItem.links,
                                     enabled: linkPreviewsEnabled,
                                     presentation: presentation,
                                     shareCardURL: shareCard?.url)

        for url in urls {
            if case let .success(metadata) = await metadataProvider.fetchMetadataFor(url: url) {
                await MainActor.run {
                    linkMetadata[url] = metadata
                }
            }
        }
    }
}

struct TextRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock

    static var previews: some View {
        body.environmentObject(viewModel.context)
            .previewDisplayName("Bubble")
            .previewLayout(.sizeThatFits)
        body
            .environmentObject(viewModel.context)
            .environment(\.layoutDirection, .rightToLeft)
            .previewDisplayName("Bubble RTL")
            .previewLayout(.sizeThatFits)
    }

    static var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20.0) {
                TextRoomTimelineView(timelineItem: itemWith(text: "Short loin ground round tongue hamburger, fatback salami shoulder. Beef turkey sausage kielbasa strip steak. Alcatra capicola pig tail pancetta chislic.",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))

                TextRoomTimelineView(timelineItem: itemWith(text: "Check out this cool website: https://www.apple.com and also https://github.com for some great projects!",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))

                TextRoomTimelineView(timelineItem: itemWith(text: "Short loin ground round tongue hamburger, fatback salami shoulder. Beef turkey sausage kielbasa strip steak. Alcatra capicola pig tail pancetta chislic.",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))

                TextRoomTimelineView(timelineItem: itemWith(text: "Some other text",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))

                TextRoomTimelineView(timelineItem: itemWith(text: "טקסט אחר",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))

                TextRoomTimelineView(timelineItem: itemWith(html: "<ol><li>First item</li><li>Second item</li><li>Third item</li></ol>",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))

                TextRoomTimelineView(timelineItem: itemWith(html: "<ol><li>פריט ראשון</li><li>הפריט השני</li><li>פריט שלישי</li></ol>",
                                                            timestamp: .mock,
                                                            isOutgoing: true,
                                                            senderId: "Anne"))

                // HTML with links for testing
                TextRoomTimelineView(timelineItem: itemWith(html: "Check out <a href=\"https://www.apple.com\">Apple's website</a> and <a href=\"https://github.com\">GitHub</a>!",
                                                            timestamp: .mock,
                                                            isOutgoing: false,
                                                            senderId: "Bob"))
            }
        }
    }

    private static func itemWith(text: String, timestamp: Date, isOutgoing: Bool, senderId: String) -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: .randomEvent,
                             timestamp: timestamp,
                             isOutgoing: isOutgoing,
                             isEditable: isOutgoing,
                             canBeRepliedTo: true,
                             sender: .init(id: senderId),
                             content: .init(body: text))
    }

    private static func itemWith(html: String, timestamp: Date, isOutgoing: Bool, senderId: String) -> TextRoomTimelineItem {
        let builder = AttributedStringBuilder(cacheKey: "preview", mentionBuilder: MentionBuilder())
        let attributedString = builder.fromHTML(html)

        return TextRoomTimelineItem(id: .randomEvent,
                                    timestamp: timestamp,
                                    isOutgoing: isOutgoing,
                                    isEditable: isOutgoing,
                                    canBeRepliedTo: true,
                                    sender: .init(id: senderId),
                                    content: .init(body: "", formattedBody: attributedString))
    }
}
