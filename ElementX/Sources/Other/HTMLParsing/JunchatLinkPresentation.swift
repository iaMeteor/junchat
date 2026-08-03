//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum JunchatLinkPresentation: String, CaseIterable, Hashable {
    case card
    case text

    private static let marker = #"data-junchat-link-presentation="text""#
    private static let wrapperPrefix = #"<div data-junchat-link-presentation="text">"#
    private static let plainDraftHTML = #"<div data-junchat-link-presentation="text" data-junchat-composer-draft="plain"></div>"#

    static func encodedPresentation(in formattedBody: String?) -> Self {
        formattedBody?.contains(marker) == true ? .text : .card
    }

    static func formattedBody(plain: String, html: String?, presentation: Self) -> String? {
        guard presentation == .text else {
            return html
        }

        let content = html ?? linkifiedHTML(from: plain)
        return wrapperPrefix + content + "</div>"
    }

    static func draftHTML(html: String?, presentation: Self) -> String? {
        guard presentation == .text else {
            return html
        }
        guard let html else {
            return plainDraftHTML
        }
        return wrapperPrefix + html + "</div>"
    }

    static func decodeDraftHTML(_ html: String?) -> (html: String?, presentation: Self) {
        guard encodedPresentation(in: html) == .text else {
            return (html, .card)
        }
        guard let html else {
            return (nil, .text)
        }
        if html == plainDraftHTML {
            return (nil, .text)
        }
        guard html.hasPrefix(wrapperPrefix), html.hasSuffix("</div>") else {
            return (html, .text)
        }

        let contentStart = html.index(html.startIndex, offsetBy: wrapperPrefix.count)
        let contentEnd = html.index(html.endIndex, offsetBy: -"</div>".count)
        return (String(html[contentStart..<contentEnd]), .text)
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
            if let url = match.url, isExternalWebURL(url) {
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

    private static func isExternalWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.lowercased() != "matrix.to"
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
