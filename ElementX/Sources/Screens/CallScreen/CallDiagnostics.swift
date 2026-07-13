//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum CallDiagnostics {
    static func urlSummary(_ url: URL?) -> String {
        guard let url else {
            return "scheme=none hostPresent=false pathComponents=0 queryPresent=false fragmentPresent=false"
        }

        let scheme = switch url.scheme?.lowercased() {
        case "file": "file"
        case "http": "http"
        case "https": "https"
        case nil: "none"
        default: "other"
        }
        let pathComponentCount = url.pathComponents.filter { $0 != "/" }.count
        return "scheme=\(scheme) hostPresent=\(url.host != nil) pathComponents=\(pathComponentCount) queryPresent=\(url.query != nil) fragmentPresent=\(url.fragment != nil)"
    }

    static func jsonSummary(_ json: String) -> String {
        let firstCharacter = json.first { !$0.isWhitespace }
        let shape = switch firstCharacter {
        case "{": "object"
        case "[": "array"
        case "\"": "string"
        case "t", "f": "bool"
        case "n": "null"
        case let character? where character.isNumber || character == "-": "number"
        default: "invalid"
        }
        return "bytes=\(json.utf8.count) shape=\(shape)"
    }

    static func textSummary(_ text: String) -> String {
        let lineCount = text.utf8.reduce(1) { count, byte in count + (byte == 0x0A ? 1 : 0) }
        return "bytes=\(text.utf8.count) lines=\(lineCount)"
    }

    static func dictionarySummary(_ dictionary: [AnyHashable: Any]) -> String {
        "keys=\(dictionary.count)"
    }

    static func errorSummary(_ error: Error) -> String {
        let errorCode = (error as NSError).code
        return "type=\(String(describing: type(of: error))) code=\(errorCode)"
    }

    static func valueSummary(_ value: Any?) -> String {
        guard let value else { return "shape=nil" }
        return "shape=\(valueShape(value))"
    }

    private static func valueShape(_ value: Any) -> String {
        switch value {
        case is Bool:
            "bool"
        case is String:
            "string"
        case is NSNumber:
            "number"
        case is [Any]:
            "array"
        case is [String: Any]:
            "object"
        case is NSNull:
            "null"
        default:
            "other"
        }
    }
}
