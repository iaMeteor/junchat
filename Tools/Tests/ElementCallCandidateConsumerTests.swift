/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import CryptoKit
import Darwin
import Foundation
@testable import Tools
import XCTest

final class ElementCallCandidateConsumerTests: XCTestCase {
    private let sourceCommit = "e17ab641d86c5fa83f9e288e741c5c1a7f041dc7"
    private let manifestSHA256 = "3fec23008d0f4d0dc0acfd14ed96085c46c59788d663e935f6c75b9b52fe864c"

    func testCandidateArgumentsAreAllOrNone() throws {
        XCTAssertNil(try ElementCallCandidateRequest.resolve(manifestPath: nil,
                                                             manifestSHA256: nil,
                                                             sourceCommit: nil))

        let partialRequests: [[String?]] = [
            ["/private/tmp/manifest.json", nil, nil],
            [nil, manifestSHA256, nil],
            [nil, nil, sourceCommit],
            ["/private/tmp/manifest.json", manifestSHA256, nil],
            ["/private/tmp/manifest.json", nil, sourceCommit],
            [nil, manifestSHA256, sourceCommit]
        ]
        for partialRequest in partialRequests {
            XCTAssertThrowsError(try ElementCallCandidateRequest.resolve(manifestPath: partialRequest[0],
                                                                         manifestSHA256: partialRequest[1],
                                                                         sourceCommit: partialRequest[2])) { error in
                XCTAssertTrue(error.localizedDescription.contains("all required"))
            }
        }

        let request = try XCTUnwrap(ElementCallCandidateRequest.resolve(manifestPath: "/private/tmp/manifest.json",
                                                                        manifestSHA256: manifestSHA256,
                                                                        sourceCommit: sourceCommit))
        XCTAssertEqual(request.manifestURL.path, "/private/tmp/manifest.json")
        XCTAssertEqual(request.manifestSHA256, manifestSHA256)
        XCTAssertEqual(request.sourceCommit, sourceCommit)
    }

    func testDuplicateJSONKeysAreRejectedBeforeDecoding() throws {
        XCTAssertNoThrow(try ElementCallCandidateJSON.validateUniqueKeys(Data(#"{"outer":{"value":1}}"#.utf8)))

        for json in [
            #"{"value":1,"value":2}"#,
            #"{"outer":{"value":1,"value":2}}"#,
            #"{"a":1,"\u0061":2}"#
        ] {
            XCTAssertThrowsError(try ElementCallCandidateJSON.validateUniqueKeys(Data(json.utf8))) { error in
                XCTAssertNotNil(error.localizedDescription.range(of: "duplicate", options: .caseInsensitive))
            }
        }
    }

    func testDuplicateKeyScannerRejectsExcessiveNesting() {
        let depth = 130
        let json = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)

        XCTAssertThrowsError(try ElementCallCandidateJSON.validateUniqueKeys(Data(json.utf8))) { error in
            XCTAssertNotNil(error.localizedDescription.range(of: "depth", options: .caseInsensitive))
        }
    }

    func testSafeIntegerMatchesJavaScriptValueSemantics() throws {
        XCTAssertEqual(try ElementCallCandidateJSON.safeInteger(NSNumber(value: 35.0), label: "value"), 35)
        XCTAssertEqual(try ElementCallCandidateJSON.safeInteger(NSNumber(value: -9_007_199_254_740_991.0), label: "value"),
                       -9_007_199_254_740_991)

        for value: Any in [
            NSNumber(value: 35.5),
            NSNumber(value: -9_007_199_254_740_992.0),
            NSNumber(value: -Double.infinity),
            NSNumber(value: true),
            "35"
        ] {
            XCTAssertThrowsError(try ElementCallCandidateJSON.safeInteger(value, label: "value"))
        }
    }

    func testCandidateVersionRejectsLeadingZeroComponents() {
        let commit = "e17ab641d86c5fa83f9e288e741c5c1a7f041dc7"

        XCTAssertNoThrow(try ElementCallCandidateManifest.validateVersion("0.19.3-junchat.e17ab641d86c", sourceCommit: commit))
        for version in [
            "00.19.3-junchat.e17ab641d86c",
            "0.019.3-junchat.e17ab641d86c",
            "0.19.03-junchat.e17ab641d86c"
        ] {
            XCTAssertThrowsError(try ElementCallCandidateManifest.validateVersion(version, sourceCommit: commit))
        }
    }

    func testTreeFileDescriptionsRejectExtraFields() throws {
        let fileSHA256 = String(repeating: "a", count: 64)
        let file: [String: Any] = ["path": "index.html", "sha256": fileSHA256, "size": 1, "extra": true]
        let tree: [String: Any] = try [
            "files": [file],
            "treeSha256": treeSHA256(path: "index.html", sha256: fileSHA256, size: 1)
        ]
        let object = try ElementCallCandidateManifest.JSONObject(tree, label: "test tree")

        XCTAssertThrowsError(try ElementCallCandidateManifest.treeFields(object, requiredPath: nil, label: "test tree"))
    }

    func testAndroidSDKRejectsInvalidPlatformRevision() throws {
        let digest = String(repeating: "a", count: 64)
        let sdk: [String: Any] = [
            "root": "/private/tmp/android-sdk",
            "platform": [
                "apiLevel": 35,
                "packageId": "platforms;android-35",
                "revision": "not a revision",
                "sourceProperties": ["path": "platforms/android-35/source.properties", "sha256": digest, "size": 1]
            ],
            "buildTools": [
                "packageId": "build-tools;35.0.0",
                "revision": "35.0.0",
                "sourceProperties": ["path": "build-tools/35.0.0/source.properties", "sha256": digest, "size": 1]
            ]
        ]
        let object = try ElementCallCandidateManifest.JSONObject(sdk, label: "test Android SDK")

        XCTAssertThrowsError(try ElementCallCandidateManifest.validateAndroidSDK(object))
    }

    func testToolVersionsRequireAuthoritativeObservedValues() throws {
        let cases = [
            ToolMutation(tool: "node", field: "requirement", value: "24"),
            ToolMutation(tool: "node", field: "observed", value: "v99.0.0"),
            ToolMutation(tool: "pnpm", field: "observed", value: "99.0.0"),
            ToolMutation(tool: "java", field: "observed", value: "openjdk version 21"),
            ToolMutation(tool: "gradle", field: "requirement", value: "wrapper"),
            ToolMutation(tool: "gradle", field: "observed", value: "Gradle 9.9"),
            ToolMutation(tool: "swift", field: "requirement", value: "tools"),
            ToolMutation(tool: "swift", field: "observed", value: "Swift version 5.10")
        ]

        for mutation in cases {
            let object = try makeTools(mutating: mutation.tool, field: mutation.field, value: mutation.value)
            XCTAssertThrowsError(try ElementCallCandidateManifest.validateTools(object),
                                 "Expected \(mutation.tool).\(mutation.field) rejection")
        }

        let untrimmed = try makeTools(mutating: "gradle", field: "observed", value: " Gradle 8.14.4 ")
        XCTAssertThrowsError(try ElementCallCandidateManifest.validateTools(untrimmed))
    }

    func testCandidatePathsRejectTraversalAndNoncanonicalForms() {
        XCTAssertNoThrow(try ElementCallCandidatePath.validateRelative("Sources/EmbeddedElementCall/EmbeddedElementCall.swift"))

        for path in ["", ".", "../escape", "Sources/../escape", "/absolute", "Sources//file", "Sources/./file", "Sources\\file"] {
            XCTAssertThrowsError(try ElementCallCandidatePath.validateRelative(path), "Expected rejection for \(path)")
        }
    }

    func testManifestVerificationRejectsSymlinkedPathAncestor() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let realDirectory = temporaryDirectory.appending(path: "real")
        let candidateDirectory = realDirectory.appending(path: sourceCommit)
        let alias = temporaryDirectory.appending(path: "alias")
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: candidateDirectory.appending(path: "manifest.json"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realDirectory)
        let request = try XCTUnwrap(ElementCallCandidateRequest.resolve(manifestPath: alias.appending(path: "\(sourceCommit)/manifest.json").path,
                                                                        manifestSHA256: manifestSHA256,
                                                                        sourceCommit: sourceCommit))

        XCTAssertThrowsError(try ElementCallCandidateManifest.verify(request)) { error in
            XCTAssertNotNil(error.localizedDescription.range(of: "symlink", options: .caseInsensitive))
        }
    }

    func testStagingCopiesOnlyVerifiedBytesWithPrivatePermissions() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let package = ElementCallCandidatePackageSnapshot(sourceCommit: sourceCommit,
                                                          version: "0.19.3-junchat.e17ab641d86c",
                                                          files: [
                                                              .init(path: "Package.swift", data: Data("// package".utf8)),
                                                              .init(path: "Sources/EmbeddedElementCall/EmbeddedElementCall.swift", data: Data("public enum EmbeddedElementCall {}".utf8)),
                                                              .init(path: "Sources/dist/index.html", data: Data("<html></html>".utf8))
                                                          ])

        let staged = try ElementCallCandidateStaging.stage(package, under: temporaryDirectory)

        XCTAssertEqual(try permissions(of: staged.rootURL), 0o700)
        XCTAssertEqual(try permissions(of: staged.packageURL), 0o700)
        XCTAssertEqual(try permissions(of: staged.packageURL.appending(path: "Package.swift")), 0o600)
        XCTAssertEqual(try Data(contentsOf: staged.packageURL.appending(path: "Sources/dist/index.html")), Data("<html></html>".utf8))
        XCTAssertFalse(staged.packageURL.path.contains("junchat-platform-ec-candidate"))
    }

    func testStagingRejectsSymlinkedTemporaryAncestor() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let realDirectory = temporaryDirectory.appending(path: "real")
        let alias = temporaryDirectory.appending(path: "alias")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realDirectory)
        let package = ElementCallCandidatePackageSnapshot(sourceCommit: sourceCommit,
                                                          version: "0.19.3-junchat.e17ab641d86c",
                                                          files: [.init(path: "Package.swift", data: Data())])

        XCTAssertThrowsError(try ElementCallCandidateStaging.stage(package, under: alias)) { error in
            XCTAssertNotNil(error.localizedDescription.range(of: "symlink", options: .caseInsensitive))
        }
    }

    func testTransientSpecRequiresPublic0191AndDisablesPostGenerationMutation() throws {
        let projectYAMLURL = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "project.yml")
        let projectYAML = try String(contentsOf: projectYAMLURL, encoding: .utf8)
        let stagedPackageURL = URL(filePath: "/private/tmp/junchat-element-call-ios-test/EmbeddedElementCall")
        let repositoryURL = URL(filePath: FileManager.default.currentDirectoryPath)

        let spec = try ElementCallCandidateProjectSpec.make(defaultProjectYAML: projectYAML,
                                                            stagedPackageURL: stagedPackageURL,
                                                            repositoryURL: repositoryURL)
        let inspection = try ElementCallCandidateProjectSpec.inspect(spec)

        XCTAssertEqual(inspection.elementCallPath, stagedPackageURL.path)
        XCTAssertNil(inspection.elementCallURL)
        XCTAssertNil(inspection.elementCallExactVersion)
        XCTAssertEqual(inspection.packagePaths["Compound"], repositoryURL.appending(path: "compound-ios").path)
        XCTAssertFalse(inspection.hasPostGenerationCommand)
        XCTAssertTrue(inspection.replacesElementXPreBuildScripts)
        XCTAssertTrue(inspection.replacesElementXPostBuildScripts)
        XCTAssertEqual(inspection.targetBaseSettings, [
            "ElementX": [
                "DEVELOPMENT_ASSET_PATHS": repositoryURL.appending(path: "DevelopmentAssets/Media").path,
                "INFOPLIST_FILE": repositoryURL.appending(path: "ElementX/SupportingFiles/Info.plist").path,
                "SWIFT_OBJC_BRIDGING_HEADER": repositoryURL.appending(path: "ElementX/SupportingFiles/ElementX-Bridging-Header.h").path
            ],
            "NSE": [
                "INFOPLIST_FILE": repositoryURL.appending(path: "NSE/SupportingFiles/Info.plist").path
            ],
            "ShareExtension": [
                "INFOPLIST_FILE": repositoryURL.appending(path: "ShareExtension/SupportingFiles/Info.plist").path
            ]
        ])
        XCTAssertEqual(try String(contentsOf: projectYAMLURL, encoding: .utf8), projectYAML)

        let driftedYAML = projectYAML.replacingOccurrences(of: "exactVersion: 0.19.1", with: "exactVersion: 0.19.2")
        XCTAssertThrowsError(try ElementCallCandidateProjectSpec.make(defaultProjectYAML: driftedYAML,
                                                                      stagedPackageURL: stagedPackageURL,
                                                                      repositoryURL: repositoryURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("0.19.1"))
        }
    }

    func testTrackedProjectStateReadsCapturedProjectAndResolutionBytes() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let projectYAMLURL = temporaryDirectory.appending(path: "project.yml")
        let packageResolutionURL = temporaryDirectory.appending(path: "Package.resolved")
        let capturedProjectData = Data("captured project".utf8)
        let capturedResolutionData = Data("captured resolution".utf8)
        try Data("changed".utf8).write(to: projectYAMLURL)
        try Data("changed".utf8).write(to: packageResolutionURL)
        let state = TrackedProjectState(repositoryURL: temporaryDirectory,
                                        files: [
                                            .init(relativePath: "project.yml", url: projectYAMLURL, data: capturedProjectData),
                                            .init(relativePath: "ElementX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                                                  url: packageResolutionURL,
                                                  data: capturedResolutionData)
                                        ],
                                        head: Data(),
                                        status: Data())

        XCTAssertEqual(try state.projectYAML(), "captured project")
        XCTAssertEqual(try state.packageResolutionData(), capturedResolutionData)
    }

    func testPackageIdentityRequiresOnlyTheExpectedLibraryAndTarget() throws {
        let validDump = Data(#"""
        {
          "name": "EmbeddedElementCall",
          "products": [{
            "name": "EmbeddedElementCall",
            "targets": ["EmbeddedElementCall"],
            "type": {"library": ["automatic"]}
          }],
          "targets": [{
            "dependencies": [],
            "name": "EmbeddedElementCall",
            "resources": [{"path": "../dist", "rule": {"copy": {}}}],
            "type": "regular"
          }]
        }
        """#.utf8)
        XCTAssertNoThrow(try ElementCallCandidatePackageIdentity.validate(dumpPackageJSON: validDump))

        let validDumpString = try XCTUnwrap(String(data: validDump, encoding: .utf8))
        let wrongName = Data(validDumpString.replacingOccurrences(of: "EmbeddedElementCall", with: "ForeignPackage").utf8)
        XCTAssertThrowsError(try ElementCallCandidatePackageIdentity.validate(dumpPackageJSON: wrongName))
    }

    func testTransientPackageResolutionChangesOnlyElementCallPin() throws {
        let publicURL = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "ElementX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let publicData = try Data(contentsOf: publicURL)
        var candidateRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: publicData) as? [String: Any])
        let publicPins = try XCTUnwrap(candidateRoot["pins"] as? [[String: Any]])
        let candidatePins = publicPins.filter { $0["identity"] as? String != "element-call-swift" }
        XCTAssertEqual(publicPins.count, candidatePins.count + 1)
        let publicOriginHash = try XCTUnwrap(candidateRoot["originHash"] as? String)
        let candidateOriginHash = publicOriginHash == String(repeating: "b", count: 64)
            ? String(repeating: "c", count: 64)
            : String(repeating: "b", count: 64)
        candidateRoot["originHash"] = candidateOriginHash
        candidateRoot["pins"] = candidatePins
        let candidateData = try JSONSerialization.data(withJSONObject: candidateRoot, options: [.sortedKeys])

        XCTAssertNoThrow(try ElementCallCandidatePackageResolution.validate(publicData: publicData,
                                                                            candidateData: candidateData))

        var staleOrigin = candidateRoot
        staleOrigin["originHash"] = publicOriginHash
        XCTAssertThrowsError(try ElementCallCandidatePackageResolution.validate(publicData: publicData,
                                                                                candidateData: JSONSerialization.data(withJSONObject: staleOrigin, options: [.sortedKeys])))

        var retainedRemotePin = candidateRoot
        retainedRemotePin["pins"] = publicPins
        XCTAssertThrowsError(try ElementCallCandidatePackageResolution.validate(publicData: publicData,
                                                                                candidateData: JSONSerialization.data(withJSONObject: retainedRemotePin, options: [.sortedKeys])))

        var changedDependency = candidateRoot
        var changedPins = candidatePins
        changedPins[0]["location"] = "https://invalid.example/dependency"
        changedDependency["pins"] = changedPins
        XCTAssertThrowsError(try ElementCallCandidatePackageResolution.validate(publicData: publicData,
                                                                                candidateData: JSONSerialization.data(withJSONObject: changedDependency, options: [.sortedKeys])))
    }

    func testBuildInvocationIsFixedToUnsignedDebugSimulator() {
        let projectURL = URL(filePath: "/private/tmp/candidate/ElementX.xcodeproj")
        let derivedDataURL = URL(filePath: "/private/tmp/candidate/DerivedData")
        let sourcePackagesURL = URL(filePath: "/private/tmp/candidate/SourcePackages")

        XCTAssertEqual(ElementCallCandidateBuildInvocation.resolveArguments(projectURL: projectURL,
                                                                            derivedDataURL: derivedDataURL,
                                                                            sourcePackagesURL: sourcePackagesURL), [
                "-IDEPackageSupportDisableManifestSandbox=1",
                "-project", projectURL.path,
                "-scheme", "ElementX",
                "-derivedDataPath", derivedDataURL.path,
                "-resultBundlePath", "/private/tmp/candidate/Resolve.xcresult",
                "-clonedSourcePackagesDirPath", sourcePackagesURL.path,
                "-skipPackageUpdates",
                "-resolvePackageDependencies"
            ])

        XCTAssertEqual(ElementCallCandidateBuildInvocation.arguments(projectURL: projectURL,
                                                                     derivedDataURL: derivedDataURL,
                                                                     sourcePackagesURL: sourcePackagesURL,
                                                                     repositoryURL: URL(filePath: "/private/repository")), [
                "-IDEPackageSupportDisableManifestSandbox=1",
                "-project", projectURL.path,
                "-scheme", "ElementX",
                "-configuration", "Debug",
                "-sdk", "iphonesimulator",
                "-destination", "generic/platform=iOS Simulator",
                "-derivedDataPath", derivedDataURL.path,
                "-resultBundlePath", "/private/tmp/candidate/Build.xcresult",
                "-clonedSourcePackagesDirPath", sourcePackagesURL.path,
                "-disableAutomaticPackageResolution",
                "-onlyUsePackageVersionsFromResolvedFile",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
                "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox",
                "SRCROOT=/private/repository",
                "build"
            ])

        XCTAssertEqual(ElementCallCandidateBuildInvocation.environment(repositoryURL: URL(filePath: "/private/repository"),
                                                                       gitDirectoryURL: URL(filePath: "/private/git/worktrees/candidate"),
                                                                       gitCommonDirectoryURL: URL(filePath: "/private/git"),
                                                                       temporaryRootURL: URL(filePath: "/private/tmp/candidate"),
                                                                       base: ["EXISTING": "value"]), [
                "EXISTING": "value",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_NO_LAZY_FETCH": "1",
                "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0",
                "JUNCHAT_XCODEBUILD_READ_ONLY_ROOT": "/private/repository",
                "JUNCHAT_XCODEBUILD_READ_ONLY_GIT_DIR": "/private/git/worktrees/candidate",
                "JUNCHAT_XCODEBUILD_READ_ONLY_GIT_COMMON_DIR": "/private/git",
                "XBS_DISABLE_SANDBOXED_BUILDS": "YES",
                "TMPDIR": "/private/tmp/candidate/"
            ])
    }

    func testXcodeBuildWrapperOwnsResourceAndIsolationGates() throws {
        let wrapperURL = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "Tools/Scripts/run_xcodebuild.sh")
        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)

        XCTAssertTrue(wrapper.contains("minimum_kib=83886080"))
        XCTAssertTrue(wrapper.contains("/System/Volumes/Data"))
        XCTAssertFalse(wrapper.contains("exec 9>>\"$lock_file\""))
        XCTAssertTrue(wrapper.contains("O_NOFOLLOW"))
        XCTAssertTrue(wrapper.contains("S_ISREG"))
        XCTAssertTrue(wrapper.contains("/usr/bin/lockf -s -t 0 9"))
        XCTAssertTrue(wrapper.contains("/usr/bin/pgrep -x xcodebuild"))
        XCTAssertTrue(wrapper.contains("/usr/bin/pgrep -x XCBBuildService"))
        XCTAssertTrue(wrapper.contains("(deny network*)"))
        XCTAssertTrue(wrapper.contains("(deny file-write*"))
        XCTAssertTrue(wrapper.contains("JUNCHAT_XCODEBUILD_READ_ONLY_GIT_DIR"))
        XCTAssertTrue(wrapper.contains("JUNCHAT_XCODEBUILD_READ_ONLY_GIT_COMMON_DIR"))
        XCTAssertTrue(wrapper.contains("/usr/bin/perl -MPOSIX"))
        XCTAssertTrue(wrapper.contains("/bin/kill \"-$signal_name\" \"-$child_pid\""))
        XCTAssertTrue(wrapper.contains("process_group_is_active"))
        XCTAssertTrue(wrapper.contains("pending_signal"))
        XCTAssertTrue(wrapper.contains("ready_file"))
        XCTAssertTrue(wrapper.contains("go_file"))
        XCTAssertTrue(wrapper.contains("wait \"$child_pid\""))
        XCTAssertTrue(wrapper.contains("/usr/bin/sandbox-exec -p \"$profile\" /usr/bin/xcodebuild \"$@\" &"))
    }

    func testXcodeBuildWrapperKeepsLockUntilProcessGroupExits() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory)

        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "wrapper terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitForFile(fixture.pidURL, timeout: 5))
        XCTAssertTrue(waitForFile(fixture.lockURL, timeout: 5))
        let pids = try processIDs(in: fixture.pidURL)
        XCTAssertEqual(pids.count, 2)
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))

        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
        usleep(200_000)
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))
        wait(for: [terminated], timeout: 10)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 143)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        XCTAssertTrue(try canAcquireLock(fixture.lockURL))
        for pid in pids {
            XCTAssertFalse(processIsActive(pid), "Process \(pid) outlived the wrapper lock.")
        }
    }

    func testXcodeBuildLockSurvivesWrapperSIGKILL() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory, useRealSandbox: true)
        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "wrapper killed")
        process.terminationHandler = { _ in terminated.fulfill() }
        var pids = [pid_t]()
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if let groupLeader = pids.first {
                kill(-groupLeader, SIGKILL)
            }
        }

        XCTAssertTrue(waitForFile(fixture.pidURL, timeout: 5))
        XCTAssertTrue(waitForFile(fixture.lockURL, timeout: 5))
        pids = try processIDs(in: fixture.pidURL)
        XCTAssertEqual(pids.count, 2)
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))

        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        wait(for: [terminated], timeout: 5)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertTrue(pids.contains(where: processIsActive))
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))

        let groupLeader = try XCTUnwrap(pids.first)
        XCTAssertEqual(kill(-groupLeader, SIGTERM), 0)
        XCTAssertTrue(waitForProcessesToExit(pids, timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertTrue(try canAcquireLock(fixture.lockURL))
    }

    func testXcodeBuildWrapperEscalatesWhenLeaderIgnoresTermination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory, ignoresTermination: true)
        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "nonresponsive wrapper terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        var pids = [pid_t]()
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if let groupLeader = pids.first {
                kill(-groupLeader, SIGKILL)
            }
        }

        XCTAssertTrue(waitForFile(fixture.pidURL, timeout: 5))
        pids = try processIDs(in: fixture.pidURL)
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
        wait(for: [terminated], timeout: 5)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 143)
        XCTAssertTrue(waitForProcessesToExit(pids, timeout: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertTrue(try canAcquireLock(fixture.lockURL))
    }

    func testXcodeBuildWrapperRejectsSymlinkedLockWithoutChangingTarget() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory, leaderExitsImmediately: true)
        let targetURL = temporaryDirectory.appending(path: "lock-target")
        let targetData = Data("unchanged\n".utf8)
        try targetData.write(to: targetURL)
        XCTAssertEqual(chmod(targetURL.path, 0o644), 0)
        try FileManager.default.createSymbolicLink(at: fixture.lockURL, withDestinationURL: targetURL)
        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "symlinked-lock wrapper terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        wait(for: [terminated], timeout: 5)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertEqual(try permissions(of: targetURL), 0o644)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pidURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    func testXcodeBuildWrapperDefersSignalAcrossLaunchRace() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory, delayBeforeLaunch: true)
        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "launch-race wrapper terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitForFile(fixture.launchBarrierURL, timeout: 5))
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
        wait(for: [terminated], timeout: 5)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 143)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pidURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertTrue(try canAcquireLock(fixture.lockURL))
    }

    func testXcodeBuildWrapperDrainsDescendantsAfterNormalLeaderExit() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixture = try makeXcodeWrapperFixture(in: temporaryDirectory, leaderExitsImmediately: true)
        let process = Process()
        process.executableURL = fixture.wrapperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        let terminated = expectation(description: "orphan-draining wrapper terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitForFile(fixture.pidURL, timeout: 5))
        let pids = try processIDs(in: fixture.pidURL)
        XCTAssertEqual(pids.count, 2)
        XCTAssertFalse(try canAcquireLock(fixture.lockURL))
        wait(for: [terminated], timeout: 5)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        XCTAssertTrue(waitForProcessesToExit(pids, timeout: 2))
        XCTAssertTrue(try canAcquireLock(fixture.lockURL))
    }

    func testRetainedSchemaV4ManifestWhenExplicitlyProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["JUNCHAT_ELEMENT_CALL_CANDIDATE_TEST_MANIFEST"],
              let manifestSHA256 = environment["JUNCHAT_ELEMENT_CALL_CANDIDATE_TEST_MANIFEST_SHA256"],
              let sourceCommit = environment["JUNCHAT_ELEMENT_CALL_CANDIDATE_TEST_SOURCE_COMMIT"] else {
            throw XCTSkip("Retained Element Call candidate inputs were not provided.")
        }

        let request = try XCTUnwrap(ElementCallCandidateRequest.resolve(manifestPath: manifestPath,
                                                                        manifestSHA256: manifestSHA256,
                                                                        sourceCommit: sourceCommit))
        let package = try ElementCallCandidateManifest.verify(request)

        XCTAssertEqual(package.sourceCommit, sourceCommit)
        XCTAssertEqual(package.version, "0.19.3-junchat.\(sourceCommit.prefix(12))")
        XCTAssertEqual(package.files.count, 167)
        XCTAssertTrue(package.files.contains { $0.path == "Package.swift" })
        XCTAssertTrue(package.files.contains { $0.path == "Sources/EmbeddedElementCall/EmbeddedElementCall.swift" })
    }

    private struct XcodeWrapperFixture {
        let wrapperURL: URL
        let lockURL: URL
        let pidURL: URL
        let markerURL: URL
        let launchBarrierURL: URL
    }

    private func makeXcodeWrapperFixture(in temporaryDirectory: URL,
                                         delayBeforeLaunch: Bool = false,
                                         leaderExitsImmediately: Bool = false,
                                         ignoresTermination: Bool = false,
                                         useRealSandbox: Bool = false) throws -> XcodeWrapperFixture {
        let sourceWrapperURL = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "Tools/Scripts/run_xcodebuild.sh")
        let wrapperURL = temporaryDirectory.appending(path: "run_xcodebuild_test.sh")
        let workerURL = temporaryDirectory.appending(path: "xcodebuild_worker.pl")
        let lockURL = temporaryDirectory.appending(path: "xcodebuild.lock")
        let pidURL = temporaryDirectory.appending(path: "worker.pids")
        let markerURL = temporaryDirectory.appending(path: "grandchild-terminated")
        let launchBarrierURL = temporaryDirectory.appending(path: "launch-barrier")
        let handshakeTemplate = temporaryDirectory.appending(path: "handshake.XXXXXX").path
        var wrapper = try String(contentsOf: sourceWrapperURL, encoding: .utf8)

        try replaceRequired("minimum_kib=83886080", with: "minimum_kib=0", in: &wrapper)
        try replaceRequired("lock_file=/private/tmp/junchat-element-x-ios-xcodebuild.lock",
                            with: "lock_file=\(shellQuote(lockURL.path))", in: &wrapper)
        try replaceRequired("if /usr/bin/pgrep -x xcodebuild >/dev/null 2>&1 || /usr/bin/pgrep -x XCBBuildService >/dev/null 2>&1; then",
                            with: "if /usr/bin/false; then", in: &wrapper)
        try replaceRequired("/usr/bin/mktemp -d /private/tmp/junchat-xcodebuild-handshake.XXXXXX",
                            with: "/usr/bin/mktemp -d \(shellQuote(handshakeTemplate))", in: &wrapper)
        try replaceRequired("/private/tmp/junchat-xcodebuild-handshake.*)",
                            with: "\(temporaryDirectory.path)/handshake.*)", in: &wrapper)
        let launchBarrier = ": > \(shellQuote(launchBarrierURL.path))"
        let launchDelay = delayBeforeLaunch ? "\n/bin/sleep 1" : ""
        try replaceRequired("launching=1\n/usr/bin/perl",
                            with: "launching=1\n\(launchBarrier)\(launchDelay)\n/usr/bin/perl", in: &wrapper)
        if ignoresTermination {
            try replaceRequired("if [ \"$attempts\" -eq 100 ]; then",
                                with: "if [ \"$attempts\" -eq 10 ]; then", in: &wrapper)
        }
        let workerMode = leaderExitsImmediately ? "orphan" : (ignoresTermination ? "ignore" : "wait")
        let workerCommand = "\(shellQuote(workerURL.path)) \(shellQuote(pidURL.path)) " +
            "\(shellQuote(markerURL.path)) \(workerMode)"
        let launchCommand = useRealSandbox ? "/usr/bin/sandbox-exec -p \"$profile\" \(workerCommand) &" :
            "\(workerCommand) &"
        try replaceRequired("/usr/bin/sandbox-exec -p \"$profile\" /usr/bin/xcodebuild \"$@\" &",
                            with: launchCommand,
                            in: &wrapper)

        let worker = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        my ($pid_path, $marker_path, $mode) = @ARGV;
        my $grandchild = fork();
        die "fork failed: $!\n" unless defined $grandchild;
        if ($grandchild == 0) {
            if ($mode eq 'ignore') {
                $SIG{TERM} = 'IGNORE';
            } else {
                $SIG{TERM} = sub {
                    select undef, undef, undef, 1.0;
                    open my $marker, '>', $marker_path or die "marker failed: $!\n";
                    print {$marker} "terminated\n";
                    close $marker or die "marker close failed: $!\n";
                    exit 0;
                };
            }
            sleep 1 while 1;
        }
        if ($mode eq 'wait') {
            $SIG{TERM} = sub {
                waitpid($grandchild, 0);
                exit 0;
            };
        } elsif ($mode eq 'ignore') {
            $SIG{TERM} = 'IGNORE';
        }
        open my $pids, '>', $pid_path or die "pid file failed: $!\n";
        print {$pids} "$$ $grandchild\n";
        close $pids or die "pid file close failed: $!\n";
        exit 0 if $mode eq 'orphan';
        waitpid($grandchild, 0);
        """#
        try Data(wrapper.utf8).write(to: wrapperURL)
        try Data(worker.utf8).write(to: workerURL)
        XCTAssertEqual(chmod(wrapperURL.path, 0o700), 0)
        XCTAssertEqual(chmod(workerURL.path, 0o700), 0)
        return XcodeWrapperFixture(wrapperURL: wrapperURL, lockURL: lockURL,
                                   pidURL: pidURL, markerURL: markerURL,
                                   launchBarrierURL: launchBarrierURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = try ElementCallCandidatePath.systemTemporaryDirectory()
            .appending(path: "element-call-candidate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func permissions(of url: URL) throws -> mode_t {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return information.st_mode & 0o777
    }

    private func replaceRequired(_ target: String, with replacement: String, in value: inout String) throws {
        guard let range = value.range(of: target) else {
            throw NSError(domain: "ElementCallCandidateConsumerTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing wrapper fixture text: \(target)"])
        }
        value.replaceSubrange(range, with: replacement)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            usleep(20000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func processIDs(in url: URL) throws -> [pid_t] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t(String($0)) }
    }

    private func canAcquireLock(_ url: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "exec 9>>\"$1\"; /usr/bin/lockf -s -t 0 9", "lock-probe", url.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private func waitForProcessesToExit(_ pids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ !processIsActive($0) }) {
                return true
            }
            usleep(20000)
        }
        return pids.allSatisfy { !processIsActive($0) }
    }

    private func processIsActive(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func makeTools(mutating tool: String, field: String, value: String) throws -> ElementCallCandidateManifest.JSONObject {
        let binaryKeys = [
            "bootstrapHelper", "buildWrapper", "candidateModule", "git", "gradleDistribution", "gradleWrapperJar",
            "gradleWrapperScript", "java", "mise", "node", "pnpm", "sandboxExec", "swift", "swVers", "tar",
            "verifyWrapper", "xcodebuild", "xcodeSelect", "xcrun"
        ]
        let digest = String(repeating: "a", count: 64)
        let binaries = Dictionary(uniqueKeysWithValues: binaryKeys.map { key in
            (key, ["path": "tools/\(key)", "sha256": digest, "size": 1] as [String: Any])
        })
        var versions: [String: [String: Any]] = [
            "node": ["requirement": "24.13.1", "observed": "v24.13.1"],
            "pnpm": ["requirement": "10.33.0", "observed": "10.33.0"],
            "java": ["requirement": "17", "observed": "openjdk version 17.0.15"],
            "gradle": ["requirement": "8.14.4", "observed": "Gradle 8.14.4"],
            "swift": ["requirement": "6.0", "observed": "Swift version 6.1.2"]
        ]
        versions[tool]?[field] = value
        return try ElementCallCandidateManifest.JSONObject(["binaries": binaries, "versions": versions], label: "test tools")
    }

    private func treeSHA256(path: String, sha256: String, size: Int64) throws -> String {
        var data = try JSONSerialization.data(withJSONObject: [["path": path, "sha256": sha256, "size": size]],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ToolMutation {
        let tool: String
        let field: String
        let value: String
    }
}
