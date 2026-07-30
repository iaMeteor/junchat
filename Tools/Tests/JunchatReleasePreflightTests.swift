import Foundation
@testable import Tools
import XCTest

final class JunchatReleasePreflightTests: XCTestCase {
    func testProductionPreflightCommandDoesNotExposeVerifierExecutableOverrides() {
        let help = ValidateJunchatReleasePreflight.helpMessage()

        XCTAssertFalse(help.contains("--codesign-executable-path"))
        XCTAssertFalse(help.contains("--otool-executable-path"))
        XCTAssertFalse(help.contains("--dwarfdump-executable-path"))
    }

    func testProductionArtifactRunnerUsesOnlyImmutableSystemVerifierPaths() {
        let commandRunner = ReleaseArtifactCommandRunner.production()

        XCTAssertEqual(commandRunner.codesignExecutablePath, "/usr/bin/codesign")
        XCTAssertEqual(commandRunner.otoolExecutablePath, "/usr/bin/otool")
        XCTAssertEqual(commandRunner.dwarfdumpExecutablePath, "/usr/bin/dwarfdump")
    }

    func testExportsValidatedArtifactBindingForShellIntegration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JUNCHAT_RELEASE_TEST_EXPORT_BINDING"] == "1" else { return }

        let repositoryPath = try XCTUnwrap(environment["JUNCHAT_RELEASE_TEST_REPOSITORY_PATH"])
        let bindingPath = try XCTUnwrap(environment["JUNCHAT_RELEASE_TEST_BINDING_PATH"])
        let digestPath = try XCTUnwrap(environment["JUNCHAT_RELEASE_TEST_BINDING_DIGEST_PATH"])
        let originalDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(repositoryPath))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(originalDirectory)) }

        var command = ValidateJunchatReleasePreflight()
        command.artifactBindingPath = bindingPath
        command.artifactBindingDigestPath = digestPath
        try await command.run(commandRunner: validatingCommandRunner())
    }

    func testCryptographicArtifactValidationRejectsUnsignedTextStaleMetadataAndUnrelatedDSYMBeforeSideEffects() async throws {
        let unsignedFixture = try ReleaseArchiveFixture()
        defer { unsignedFixture.remove() }
        try Data("unsigned text".utf8).write(to: unsignedFixture.appExecutableURL)
        await assertReleaseArtifactFailure(environment: unsignedFixture.environment)

        let staleFixture = try ReleaseArchiveFixture()
        defer { staleFixture.remove() }
        try staleFixture.setReleaseVersion(name: "1.8.1", build: 36)
        await assertReleaseArtifactFailure(environment: staleFixture.environment)

        let unrelatedDSYMFixture = try ReleaseArchiveFixture()
        defer { unrelatedDSYMFixture.remove() }
        try Data(contentsOf: URL(filePath: "/usr/bin/false")).write(to: unrelatedDSYMFixture.dwarfURL)
        await assertReleaseArtifactFailure(environment: unrelatedDSYMFixture.environment,
                                           commandRunner: validatingCommandRunner(dSYMMatchesApp: false))

        let wrongBundleFixture = try ReleaseArchiveFixture()
        defer { wrongBundleFixture.remove() }
        try wrongBundleFixture.setArchiveBundleIdentifier("com.example.unrelated")
        await assertReleaseArtifactFailure(environment: wrongBundleFixture.environment)
    }

    func testReleaseArtifactValidationAcceptsTheCanonicalArchiveInputs() async throws {
        let fixture = try ReleaseArchiveFixture()
        defer { fixture.remove() }
        var operationCount = 0

        try await JunchatReleasePreflight.performAfterValidatingReleaseArtifacts(environment: fixture.environment,
                                                                                 commandRunner: validatingCommandRunner()) { _ in
            operationCount += 1
        }

        XCTAssertEqual(operationCount, 1)
    }

    func testReleaseArtifactValidationRejectsAdHocMissingTeamAndNonExecutableMachO() async throws {
        let invalidRunners = [
            validatingCommandRunner(signature: "Signature=adhoc"),
            validatingCommandRunner(teamIdentifier: "not set"),
            validatingCommandRunner(fileType: "BUNDLE")
        ]

        for commandRunner in invalidRunners {
            let fixture = try ReleaseArchiveFixture()
            defer { fixture.remove() }
            await assertReleaseArtifactFailure(environment: fixture.environment,
                                               commandRunner: commandRunner)
        }
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

    func testReleaseArtifactBindingRevalidatesExactIdentityAndFullTreeBytes() async throws {
        let fixture = try ReleaseArchiveFixture()
        defer { fixture.remove() }
        let bindingDirectory = fixture.rootURL.appending(path: "binding")
        try FileManager.default.createDirectory(at: bindingDirectory,
                                                withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let bindingURL = bindingDirectory.appending(path: "release-artifacts.json")

        let validation = try await JunchatReleaseArtifacts.validate(environment: fixture.environment,
                                                                    commandRunner: validatingCommandRunner(),
                                                                    artifactBindingURL: bindingURL)
        let digest = try XCTUnwrap(validation.bindingDigest)
        let attributes = try FileManager.default.attributesOfItem(atPath: bindingURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        _ = try JunchatReleaseArtifacts.revalidateBinding(atPath: bindingURL.path,
                                                          expectedDigest: digest,
                                                          environment: fixture.environment,
                                                          validateProjectMetadata: true)
        XCTAssertThrowsError(try JunchatReleaseArtifacts.revalidateBinding(atPath: bindingURL.path,
                                                                           expectedDigest: String(repeating: "0", count: 64),
                                                                           environment: fixture.environment))

        let originalDWARF = try Data(contentsOf: fixture.dwarfURL)
        try FileManager.default.removeItem(at: fixture.dwarfURL)
        try originalDWARF.write(to: fixture.dwarfURL)
        XCTAssertThrowsError(try JunchatReleaseArtifacts.revalidateBinding(atPath: bindingURL.path,
                                                                           expectedDigest: digest,
                                                                           environment: fixture.environment))
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
                                              commandRunner: ReleaseArtifactCommandRunner = .production(),
                                              file: StaticString = #filePath,
                                              line: UInt = #line) async {
        var operationCount = 0

        do {
            try await JunchatReleasePreflight.performAfterValidatingReleaseArtifacts(environment: environment,
                                                                                     commandRunner: commandRunner) { _ in
                operationCount += 1
            }
            XCTFail("Expected release artifact validation to fail", file: file, line: line)
        } catch { }

        XCTAssertEqual(operationCount, 0, file: file, line: line)
    }

    private func validatingCommandRunner(dSYMMatchesApp: Bool = true,
                                         teamIdentifier: String = "W834S4TA7S",
                                         signature: String = "Signature size=9000",
                                         fileType: String = "EXECUTE") -> ReleaseArtifactCommandRunner {
        ReleaseArtifactCommandRunner(codesignExecutablePath: "/usr/bin/codesign",
                                     otoolExecutablePath: "/usr/bin/otool",
                                     dwarfdumpExecutablePath: "/usr/bin/dwarfdump") { executablePath, arguments in
            switch (executablePath, arguments.first) {
            case ("/usr/bin/codesign", "--verify"):
                XCTAssertEqual(Array(arguments.dropLast()), ["--verify", "--deep", "--strict"])
                XCTAssertEqual(arguments.last.map { URL(filePath: $0).pathExtension }, "app")
                return .init(standardOutput: "", standardError: "")
            case ("/usr/bin/codesign", "--display"):
                return .init(standardOutput: "",
                             standardError: "Identifier=com.heyujk.junchat\nTeamIdentifier=\(teamIdentifier)\n\(signature)\n")
            case ("/usr/bin/otool", "-hv"):
                return .init(standardOutput: """
                Mach header
                      magic cputype cpusubtype caps filetype ncmds sizeofcmds flags
                 MH_MAGIC_64   ARM64        ALL  0x00  \(fileType)    20       2048 0x0
                """, standardError: "")
            case ("/usr/bin/dwarfdump", "--uuid"):
                let isDSYM = arguments.last?.hasSuffix(".dSYM") == true
                let uuid = isDSYM && !dSYMMatchesApp
                    ? "28B4D55A-9134-4EA7-865E-FAC746A59056"
                    : "1AB9D6FA-27FF-3A79-9369-BE0E635A4AA2"
                return .init(standardOutput: "UUID: \(uuid) (arm64) \(arguments.last ?? "")\n",
                             standardError: "")
            default:
                throw StubError.unexpectedArtifactCommand
            }
        }
    }

    private enum StubError: Error {
        case xcodeGenFailed
        case unexpectedArtifactCommand
    }
}

private final class ReleaseArchiveFixture {
    let rootURL: URL
    let archiveURL: URL
    let appExecutableURL: URL
    let dwarfURL: URL

    private let fileManager = FileManager.default

    init() throws {
        let projectYAML = try String(contentsOf: URL.projectDirectory.appending(path: "project.yml"),
                                     encoding: .utf8)
        let releaseVersion = try JunchatReleaseVersion.parse(projectYAML)
        rootURL = fileManager.temporaryDirectory
            .appending(path: "junchat-release-preflight-tests")
            .appending(path: UUID().uuidString)
        archiveURL = rootURL.appending(path: "Junchat.xcarchive")

        let appURL = archiveURL.appending(path: "Products/Applications/Junchat.app")
        appExecutableURL = appURL.appending(path: "Junchat")
        dwarfURL = archiveURL.appending(path: "dSYMs/Junchat.app.dSYM/Contents/Resources/DWARF/Junchat")
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dwarfURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try writePropertyList([
            "ApplicationProperties": [
                "ApplicationPath": "Applications/Junchat.app",
                "CFBundleIdentifier": "com.heyujk.junchat",
                "CFBundleShortVersionString": releaseVersion.name,
                "CFBundleVersion": String(releaseVersion.build)
            ],
            "ArchiveVersion": 2,
            "Name": "Junchat",
            "SchemeName": "Junchat"
        ], to: archiveURL.appending(path: "Info.plist"))
        try writePropertyList([
            "CFBundleExecutable": "Junchat",
            "CFBundleIdentifier": "com.heyujk.junchat",
            "CFBundleShortVersionString": releaseVersion.name,
            "CFBundleVersion": String(releaseVersion.build),
            "CFBundlePackageType": "APPL"
        ], to: appURL.appending(path: "Info.plist"))
        try writePropertyList([
            "CFBundleIdentifier": "com.apple.xcode.dsym.com.heyujk.junchat",
            "CFBundlePackageType": "dSYM"
        ], to: archiveURL.appending(path: "dSYMs/Junchat.app.dSYM/Contents/Info.plist"))
        let machO = try Data(contentsOf: URL(filePath: "/usr/bin/true"))
        try machO.write(to: appExecutableURL)
        try machO.write(to: dwarfURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExecutableURL.path)
    }

    var environment: [String: String] {
        [
            "CI_ARCHIVE_PATH": archiveURL.path,
            "CI_APP_STORE_SIGNED_APP_PATH": archiveURL.appending(path: "Products/Applications/Junchat.app").path
        ]
    }

    func setReleaseVersion(name: String, build: Int) throws {
        try writeArchivePropertyList(version: name, build: build, bundleIdentifier: "com.heyujk.junchat")
        try writeAppPropertyList(version: name, build: build)
    }

    func setArchiveBundleIdentifier(_ bundleIdentifier: String) throws {
        let projectYAML = try String(contentsOf: URL.projectDirectory.appending(path: "project.yml"),
                                     encoding: .utf8)
        let releaseVersion = try JunchatReleaseVersion.parse(projectYAML)
        try writeArchivePropertyList(version: releaseVersion.name,
                                     build: releaseVersion.build,
                                     bundleIdentifier: bundleIdentifier)
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

    private func writeArchivePropertyList(version: String, build: Int, bundleIdentifier: String) throws {
        try writePropertyList([
            "ApplicationProperties": [
                "ApplicationPath": "Applications/Junchat.app",
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": String(build)
            ],
            "ArchiveVersion": 2,
            "Name": "Junchat",
            "SchemeName": "Junchat"
        ], to: archiveURL.appending(path: "Info.plist"))
    }

    private func writeAppPropertyList(version: String, build: Int) throws {
        try writePropertyList([
            "CFBundleExecutable": "Junchat",
            "CFBundleIdentifier": "com.heyujk.junchat",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build),
            "CFBundlePackageType": "APPL"
        ], to: archiveURL.appending(path: "Products/Applications/Junchat.app/Info.plist"))
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
