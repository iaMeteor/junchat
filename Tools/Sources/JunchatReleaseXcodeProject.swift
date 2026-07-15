import Foundation

enum JunchatReleaseXcodeProject {
    enum XcodeProjectError: LocalizedError {
        case unexpectedBuildSetting(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedBuildSetting(let name):
                "ElementX.xcodeproj contains unexpected literal values for \(name)."
            }
        }
    }

    static func updatedContent(_ content: String,
                               from currentVersion: JunchatReleaseVersion,
                               to nextVersion: JunchatReleaseVersion) throws -> String {
        let updatedVersion = try replacingBuildSetting("MARKETING_VERSION",
                                                       in: content,
                                                       currentValue: currentVersion.name,
                                                       nextValue: nextVersion.name)
        return try replacingBuildSetting("CURRENT_PROJECT_VERSION",
                                         in: updatedVersion,
                                         currentValue: String(currentVersion.build),
                                         nextValue: String(nextVersion.build))
    }

    private static func replacingBuildSetting(_ name: String,
                                              in content: String,
                                              currentValue: String,
                                              nextValue: String) throws -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let expression = try NSRegularExpression(pattern: #"(?m)^([ \t]*\#(escapedName)[ \t]*=[ \t]*)([^;\r\n]+)(;[ \t]*)$"#)
        let matches = expression.matches(in: content, range: NSRange(content.startIndex..., in: content))
        var updated = content
        var literalCount = 0

        for match in matches.reversed() {
            guard let valueRange = Range(match.range(at: 2), in: updated) else {
                throw XcodeProjectError.unexpectedBuildSetting(name)
            }
            let rawValue = String(updated[valueRange])
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            if value == "\"$(\(name))\"" || value == "$(\(name))" {
                continue
            }
            guard value == currentValue else {
                throw XcodeProjectError.unexpectedBuildSetting(name)
            }

            let leadingWhitespace = rawValue.prefix { $0 == " " || $0 == "\t" }
            let trailingWhitespace = rawValue.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
            updated.replaceSubrange(valueRange,
                                    with: String(leadingWhitespace) + nextValue + String(trailingWhitespace))
            literalCount += 1
        }

        guard literalCount > 0 else {
            throw XcodeProjectError.unexpectedBuildSetting(name)
        }
        return updated
    }
}
