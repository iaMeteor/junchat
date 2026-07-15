import Foundation
@testable import Tools
import XCTest

final class JunchatReleaseVersionTests: XCTestCase {
    private let projectYAML = """
    settings:
      MARKETING_VERSION: 1.8.2
      CURRENT_PROJECT_VERSION: 37
      SUPPORTS_MACCATALYST: false
    """

    func testReadsTheVersionMetadataUsedByXcodeGen() throws {
        let metadata = try JunchatReleaseVersion.parse(projectYAML)

        XCTAssertEqual(metadata, JunchatReleaseVersion(name: "1.8.2", build: 37))
    }

    func testUpdatesOnlyTheVersionMetadataUsedByXcodeGen() throws {
        let updated = try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                                   name: "1.8.3",
                                                                   build: 38)

        XCTAssertTrue(updated.contains("MARKETING_VERSION: 1.8.3"))
        XCTAssertTrue(updated.contains("CURRENT_PROJECT_VERSION: 38"))
        XCTAssertTrue(updated.contains("SUPPORTS_MACCATALYST: false"))
    }

    func testRequiresSemanticVersioningAndAnIncreasingBuildNumber() throws {
        let invalidTargets = [
            (name: "1.8", build: 38),
            (name: "01.8.3", build: 38),
            (name: "1.8.1", build: 38),
            (name: "1.8.3", build: 37),
            (name: "1.8.2", build: 37)
        ]

        for target in invalidTargets {
            XCTAssertThrowsError(try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                                              name: target.name,
                                                                              build: target.build))
        }
    }

    func testAllowsAnExactNoOpWhenResumingPreparedReleaseState() throws {
        XCTAssertEqual(try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                                    name: "1.8.2",
                                                                    build: 37,
                                                                    allowExactNoOp: true),
                       projectYAML)
    }

    func testAllowsARebuildOfTheSameMarketingVersion() throws {
        let updated = try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                                   name: "1.8.2",
                                                                   build: 38)

        XCTAssertTrue(updated.contains("MARKETING_VERSION: 1.8.2"))
        XCTAssertTrue(updated.contains("CURRENT_PROJECT_VERSION: 38"))
    }

    func testRejectsMissingOrDuplicateMetadata() throws {
        let invalidSources = [
            projectYAML.replacingOccurrences(of: "  MARKETING_VERSION: 1.8.2\n", with: ""),
            projectYAML + "\nMARKETING_VERSION: 9.9.9\n",
            projectYAML.replacingOccurrences(of: "  CURRENT_PROJECT_VERSION: 37\n", with: ""),
            projectYAML + "\nCURRENT_PROJECT_VERSION: 99\n"
        ]

        for source in invalidSources {
            XCTAssertThrowsError(try JunchatReleaseVersion.parse(source))
        }
    }

    func testComputesTheNextPatchAndBuildWithoutCalendarSemantics() throws {
        let current = try JunchatReleaseVersion.parse(projectYAML)

        XCTAssertEqual(try current.nextPatch(), JunchatReleaseVersion(name: "1.8.3", build: 38))
    }

    func testUpdatesTheProjectFileAtomicallyAndPreservesPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appending(path: "project.yml")
        try projectYAML.write(to: projectURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: projectURL.path)

        XCTAssertTrue(try JunchatReleaseVersion.updateProjectFile(at: projectURL,
                                                                  name: "1.8.3",
                                                                  build: 38))
        XCTAssertEqual(try JunchatReleaseVersion.parse(String(contentsOf: projectURL, encoding: .utf8)),
                       JunchatReleaseVersion(name: "1.8.3", build: 38))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: projectURL.path)[.posixPermissions] as? Int,
                       0o640)
        XCTAssertFalse(try JunchatReleaseVersion.updateProjectFile(at: projectURL,
                                                                   name: "1.8.3",
                                                                   build: 38))
    }

    func testSetCommandRegeneratesTheXcodeProjectWhenMetadataAlreadyMatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appending(path: "project.yml")
        try projectYAML.write(to: projectURL, atomically: true, encoding: .utf8)
        var generationCount = 0

        let changed = try SetJunchatReleaseVersion.updateProject(at: projectURL,
                                                                 versionName: "1.8.2",
                                                                 buildNumber: 37) {
            generationCount += 1
        }

        XCTAssertFalse(changed)
        XCTAssertEqual(generationCount, 1)
    }

    func testSetCommandDoesNotReportSuccessWhenRetryGenerationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appending(path: "project.yml")
        try projectYAML.write(to: projectURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SetJunchatReleaseVersion.updateProject(at: projectURL,
                                                                        versionName: "1.8.2",
                                                                        buildNumber: 37) {
                throw StubError.xcodeGenFailed
            })
    }

    private enum StubError: Error {
        case xcodeGenFailed
    }
}
