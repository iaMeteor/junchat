@testable import Tools
import XCTest

final class JunchatReleasePreparationTests: XCTestCase {
    private let releaseCommit = String(repeating: "a", count: 40)

    func testMarkerRoundTripsThroughTheCommitMessage() throws {
        let marker = try makeMarker()

        XCTAssertEqual(marker.commitMessage.components(separatedBy: "\n").first,
                       JunchatReleasePreparation.subject,
                       String(reflecting: marker.commitMessage))
        XCTAssertEqual(try JunchatReleasePreparation.parseIfPresent(marker.commitMessage + "\n"), marker)
        XCTAssertNil(try JunchatReleasePreparation.parseIfPresent("Regular product commit\n"))
    }

    func testPreparationSubjectWithoutExactTrailersFailsClosed() throws {
        XCTAssertThrowsError(try JunchatReleasePreparation.parseIfPresent("Prepare next release\n"))
        let invalidDateMarker = [
            "Prepare next release",
            "",
            "Junchat-Release-Version: 1.8.2",
            "Junchat-Release-Build: 37",
            "Junchat-Release-Commit: \(releaseCommit)",
            "Junchat-Release-Date: 2026-02-30"
        ].joined(separator: "\n")
        XCTAssertThrowsError(try JunchatReleasePreparation.parseIfPresent(invalidDateMarker))
    }

    func testRepositoryChangesFailBeforeReleasePreparation() {
        XCTAssertNoThrow(try JunchatReleasePreparation.validateCleanRepositoryStatus(""))
        XCTAssertThrowsError(try JunchatReleasePreparation.validateCleanRepositoryStatus("M  unrelated.swift\n"))
        XCTAssertThrowsError(try JunchatReleasePreparation.validateCleanRepositoryStatus(" M project.yml\n"))
        XCTAssertThrowsError(try JunchatReleasePreparation.validateCleanRepositoryStatus("?? untracked.txt\u{0}"))
    }

    func testValidPreparationCommitCanResumeIdempotently() throws {
        let marker = try makeMarker()

        XCTAssertNoThrow(try marker.validateResume(parentCommits: [releaseCommit],
                                                   currentVersion: JunchatReleaseVersion(name: "1.8.3", build: 38),
                                                   changedPaths: [
                                                       "JUNCHAT_CHANGES.md",
                                                       "project.yml",
                                                       "ElementX.xcodeproj/project.pbxproj"
                                                   ]))
    }

    func testResumeRejectsTheWrongParentVersionOrChangedPath() throws {
        let marker = try makeMarker()

        XCTAssertThrowsError(try marker.validateResume(parentCommits: [String(repeating: "b", count: 40)],
                                                       currentVersion: JunchatReleaseVersion(name: "1.8.3", build: 38),
                                                       changedPaths: ["project.yml"]))
        XCTAssertThrowsError(try marker.validateResume(parentCommits: [releaseCommit],
                                                       currentVersion: JunchatReleaseVersion(name: "1.8.4", build: 39),
                                                       changedPaths: ["project.yml"]))
        XCTAssertThrowsError(try marker.validateResume(parentCommits: [releaseCommit],
                                                       currentVersion: JunchatReleaseVersion(name: "1.8.3", build: 38),
                                                       changedPaths: ["Unrelated.swift"]))
        XCTAssertThrowsError(try marker.validateResume(parentCommits: [releaseCommit],
                                                       currentVersion: JunchatReleaseVersion(name: "1.8.3", build: 38),
                                                       changedPaths: [
                                                           "JUNCHAT_CHANGES.md",
                                                           "project.yml",
                                                           "ElementX.xcodeproj/project.pbxproj",
                                                           "ElementX.xcodeproj/unexpected.txt"
                                                       ]))
        XCTAssertThrowsError(try marker.validateResume(parentCommits: [releaseCommit, String(repeating: "c", count: 40)],
                                                       currentVersion: JunchatReleaseVersion(name: "1.8.3", build: 38),
                                                       changedPaths: ["project.yml"]))
    }

    func testResumeRejectsUnrelatedContentWithinEveryAllowedFile() throws {
        let marker = try makeMarker()
        let archivedProject = """
        settings:
          MARKETING_VERSION: 1.8.2
          CURRENT_PROJECT_VERSION: 37
        """
        let preparedProject = """
        settings:
          MARKETING_VERSION: 1.8.3
          CURRENT_PROJECT_VERSION: 38
        """
        let archivedChangelog = "# JunChat iOS Changes\n\nJunChat fork release notes are recorded here."
        let preparedChangelog = try JunchatReleaseNotes.updatedChangelog(existingContent: archivedChangelog,
                                                                         version: marker.releaseVersion.name,
                                                                         generatedNotes: "- Fixed retry",
                                                                         releaseDate: marker.releaseDate)
        let archivedXcodeProject = """
        buildSettings = {
            CURRENT_PROJECT_VERSION = 37;
            MARKETING_VERSION = 1.8.2;
        };
        """
        let preparedXcodeProject = """
        buildSettings = {
            CURRENT_PROJECT_VERSION = 38;
            MARKETING_VERSION = 1.8.3;
        };
        """

        func validate(project: String = preparedProject,
                      changelog: String = preparedChangelog,
                      xcodeProject: String = preparedXcodeProject) throws {
            try marker.validatePreparedContents(archivedProjectYAML: archivedProject,
                                                preparedProjectYAML: project,
                                                archivedChangelog: archivedChangelog,
                                                preparedChangelog: changelog,
                                                archivedXcodeProject: archivedXcodeProject,
                                                preparedXcodeProject: xcodeProject,
                                                generatedNotes: "- Fixed retry")
        }

        XCTAssertNoThrow(try validate())
        XCTAssertThrowsError(try validate(project: preparedProject + "# unrelated\n"))
        XCTAssertThrowsError(try validate(changelog: preparedChangelog + "Unrelated\n"))
        XCTAssertThrowsError(try validate(xcodeProject: preparedXcodeProject + "// unrelated\n"))
    }

    private func makeMarker() throws -> JunchatReleasePreparation {
        try JunchatReleasePreparation(releaseVersion: JunchatReleaseVersion(name: "1.8.2", build: 37),
                                      releaseCommit: releaseCommit,
                                      releaseDate: "2026-07-14")
    }
}
