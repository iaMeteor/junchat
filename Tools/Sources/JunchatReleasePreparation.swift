import Foundation

struct JunchatReleasePreparation: Equatable {
    enum PreparationError: LocalizedError {
        case malformedMarker
        case dirtyTrackedState
        case unexpectedParent
        case unexpectedVersion
        case unexpectedChangedPaths

        var errorDescription: String? {
            switch self {
            case .malformedMarker:
                "The release preparation commit marker is malformed."
            case .dirtyTrackedState:
                "Release preparation requires a clean worktree and index."
            case .unexpectedParent:
                "The release preparation commit does not have the archived commit as its only parent."
            case .unexpectedVersion:
                "The release preparation commit does not contain the expected next version and build."
            case .unexpectedChangedPaths:
                "The release preparation commit changed files outside the release metadata boundary."
            }
        }
    }

    static let subject = "Prepare next release"
    static let expectedChangedPaths = Set([
        "JUNCHAT_CHANGES.md",
        "project.yml",
        "ElementX.xcodeproj/project.pbxproj"
    ])

    let releaseVersion: JunchatReleaseVersion
    let releaseCommit: String
    let releaseDate: String

    init(releaseVersion: JunchatReleaseVersion,
         releaseCommit: String,
         releaseDate: String) throws {
        try JunchatReleaseVersion.validateMarketingVersion(releaseVersion.name)
        guard releaseVersion.build > 0,
              Self.isCommitHash(releaseCommit),
              JunchatReleaseNotes.isValidISODate(releaseDate) else {
            throw PreparationError.malformedMarker
        }

        self.releaseVersion = releaseVersion
        self.releaseCommit = releaseCommit
        self.releaseDate = releaseDate
    }

    var commitMessage: String {
        [
            Self.subject,
            "",
            "Junchat-Release-Version: \(releaseVersion.name)",
            "Junchat-Release-Build: \(releaseVersion.build)",
            "Junchat-Release-Commit: \(releaseCommit)",
            "Junchat-Release-Date: \(releaseDate)"
        ].joined(separator: "\n")
    }

    static func parseIfPresent(_ commitMessage: String) throws -> JunchatReleasePreparation? {
        let normalized = commitMessage.trimmingCharacters(in: .newlines)
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == subject else { return nil }
        guard lines.count == 6,
              lines[1].isEmpty,
              let version = value(in: lines[2], after: "Junchat-Release-Version: "),
              let buildValue = value(in: lines[3], after: "Junchat-Release-Build: "),
              let build = Int(buildValue),
              let releaseCommit = value(in: lines[4], after: "Junchat-Release-Commit: "),
              let releaseDate = value(in: lines[5], after: "Junchat-Release-Date: ") else {
            throw PreparationError.malformedMarker
        }

        return try JunchatReleasePreparation(releaseVersion: .init(name: version, build: build),
                                             releaseCommit: releaseCommit,
                                             releaseDate: releaseDate)
    }

    static func validateCleanRepositoryStatus(_ status: String) throws {
        guard status.isEmpty else {
            throw PreparationError.dirtyTrackedState
        }
    }

    func validateResume(parentCommits: [String],
                        currentVersion: JunchatReleaseVersion,
                        changedPaths: [String]) throws {
        guard parentCommits == [releaseCommit] else {
            throw PreparationError.unexpectedParent
        }
        guard try currentVersion == (releaseVersion.nextPatch()) else {
            throw PreparationError.unexpectedVersion
        }

        guard changedPaths.count == Self.expectedChangedPaths.count,
              Set(changedPaths) == Self.expectedChangedPaths else {
            throw PreparationError.unexpectedChangedPaths
        }
    }

    private static func value(in line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    private static func isCommitHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }
}
