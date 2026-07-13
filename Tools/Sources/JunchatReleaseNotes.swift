import Foundation

enum JunchatReleaseNotes {
    enum ReleaseNotesError: LocalizedError {
        case invalidChangelog
        case invalidReleaseDate
        case missingReleaseNotes

        var errorDescription: String? {
            switch self {
            case .invalidChangelog:
                "JUNCHAT_CHANGES.md must begin with the JunChat iOS heading"
            case .invalidReleaseDate:
                "Release date must use YYYY-MM-DD"
            case .missingReleaseNotes:
                "Generated release notes are empty"
            }
        }
    }

    static let heading = "# JunChat iOS Changes"

    static func updatedChangelog(existingContent: String,
                                 version: String,
                                 generatedNotes: String,
                                 releaseDate: String) throws -> String {
        try JunchatReleaseVersion.validateMarketingVersion(version)
        guard existingContent == heading || existingContent.hasPrefix("\(heading)\n") else {
            throw ReleaseNotesError.invalidChangelog
        }
        guard isISODate(releaseDate) else {
            throw ReleaseNotesError.invalidReleaseDate
        }

        let withoutComments = generatedNotes.replacingOccurrences(of: #"<!--(?s:.*?)-->"#,
                                                                  with: "",
                                                                  options: .regularExpression)
        let cleanedNotes = withoutComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.hasPrefix("### ") { return "#\(line)" }
                if line.hasPrefix("## ") { return "#\(line)" }
                return String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedNotes.isEmpty else {
            throw ReleaseNotesError.missingReleaseNotes
        }

        let existingBody = existingContent
            .dropFirst(heading.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousContent = existingBody.isEmpty ? "" : "\n\n\(existingBody)"
        return "\(heading)\n\n## Changes in \(version) (\(releaseDate))\n\(cleanedNotes)\(previousContent)"
    }

    private static func isISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 &&
            parts[0].count == 4 &&
            parts[1].count == 2 &&
            parts[2].count == 2 &&
            parts.allSatisfy { part in
                part.allSatisfy { $0.isASCII && $0.isNumber }
            }
    }
}
