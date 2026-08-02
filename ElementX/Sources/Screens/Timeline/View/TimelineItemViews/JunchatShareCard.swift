//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum JunchatLinkPresentation: String, CaseIterable, Hashable {
    case card
    case text

    private static let marker = #"data-junchat-link-presentation="text""#

    static func encodedPresentation(in formattedBody: String?) -> Self {
        formattedBody?.contains(marker) == true ? .text : .card
    }

    static func formattedBody(plain: String, html: String?, presentation: Self) -> String? {
        guard presentation == .text else {
            return html
        }

        let content = html ?? linkifiedHTML(from: plain)
        return #"<div data-junchat-link-presentation="text">"# + content + "</div>"
    }

    private static func linkifiedHTML(from text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = MatrixEntityRegex.linkRegex.matches(in: text, options: [], range: range)
        let string = text as NSString
        var location = 0
        var result = ""

        for match in matches where match.resultType == .link {
            let prefixRange = NSRange(location: location, length: match.range.location - location)
            result += escapedHTML(string.substring(with: prefixRange))

            let displayText = string.substring(with: match.range)
            if let url = match.url, url.junchatIsExternalWebURL {
                result += #"<a href=""# + escapedHTML(url.absoluteString) + #"">"#
                    + escapedHTML(displayText) + "</a>"
            } else {
                result += escapedHTML(displayText)
            }
            location = NSMaxRange(match.range)
        }

        if location < string.length {
            result += escapedHTML(string.substring(from: location))
        }

        return result.replacingOccurrences(of: "\n", with: "<br />")
    }

    private static func escapedHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct JunchatShareCard: Equatable {
    private struct DetectedURL {
        let url: URL
        let source: String
    }

    let url: URL
    let title: String
    let summary: String?
    let host: String
    let shouldReplaceBody: Bool

    static func parse(body: String, links: [URL] = []) -> JunchatShareCard? {
        let detectedURLs = detectURLs(in: body)
        guard let url = detectedURLs.first?.url ?? links.first(where: \.junchatIsExternalWebURL),
              url.junchatIsExternalWebURL else {
            return nil
        }

        let urlStrings = detectedURLs.map(\.source) + [url.absoluteString]
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let textCandidates = lines
            .map { strippedShareText(from: $0, urlStrings: urlStrings) }
            .filter { !$0.isEmpty }

        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        let title = textCandidates.first ?? host
        let summary = textCandidates.dropFirst().first { $0 != title }
        let bodyWithoutURLs = strippedShareText(from: body, urlStrings: urlStrings)
        let shouldReplaceBody = bodyWithoutURLs.isEmpty

        return JunchatShareCard(url: url,
                                title: title.junchatShareCardLimited(to: 96),
                                summary: summary?.junchatShareCardLimited(to: 160),
                                host: host,
                                shouldReplaceBody: shouldReplaceBody)
    }

    private static func detectURLs(in text: String) -> [DetectedURL] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let string = text as NSString
        return MatrixEntityRegex.linkRegex.matches(in: text, options: [], range: nsRange)
            .compactMap { match in
                guard let url = match.url, url.junchatIsExternalWebURL else {
                    return nil
                }

                return DetectedURL(url: url, source: string.substring(with: match.range))
            }
    }

    private static func strippedShareText(from text: String, urlStrings: [String]) -> String {
        var result = text
        for urlString in urlStrings {
            result = result.replacingOccurrences(of: urlString, with: "")
        }

        return result
            .replacingOccurrences(of: #"[\s　]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

struct JunchatShareCardView: View {
    let card: JunchatShareCard
    let metadata: LPLinkMetadata?
    let onOpen: () -> Void

    @State private var previewImage: UIImage?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(metadata?.title?.nilIfBlank ?? card.title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let summary = card.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.caption)
                    Text(card.host)
                        .lineLimit(1)
                }
                .font(.compound.bodyXS)
                .foregroundStyle(.compound.textSecondary)
            }

            Spacer(minLength: 8)

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.compound.iconSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.compound.bgCanvasDefault, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.compound.separatorPrimary, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .task(id: previewImageTaskID) {
            previewImage = await JunchatSharePreviewImage.load(from: metadata)
        }
    }

    private var previewImageTaskID: String {
        let provider = metadata?.imageProvider ?? metadata?.iconProvider
        let providerTypes = provider?.registeredTypeIdentifiers.joined(separator: ",") ?? "none"
        return "\(card.url.absoluteString)|\(providerTypes)|\(provider?.suggestedName ?? "")"
    }
}

enum JunchatSharePreviewImage {
    static func load(from metadata: LPLinkMetadata?) async -> UIImage? {
        guard let provider = metadata?.imageProvider ?? metadata?.iconProvider else {
            return nil
        }

        if provider.canLoadObject(ofClass: UIImage.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }

        guard let imageTypeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) ?? false
        }) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                continuation.resume(returning: data.flatMap { UIImage(data: $0) })
            }
        }
    }
}

private extension URL {
    var junchatIsExternalWebURL: Bool {
        guard let scheme = scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        let host = host?.lowercased()
        return host != "matrix.to"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func junchatShareCardLimited(to limit: Int) -> String {
        guard count > limit else {
            return self
        }

        return String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
