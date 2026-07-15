@testable import Tools
import XCTest

final class JunchatReleasePreflightTests: XCTestCase {
    func testCompletesLocalPreparationBeforeRemoteMutation() async throws {
        var events = [String]()

        let (preparation, remoteResult) = try await JunchatReleasePreflight.prepareBeforeRemoteMutation(projectYAML: validProjectYAML,
                                                                                                        changelog: validChangelog,
                                                                                                        xcodeProject: validXcodeProject,
                                                                                                        releaseDate: "2026-07-16",
                                                                                                        generateXcodeProject: { updatedProject in
                                                                                                            XCTAssertTrue(updatedProject.contains("MARKETING_VERSION: 1.8.3"))
                                                                                                            events.append("xcodegen")
                                                                                                            return generatedXcodeProject
                                                                                                        },
                                                                                                        remoteMutation: { _ in
                                                                                                            events.append("remote")
                                                                                                            return "Generated notes"
                                                                                                        })

        XCTAssertEqual(preparation.currentVersion, JunchatReleaseVersion(name: "1.8.2", build: 37))
        XCTAssertEqual(preparation.nextVersion, JunchatReleaseVersion(name: "1.8.3", build: 38))
        XCTAssertEqual(remoteResult, "Generated notes")
        XCTAssertEqual(events, ["xcodegen", "remote"])
    }

    func testChangelogParseFailurePreventsRemoteMutation() async {
        await assertPreflightFailure(projectYAML: validProjectYAML,
                                     changelog: "# Wrong heading\n") { _ in generatedXcodeProject }
    }

    func testVersionOverflowPreventsRemoteMutation() async {
        let overflowingProject = validProjectYAML
            .replacingOccurrences(of: "CURRENT_PROJECT_VERSION: 37",
                                  with: "CURRENT_PROJECT_VERSION: \(Int.max)")
        await assertPreflightFailure(projectYAML: overflowingProject,
                                     changelog: validChangelog) { _ in generatedXcodeProject }
    }

    func testInvalidMetadataPreventsRemoteMutation() async {
        await assertPreflightFailure(projectYAML: validProjectYAML + "MARKETING_VERSION: 9.9.9\n",
                                     changelog: validChangelog) { _ in generatedXcodeProject }
    }

    func testXcodeGenFailurePreventsRemoteMutation() async {
        await assertPreflightFailure(projectYAML: validProjectYAML,
                                     changelog: validChangelog) { _ in throw StubError.xcodeGenFailed }
    }

    private func assertPreflightFailure(projectYAML: String,
                                        changelog: String,
                                        generateXcodeProject: (String) async throws -> String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async {
        var performedRemoteMutation = false

        do {
            _ = try await JunchatReleasePreflight.prepareBeforeRemoteMutation(projectYAML: projectYAML,
                                                                              changelog: changelog,
                                                                              xcodeProject: validXcodeProject,
                                                                              releaseDate: "2026-07-16",
                                                                              generateXcodeProject: generateXcodeProject) { _ in
                performedRemoteMutation = true
                return "Generated notes"
            }
            XCTFail("Expected local release preparation to fail", file: file, line: line)
        } catch { }

        XCTAssertFalse(performedRemoteMutation, file: file, line: line)
    }

    private enum StubError: Error {
        case xcodeGenFailed
    }
}

private let validProjectYAML = """
settings:
  MARKETING_VERSION: 1.8.2
  CURRENT_PROJECT_VERSION: 37
"""

private let validChangelog = """
# JunChat iOS Changes

JunChat fork release notes are recorded here.
"""

private let validXcodeProject = """
buildSettings = {
    CURRENT_PROJECT_VERSION = 37;
    MARKETING_VERSION = 1.8.2;
};
"""

private let generatedXcodeProject = """
buildSettings = {
    CURRENT_PROJECT_VERSION = 38;
    MARKETING_VERSION = 1.8.3;
};
"""
