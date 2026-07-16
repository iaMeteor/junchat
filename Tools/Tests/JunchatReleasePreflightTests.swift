import Foundation
@testable import Tools
import XCTest

final class JunchatReleasePreflightTests: XCTestCase {
    func testReleaseArtifactValidationAcceptsTheCanonicalArchiveInputs() async throws {
        let fixture = try ReleaseArchiveFixture()
        defer { fixture.remove() }
        var operationCount = 0

        try await JunchatReleasePreflight.performAfterValidatingReleaseArtifacts(environment: fixture.environment) { _ in
            operationCount += 1
        }

        XCTAssertEqual(operationCount, 1)
    }

    func testReleaseArtifactValidationRejectsMissingAndNoncanonicalArchivePathsBeforeSideEffects() async throws {
        for invalidArchivePath in [
            nil,
            "Junchat.xcarchive",
            "/tmp/../tmp/Junchat.xcarchive"
        ] {
            let fixture = try ReleaseArchiveFixture()
            defer { fixture.remove() }
            var environment = fixture.environment
            environment["CI_ARCHIVE_PATH"] = invalidArchivePath

            await assertReleaseArtifactFailure(environment: environment)
        }

        let fixture = try ReleaseArchiveFixture()
        defer { fixture.remove() }
        let archiveAlias = fixture.rootURL.appending(path: "Junchat-alias.xcarchive")
        try FileManager.default.createSymbolicLink(at: archiveAlias, withDestinationURL: fixture.archiveURL)
        var environment = fixture.environment
        environment["CI_ARCHIVE_PATH"] = archiveAlias.path

        await assertReleaseArtifactFailure(environment: environment)
    }

    func testReleaseArtifactValidationRejectsMalformedArchiveAndUnrelatedSignedAppBeforeSideEffects() async throws {
        let malformedPaths = [
            "Info.plist",
            "Products/Applications/Junchat.app",
            "Products/Applications/Junchat.app/Info.plist",
            "Products/Applications/Junchat.app/Junchat"
        ]

        for malformedPath in malformedPaths {
            let fixture = try ReleaseArchiveFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.archiveURL.appending(path: malformedPath))

            await assertReleaseArtifactFailure(environment: fixture.environment)
        }

        let fixture = try ReleaseArchiveFixture()
        defer { fixture.remove() }
        let unrelatedSignedApp = fixture.rootURL.appending(path: "Unrelated/Junchat.app")
        try FileManager.default.createDirectory(at: unrelatedSignedApp, withIntermediateDirectories: true)
        var environment = fixture.environment
        environment["CI_APP_STORE_SIGNED_APP_PATH"] = unrelatedSignedApp.path

        await assertReleaseArtifactFailure(environment: environment)
    }

    func testReleaseArtifactValidationRejectsMissingOrMalformedDSYMInputBeforeSideEffects() async throws {
        let malformedPaths = [
            "dSYMs",
            "dSYMs/Junchat.app.dSYM/Contents/Info.plist",
            "dSYMs/Junchat.app.dSYM/Contents/Resources/DWARF/Junchat"
        ]

        for malformedPath in malformedPaths {
            let fixture = try ReleaseArchiveFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.archiveURL.appending(path: malformedPath))

            await assertReleaseArtifactFailure(environment: fixture.environment)
        }
    }

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

    private func assertReleaseArtifactFailure(environment: [String: String],
                                              file: StaticString = #filePath,
                                              line: UInt = #line) async {
        var operationCount = 0

        do {
            try await JunchatReleasePreflight.performAfterValidatingReleaseArtifacts(environment: environment) { _ in
                operationCount += 1
            }
            XCTFail("Expected release artifact validation to fail", file: file, line: line)
        } catch { }

        XCTAssertEqual(operationCount, 0, file: file, line: line)
    }

    private enum StubError: Error {
        case xcodeGenFailed
    }
}

private final class ReleaseArchiveFixture {
    let rootURL: URL
    let archiveURL: URL

    private let fileManager = FileManager.default

    init() throws {
        rootURL = fileManager.temporaryDirectory
            .appending(path: "junchat-release-preflight-tests")
            .appending(path: UUID().uuidString)
        archiveURL = rootURL.appending(path: "Junchat.xcarchive")

        let appURL = archiveURL.appending(path: "Products/Applications/Junchat.app")
        let dwarfURL = archiveURL.appending(path: "dSYMs/Junchat.app.dSYM/Contents/Resources/DWARF/Junchat")
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dwarfURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try writePropertyList([
            "ApplicationProperties": [
                "ApplicationPath": "Applications/Junchat.app",
                "CFBundleIdentifier": "com.heyujk.junchat",
                "CFBundleShortVersionString": "1.8.2",
                "CFBundleVersion": "37"
            ],
            "ArchiveVersion": 2,
            "Name": "Junchat",
            "SchemeName": "Junchat"
        ], to: archiveURL.appending(path: "Info.plist"))
        try writePropertyList([
            "CFBundleExecutable": "Junchat",
            "CFBundleIdentifier": "com.heyujk.junchat",
            "CFBundleShortVersionString": "1.8.2",
            "CFBundleVersion": "37",
            "CFBundlePackageType": "APPL"
        ], to: appURL.appending(path: "Info.plist"))
        try writePropertyList([
            "CFBundleIdentifier": "com.apple.xcode.dsym.com.heyujk.junchat",
            "CFBundlePackageType": "dSYM"
        ], to: archiveURL.appending(path: "dSYMs/Junchat.app.dSYM/Contents/Info.plist"))
        try Data("signed application".utf8).write(to: appURL.appending(path: "Junchat"))
        try Data("debug symbols".utf8).write(to: dwarfURL)
    }

    var environment: [String: String] {
        [
            "CI_ARCHIVE_PATH": archiveURL.path,
            "CI_APP_STORE_SIGNED_APP_PATH": archiveURL.appending(path: "Products/Applications/Junchat.app").path
        ]
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }

    private func writePropertyList(_ propertyList: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: url)
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
