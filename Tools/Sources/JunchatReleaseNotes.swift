import Foundation

enum JunchatReleaseNotes {
    enum ReleaseNotesError: LocalizedError {
        case invalidChangelog
        case invalidReleaseDate
        case missingReleaseNotes
        case conflictingReleaseNotes

        var errorDescription: String? {
            switch self {
            case .invalidChangelog:
                "JUNCHAT_CHANGES.md must begin with the JunChat iOS heading"
            case .invalidReleaseDate:
                "Release date must use YYYY-MM-DD"
            case .missingReleaseNotes:
                "Generated release notes are empty"
            case .conflictingReleaseNotes:
                "JUNCHAT_CHANGES.md already contains conflicting notes for this version"
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
        guard isValidISODate(releaseDate) else {
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

        let entry = "## Changes in \(version) (\(releaseDate))\n\(cleanedNotes)"
        let existingBody = String(existingContent
            .dropFirst(heading.count)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let releaseHeading = try NSRegularExpression(pattern: #"(?m)^## Changes in [^\r\n]+ \([^\r\n]+\)$"#)
        let releaseMatches = releaseHeading.matches(in: existingBody,
                                                    range: NSRange(existingBody.startIndex..., in: existingBody))
        let firstReleaseIndex = releaseMatches.first
            .flatMap { Range($0.range, in: existingBody)?.lowerBound }
        let introduction = firstReleaseIndex
            .map { String(existingBody[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? existingBody
        let previousReleases = firstReleaseIndex
            .map { String(existingBody[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""

        if !previousReleases.isEmpty {
            let escapedVersion = NSRegularExpression.escapedPattern(for: version)
            let versionPattern = try NSRegularExpression(pattern: "(?m)^## Changes in \(escapedVersion) \\([^\\r\\n]+\\)$")
            let versionMatches = versionPattern.matches(in: previousReleases,
                                                        range: NSRange(previousReleases.startIndex..., in: previousReleases))
            guard versionMatches.count <= 1 else {
                throw ReleaseNotesError.conflictingReleaseNotes
            }
            if let match = versionMatches.first,
               let matchRange = Range(match.range, in: previousReleases) {
                let remainder = NSRange(matchRange.upperBound..<previousReleases.endIndex,
                                        in: previousReleases)
                let nextReleaseIndex = releaseHeading.firstMatch(in: previousReleases, range: remainder)
                    .flatMap { Range($0.range, in: previousReleases)?.lowerBound }
                let endIndex = nextReleaseIndex ?? previousReleases.endIndex
                let existingEntry = String(previousReleases[matchRange.lowerBound..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard existingEntry == entry else {
                    throw ReleaseNotesError.conflictingReleaseNotes
                }
                return existingContent
            }
        }

        let sections = [heading, introduction, entry, previousReleases].filter { !$0.isEmpty }
        return sections.joined(separator: "\n\n") + "\n"
    }

    @discardableResult
    static func updateChangelogFile(at url: URL,
                                    version: String,
                                    generatedNotes: String,
                                    releaseDate: String) throws -> Bool {
        let existingContent = try String(contentsOf: url, encoding: .utf8)
        let updatedContent = try updatedChangelog(existingContent: existingContent,
                                                  version: version,
                                                  generatedNotes: generatedNotes,
                                                  releaseDate: releaseDate)
        guard updatedContent != existingContent else { return false }

        try JunchatReleaseFile.write(updatedContent, to: url)
        return true
    }

    static func isValidISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ part in part.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return false }
        calendar.timeZone = utc
        let components = DateComponents(calendar: calendar,
                                        timeZone: calendar.timeZone,
                                        year: year,
                                        month: month,
                                        day: day)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}
