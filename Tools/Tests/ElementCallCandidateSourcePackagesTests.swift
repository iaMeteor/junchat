/*
 * Copyright 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

import Darwin
import Foundation
@testable import Tools
import XCTest

final class ElementCallCandidateSourcePackagesTests: XCTestCase {
    func testSourcePackagesPathIsRequiredOnlyForCandidateMode() throws {
        XCTAssertNil(try ElementCallCandidateSourcePackages.resolve(path: nil, candidateRequested: false))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.resolve(path: "/private/tmp/SourcePackages",
                                                                            candidateRequested: false))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.resolve(path: nil, candidateRequested: true))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.resolve(path: "relative/SourcePackages",
                                                                            candidateRequested: true))
        XCTAssertEqual(try ElementCallCandidateSourcePackages.resolve(path: "/private/tmp/SourcePackages",
                                                                      candidateRequested: true)?.path,
                       "/private/tmp/SourcePackages")
    }

    func testStagesExactOfflineSourcePackagesWithoutMutatingSeed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let originalWorkspaceState = try Data(contentsOf: fixture.workspaceStateURL)
        let originalOrigin = try git(["-C", fixture.checkoutURL.path, "remote", "get-url", "origin"])
        let stagedURL = try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                     publicResolutionData: fixture.publicResolutionData,
                                                                     under: fixture.candidateRootURL)

        XCTAssertEqual(stagedURL.path, fixture.candidateRootURL.appending(path: "SourcePackages").path)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceStateURL), originalWorkspaceState)
        XCTAssertEqual(try git(["-C", fixture.checkoutURL.path, "remote", "get-url", "origin"]), originalOrigin)
        XCTAssertEqual(try permissions(of: stagedURL), 0o700)

        let stagedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stagedURL.appending(path: "workspace-state.json"))) as? [String: Any])
        let object = try XCTUnwrap(stagedState["object"] as? [String: Any])
        let artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
        let prebuilts = try XCTUnwrap(object["prebuilts"] as? [[String: Any]])
        XCTAssertEqual(artifacts[0]["path"] as? String,
                       stagedURL.appending(path: "artifacts/fixture/Fixture.xcframework").path)
        XCTAssertEqual(prebuilts[0]["checkoutPath"] as? String,
                       stagedURL.appending(path: "checkouts/Fixture").path)
        XCTAssertEqual(prebuilts[0]["path"] as? String,
                       stagedURL.appending(path: "prebuilts/fixture/FixtureSupport").path)

        let stagedCheckoutURL = stagedURL.appending(path: "checkouts/Fixture")
        XCTAssertEqual(try git(["-C", stagedCheckoutURL.path, "rev-parse", "HEAD"]), fixture.revision + "\n")
        XCTAssertEqual(try git(["-C", stagedCheckoutURL.path, "status", "--porcelain=v1",
                                "--untracked-files=all", "--ignore-submodules=none"]), "")
        XCTAssertEqual(try git(["-C", stagedCheckoutURL.path, "remote", "get-url", "origin"]),
                       stagedURL.appending(path: "repositories/Fixture-fixture").path + "\n")
    }

    func testStagesInitializedSubmoduleMetadataInsideSnapshot() throws {
        let fixture = try makeFixture(includeSubmodule: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let stagedURL = try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                     publicResolutionData: fixture.publicResolutionData,
                                                                     under: fixture.candidateRootURL)
        let stagedCheckoutURL = stagedURL.appending(path: "checkouts/Fixture")
        let submoduleStatus = try git(["-C", stagedCheckoutURL.path, "submodule", "status", "--recursive"])
        XCTAssertTrue(submoduleStatus.contains("Vendor/Submodule"))
        let metadata = try String(contentsOf: stagedCheckoutURL.appending(path: "Vendor/Submodule/.git"),
                                  encoding: .utf8)
        XCTAssertTrue(metadata.hasPrefix("gitdir: "))
        XCTAssertFalse(metadata.contains(fixture.sourcePackagesURL.path))
    }

    func testStagesRevisionOnlyPinWhenWorkspaceMatchesExactly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var publicRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.publicResolutionData) as? [String: Any])
        var publicPins = try XCTUnwrap(publicRoot["pins"] as? [[String: Any]])
        var publicState = try XCTUnwrap(publicPins[0]["state"] as? [String: Any])
        publicState["version"] = nil
        publicPins[0]["state"] = publicState
        publicRoot["pins"] = publicPins
        try mutateWorkspaceState(fixture) { object in
            var dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
            var state = try XCTUnwrap(dependencies[0]["state"] as? [String: Any])
            var checkoutState = try XCTUnwrap(state["checkoutState"] as? [String: Any])
            checkoutState["version"] = nil
            state["checkoutState"] = checkoutState
            dependencies[0]["state"] = state
            object["dependencies"] = dependencies
        }

        XCTAssertNoThrow(try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                      publicResolutionData: jsonData(publicRoot),
                                                                      under: fixture.candidateRootURL))
    }

    func testRejectsPublicPinDrift() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.publicResolutionData) as? [String: Any])
        var pins = try XCTUnwrap(root["pins"] as? [[String: Any]])
        var state = try XCTUnwrap(pins[0]["state"] as? [String: Any])
        state["revision"] = String(repeating: "b", count: 40)
        pins[0]["state"] = state
        root["pins"] = pins

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                          publicResolutionData: jsonData(root),
                                                                          under: fixture.candidateRootURL))
    }

    func testRejectsWrongCheckoutHeadAndDirtyCheckout() throws {
        let wrongHeadFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: wrongHeadFixture.rootURL) }
        try Data("second\n".utf8).write(to: wrongHeadFixture.checkoutURL.appending(path: "Second.txt"))
        _ = try git(["-C", wrongHeadFixture.checkoutURL.path, "add", "Second.txt"])
        _ = try git(["-C", wrongHeadFixture.checkoutURL.path, "commit", "-m", "Second"])
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: wrongHeadFixture.sourcePackagesURL,
                                                                          publicResolutionData: wrongHeadFixture.publicResolutionData,
                                                                          under: wrongHeadFixture.candidateRootURL))

        let dirtyFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dirtyFixture.rootURL) }
        try Data("dirty\n".utf8).write(to: dirtyFixture.checkoutURL.appending(path: "Dirty.txt"))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: dirtyFixture.sourcePackagesURL,
                                                                          publicResolutionData: dirtyFixture.publicResolutionData,
                                                                          under: dirtyFixture.candidateRootURL))
    }

    func testRejectsHiddenCheckoutMutationAndLocalFilterConfiguration() throws {
        let hiddenMutationFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: hiddenMutationFixture.rootURL) }
        _ = try git(["-C", hiddenMutationFixture.checkoutURL.path,
                     "update-index", "--skip-worktree", "Fixture.txt"])
        try Data("hidden mutation\n".utf8)
            .write(to: hiddenMutationFixture.checkoutURL.appending(path: "Fixture.txt"))

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: hiddenMutationFixture.sourcePackagesURL,
                                                                          publicResolutionData: hiddenMutationFixture.publicResolutionData,
                                                                          under: hiddenMutationFixture.candidateRootURL))

        let filterFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: filterFixture.rootURL) }
        _ = try git(["-C", filterFixture.checkoutURL.path,
                     "config", "filter.fixture.process", "/usr/bin/false"])

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: filterFixture.sourcePackagesURL,
                                                                          publicResolutionData: filterFixture.publicResolutionData,
                                                                          under: filterFixture.candidateRootURL))
    }

    func testAllowsOnlyEmptyUntrackedSwiftPMWorkspaceScaffolding() throws {
        let emptyFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: emptyFixture.rootURL) }
        let emptyScaffoldingURL = emptyFixture.checkoutURL.appending(path: ".swiftpm/xcode")
        try FileManager.default.createDirectory(at: emptyScaffoldingURL,
                                                withIntermediateDirectories: true)

        XCTAssertNoThrow(try ElementCallCandidateSourcePackages.stage(from: emptyFixture.sourcePackagesURL,
                                                                      publicResolutionData: emptyFixture.publicResolutionData,
                                                                      under: emptyFixture.candidateRootURL))

        let populatedFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: populatedFixture.rootURL) }
        let populatedScaffoldingURL = populatedFixture.checkoutURL.appending(path: ".swiftpm/xcode")
        try FileManager.default.createDirectory(at: populatedScaffoldingURL,
                                                withIntermediateDirectories: true)
        try Data("untracked\n".utf8).write(to: populatedScaffoldingURL.appending(path: "Injected"))

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: populatedFixture.sourcePackagesURL,
                                                                          publicResolutionData: populatedFixture.publicResolutionData,
                                                                          under: populatedFixture.candidateRootURL))
    }

    func testValidatesTrackedGitAttributeCheckoutConversionWithoutAllowingMutation() throws {
        let convertedFixture = try makeFixture(includeCRLFFile: true)
        defer { try? FileManager.default.removeItem(at: convertedFixture.rootURL) }

        XCTAssertNoThrow(try ElementCallCandidateSourcePackages.stage(from: convertedFixture.sourcePackagesURL,
                                                                      publicResolutionData: convertedFixture.publicResolutionData,
                                                                      under: convertedFixture.candidateRootURL))

        let mutatedFixture = try makeFixture(includeCRLFFile: true)
        defer { try? FileManager.default.removeItem(at: mutatedFixture.rootURL) }
        try Data("@echo off\r\necho changed\r\n".utf8)
            .write(to: mutatedFixture.checkoutURL.appending(path: "Fixture.bat"))

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: mutatedFixture.sourcePackagesURL,
                                                                          publicResolutionData: mutatedFixture.publicResolutionData,
                                                                          under: mutatedFixture.candidateRootURL))
    }

    func testAllowsBrokenTrackedSymlinkOnlyWhenLexicallyConfined() throws {
        let confinedFixture = try makeFixture(trackedSymlinkDestination: "../.agents/skills/")
        defer { try? FileManager.default.removeItem(at: confinedFixture.rootURL) }

        XCTAssertNoThrow(try ElementCallCandidateSourcePackages.stage(from: confinedFixture.sourcePackagesURL,
                                                                      publicResolutionData: confinedFixture.publicResolutionData,
                                                                      under: confinedFixture.candidateRootURL))

        let escapingFixture = try makeFixture(trackedSymlinkDestination: "../../OutsideMissing")
        defer { try? FileManager.default.removeItem(at: escapingFixture.rootURL) }

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: escapingFixture.sourcePackagesURL,
                                                                          publicResolutionData: escapingFixture.publicResolutionData,
                                                                          under: escapingFixture.candidateRootURL))
    }

    func testRejectsRedirectedOrExecutableGitControlState() throws {
        let configFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: configFixture.rootURL) }
        let configURL = configFixture.checkoutURL.appending(path: ".git/config")
        let externalConfigURL = configFixture.rootURL.appending(path: "ExternalGitConfig")
        try FileManager.default.moveItem(at: configURL, to: externalConfigURL)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: externalConfigURL)
        let originalExternalConfig = try Data(contentsOf: externalConfigURL)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: configFixture.sourcePackagesURL,
                                                                          publicResolutionData: configFixture.publicResolutionData,
                                                                          under: configFixture.candidateRootURL))
        XCTAssertEqual(try Data(contentsOf: externalConfigURL), originalExternalConfig)

        let worktreeConfigFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: worktreeConfigFixture.rootURL) }
        _ = try git(["-C", worktreeConfigFixture.checkoutURL.path,
                     "config", "extensions.worktreeConfig", "true"])
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: worktreeConfigFixture.sourcePackagesURL,
                                                                          publicResolutionData: worktreeConfigFixture.publicResolutionData,
                                                                          under: worktreeConfigFixture.candidateRootURL)) { error in
            XCTAssertNotNil(error.localizedDescription.range(of: "worktree", options: .caseInsensitive))
        }

        let hookFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: hookFixture.rootURL) }
        let hookURL = hookFixture.checkoutURL.appending(path: ".git/hooks/post-checkout")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hookURL)
        XCTAssertEqual(chmod(hookURL.path, 0o700), 0)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: hookFixture.sourcePackagesURL,
                                                                          publicResolutionData: hookFixture.publicResolutionData,
                                                                          under: hookFixture.candidateRootURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("active hook"))
        }

        let commonDirectoryFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: commonDirectoryFixture.rootURL) }
        try Data(".\n".utf8)
            .write(to: commonDirectoryFixture.checkoutURL.appending(path: ".git/commondir"))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: commonDirectoryFixture.sourcePackagesURL,
                                                                          publicResolutionData: commonDirectoryFixture.publicResolutionData,
                                                                          under: commonDirectoryFixture.candidateRootURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("common directory"))
        }

        let attributesFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: attributesFixture.rootURL) }
        try Data("Fixture.txt -text\n".utf8)
            .write(to: attributesFixture.checkoutURL.appending(path: ".git/info/attributes"))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: attributesFixture.sourcePackagesURL,
                                                                          publicResolutionData: attributesFixture.publicResolutionData,
                                                                          under: attributesFixture.candidateRootURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("attributes"))
        }
    }

    func testRebasesCheckoutAlternateObjectStoreIntoSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourceAlternate = fixture.sourcePackagesURL
            .appending(path: "repositories/Fixture-fixture/objects").path
        let nestedAlternate = fixture.sourcePackagesURL
            .appending(path: "repositories/Nested-fixture/objects")
        try FileManager.default.createDirectory(at: nestedAlternate.appending(path: "info"),
                                                withIntermediateDirectories: true)
        let alternateURL = fixture.checkoutURL.appending(path: ".git/objects/info/alternates")
        try Data((sourceAlternate + "\n").utf8).write(to: alternateURL)
        try Data((nestedAlternate.path + "\n").utf8)
            .write(to: URL(filePath: sourceAlternate).appending(path: "info/alternates"))

        let stagedURL = try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                     publicResolutionData: fixture.publicResolutionData,
                                                                     under: fixture.candidateRootURL)
        let stagedAlternateURL = stagedURL.appending(path: "checkouts/Fixture/.git/objects/info/alternates")
        let stagedAlternate = try String(contentsOf: stagedAlternateURL, encoding: .utf8)

        XCTAssertEqual(stagedAlternate,
                       stagedURL.appending(path: "repositories/Fixture-fixture/objects").path + "\n")
        XCTAssertFalse(stagedAlternate.contains(fixture.sourcePackagesURL.path))
        let stagedNestedAlternate = try String(contentsOf: stagedURL
            .appending(path: "repositories/Fixture-fixture/objects/info/alternates"), encoding: .utf8)
        XCTAssertEqual(stagedNestedAlternate,
                       stagedURL.appending(path: "repositories/Nested-fixture/objects").path + "\n")
        XCTAssertFalse(stagedNestedAlternate.contains(fixture.sourcePackagesURL.path))

        let externalFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: externalFixture.rootURL) }
        let externalObjects = externalFixture.rootURL.appending(path: "ExternalObjects")
        try FileManager.default.createDirectory(at: externalObjects, withIntermediateDirectories: false)
        let externalRepositoryObjects = externalFixture.sourcePackagesURL
            .appending(path: "repositories/Fixture-fixture/objects")
        try Data((externalRepositoryObjects.path + "\n").utf8)
            .write(to: externalFixture.checkoutURL.appending(path: ".git/objects/info/alternates"))
        try Data((externalObjects.path + "\n").utf8)
            .write(to: externalRepositoryObjects.appending(path: "info/alternates"))
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: externalFixture.sourcePackagesURL,
                                                                          publicResolutionData: externalFixture.publicResolutionData,
                                                                          under: externalFixture.candidateRootURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("escapes"))
        }
    }

    func testRejectsSymlinkedReachableAlternateObjectStoreEntry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let alternateObjectsURL = fixture.sourcePackagesURL
            .appending(path: "repositories/Fixture-fixture/objects")
        try Data((alternateObjectsURL.path + "\n").utf8)
            .write(to: fixture.checkoutURL.appending(path: ".git/objects/info/alternates"))
        let outsideObjectURL = fixture.rootURL.appending(path: "OutsideObject")
        try Data("outside\n".utf8).write(to: outsideObjectURL)
        let packURL = alternateObjectsURL.appending(path: "pack")
        try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: packURL.appending(path: "escape.pack"),
                                                   withDestinationURL: outsideObjectURL)

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                          publicResolutionData: fixture.publicResolutionData,
                                                                          under: fixture.candidateRootURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("object store"))
        }
    }

    func testRejectsDuplicateWorkspaceKeysAndTraversal() throws {
        let duplicateFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: duplicateFixture.rootURL) }
        let original = try String(contentsOf: duplicateFixture.workspaceStateURL, encoding: .utf8)
        let duplicate = original.replacingOccurrences(of: #""version":7"#,
                                                      with: #""version":7,"version":7"#)
        try Data(duplicate.utf8).write(to: duplicateFixture.workspaceStateURL)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: duplicateFixture.sourcePackagesURL,
                                                                          publicResolutionData: duplicateFixture.publicResolutionData,
                                                                          under: duplicateFixture.candidateRootURL))

        let traversalFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: traversalFixture.rootURL) }
        try mutateWorkspaceState(traversalFixture) { object in
            var dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
            dependencies[0]["subpath"] = "../Fixture"
            object["dependencies"] = dependencies
        }
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: traversalFixture.sourcePackagesURL,
                                                                          publicResolutionData: traversalFixture.publicResolutionData,
                                                                          under: traversalFixture.candidateRootURL))
    }

    func testRejectsOutsidePathsAndUnexpectedLocalOrigin() throws {
        let outsideFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: outsideFixture.rootURL) }
        try mutateWorkspaceState(outsideFixture) { object in
            var artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
            artifacts[0]["path"] = outsideFixture.rootURL.path
            object["artifacts"] = artifacts
        }
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: outsideFixture.sourcePackagesURL,
                                                                          publicResolutionData: outsideFixture.publicResolutionData,
                                                                          under: outsideFixture.candidateRootURL))

        let originFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: originFixture.rootURL) }
        _ = try git(["-C", originFixture.checkoutURL.path, "remote", "set-url", "origin", originFixture.rootURL.path])
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: originFixture.sourcePackagesURL,
                                                                          publicResolutionData: originFixture.publicResolutionData,
                                                                          under: originFixture.candidateRootURL))
    }

    func testCachedSymlinksMustRemainInsideTheSnapshot() throws {
        let escapingFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: escapingFixture.rootURL) }
        let outsideFileURL = escapingFixture.rootURL.appending(path: "OutsideBinary")
        try Data("outside".utf8).write(to: outsideFileURL)
        try FileManager.default.createSymbolicLink(at: escapingFixture.sourcePackagesURL
            .appending(path: "artifacts/fixture/Fixture.xcframework/Escape"),
            withDestinationURL: outsideFileURL)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: escapingFixture.sourcePackagesURL,
                                                                          publicResolutionData: escapingFixture.publicResolutionData,
                                                                          under: escapingFixture.candidateRootURL)) { error in
            XCTAssertNotNil(error.localizedDescription.range(of: "destination", options: .caseInsensitive))
        }

        let internalFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: internalFixture.rootURL) }
        let artifactURL = internalFixture.sourcePackagesURL
            .appending(path: "artifacts/fixture/Fixture.xcframework")
        try Data("binary".utf8).write(to: artifactURL.appending(path: "Binary"))
        try FileManager.default.createSymbolicLink(atPath: artifactURL.appending(path: "Current").path,
                                                   withDestinationPath: "Binary")
        let stagedURL = try ElementCallCandidateSourcePackages.stage(from: internalFixture.sourcePackagesURL,
                                                                     publicResolutionData: internalFixture.publicResolutionData,
                                                                     under: internalFixture.candidateRootURL)
        let stagedLinkURL = stagedURL.appending(path: "artifacts/fixture/Fixture.xcframework/Current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stagedLinkURL.path), "Binary")
        XCTAssertEqual(try Data(contentsOf: stagedLinkURL), Data("binary".utf8))
    }

    func testRejectsSymlinkedSeedAndExistingDestination() throws {
        let symlinkFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: symlinkFixture.rootURL) }
        let symlinkURL = symlinkFixture.rootURL.appending(path: "SourcePackagesLink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkFixture.sourcePackagesURL)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: symlinkURL,
                                                                          publicResolutionData: symlinkFixture.publicResolutionData,
                                                                          under: symlinkFixture.candidateRootURL))

        let existingFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: existingFixture.rootURL) }
        try FileManager.default.createDirectory(at: existingFixture.candidateRootURL.appending(path: "SourcePackages"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: existingFixture.sourcePackagesURL,
                                                                          publicResolutionData: existingFixture.publicResolutionData,
                                                                          under: existingFixture.candidateRootURL))
    }

    func testRejectsExternalCheckoutGitMetadataWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let gitURL = fixture.checkoutURL.appending(path: ".git")
        let externalGitURL = fixture.rootURL.appending(path: "ExternalFixtureGit")
        try FileManager.default.moveItem(at: gitURL, to: externalGitURL)
        try FileManager.default.createSymbolicLink(at: gitURL, withDestinationURL: externalGitURL)
        let originalOrigin = try git(["-C", fixture.checkoutURL.path, "remote", "get-url", "origin"])

        XCTAssertThrowsError(try ElementCallCandidateSourcePackages.stage(from: fixture.sourcePackagesURL,
                                                                          publicResolutionData: fixture.publicResolutionData,
                                                                          under: fixture.candidateRootURL))
        XCTAssertEqual(try git(["-C", fixture.checkoutURL.path, "remote", "get-url", "origin"]),
                       originalOrigin)
    }

    private struct Fixture {
        let rootURL: URL
        let sourcePackagesURL: URL
        let candidateRootURL: URL
        let workspaceStateURL: URL
        let checkoutURL: URL
        let revision: String
        let publicResolutionData: Data
    }

    private func makeFixture(includeSubmodule: Bool = false,
                             includeCRLFFile: Bool = false,
                             trackedSymlinkDestination: String? = nil) throws -> Fixture {
        let rootURL = try ElementCallCandidatePath.systemTemporaryDirectory()
            .appending(path: "element-call-source-packages-tests-\(UUID().uuidString)")
        try makeDirectory(rootURL)
        let sourcePackagesURL = rootURL.appending(path: "SeedSourcePackages")
        let candidateRootURL = rootURL.appending(path: "Candidate")
        try makeDirectory(sourcePackagesURL)
        try makeDirectory(candidateRootURL)
        for path in ["checkouts", "repositories", "artifacts/fixture/Fixture.xcframework",
                     "prebuilts/fixture/FixtureSupport"] {
            try FileManager.default.createDirectory(at: sourcePackagesURL.appending(path: path),
                                                    withIntermediateDirectories: true)
        }

        let checkoutURL = sourcePackagesURL.appending(path: "checkouts/Fixture")
        try FileManager.default.createDirectory(at: checkoutURL, withIntermediateDirectories: false)
        _ = try git(["init", checkoutURL.path])
        _ = try git(["-C", checkoutURL.path, "config", "user.name", "Element Call Tests"])
        _ = try git(["-C", checkoutURL.path, "config", "user.email", "element-call-tests@example.invalid"])
        try Data("fixture\n".utf8).write(to: checkoutURL.appending(path: "Fixture.txt"))
        _ = try git(["-C", checkoutURL.path, "add", "Fixture.txt"])
        _ = try git(["-C", checkoutURL.path, "commit", "-m", "Fixture"])
        if includeSubmodule {
            try addSubmoduleFixture(to: checkoutURL, under: rootURL)
        }
        if includeCRLFFile {
            try addCRLFFixture(to: checkoutURL)
        }
        if let trackedSymlinkDestination {
            try addTrackedSymlinkFixture(to: checkoutURL, destination: trackedSymlinkDestination)
        }
        let revision = try git(["-C", checkoutURL.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let repositoryURL = sourcePackagesURL.appending(path: "repositories/Fixture-fixture")
        _ = try git(["clone", "--bare", checkoutURL.path, repositoryURL.path])
        _ = try git(["-C", checkoutURL.path, "remote", "add", "origin", repositoryURL.path])

        let packageReference: [String: Any] = [
            "identity": "fixture",
            "kind": "remoteSourceControl",
            "location": "https://example.invalid/Fixture",
            "name": "Fixture"
        ]
        let checkoutState: [String: Any] = ["revision": revision, "version": "1.0.0"]
        let workspaceState: [String: Any] = [
            "version": 7,
            "object": [
                "dependencies": [[
                    "basedOn": NSNull(),
                    "packageRef": packageReference,
                    "state": ["checkoutState": checkoutState, "name": "sourceControlCheckout"],
                    "subpath": "Fixture"
                ]],
                "artifacts": [[
                    "kind": ["xcframework": [:]],
                    "packageRef": packageReference,
                    "path": sourcePackagesURL.appending(path: "artifacts/fixture/Fixture.xcframework").path,
                    "source": ["checksum": String(repeating: "c", count: 64),
                               "type": "remote", "url": "https://example.invalid/Fixture.zip"],
                    "targetName": "Fixture"
                ]],
                "prebuilts": [[
                    "checkoutPath": checkoutURL.path,
                    "cModules": [],
                    "identity": "fixture",
                    "includePath": [],
                    "libraryName": "FixtureSupport",
                    "path": sourcePackagesURL.appending(path: "prebuilts/fixture/FixtureSupport").path,
                    "products": ["Fixture"],
                    "version": "1.0.0"
                ]]
            ]
        ]
        let workspaceStateURL = sourcePackagesURL.appending(path: "workspace-state.json")
        try jsonData(workspaceState).write(to: workspaceStateURL)

        let publicResolution: [String: Any] = [
            "originHash": String(repeating: "a", count: 64),
            "pins": [[
                "identity": "fixture",
                "kind": "remoteSourceControl",
                "location": "https://example.invalid/Fixture",
                "state": checkoutState
            ]],
            "version": 3
        ]
        return try Fixture(rootURL: rootURL,
                           sourcePackagesURL: sourcePackagesURL,
                           candidateRootURL: candidateRootURL,
                           workspaceStateURL: workspaceStateURL,
                           checkoutURL: checkoutURL,
                           revision: revision,
                           publicResolutionData: jsonData(publicResolution))
    }

    private func addSubmoduleFixture(to checkoutURL: URL, under rootURL: URL) throws {
        let submoduleSourceURL = rootURL.appending(path: "FixtureSubmoduleSource")
        try FileManager.default.createDirectory(at: submoduleSourceURL, withIntermediateDirectories: false)
        _ = try git(["init", submoduleSourceURL.path])
        _ = try git(["-C", submoduleSourceURL.path, "config", "user.name", "Element Call Tests"])
        _ = try git(["-C", submoduleSourceURL.path, "config", "user.email", "element-call-tests@example.invalid"])
        try Data("submodule\n".utf8).write(to: submoduleSourceURL.appending(path: "Submodule.txt"))
        _ = try git(["-C", submoduleSourceURL.path, "add", "Submodule.txt"])
        _ = try git(["-C", submoduleSourceURL.path, "commit", "-m", "Submodule"])
        _ = try git(["-c", "protocol.file.allow=always", "-C", checkoutURL.path,
                     "submodule", "add", "--name", "FixtureSubmodule",
                     submoduleSourceURL.path, "Vendor/Submodule"])
        _ = try git(["config", "--file", checkoutURL.appending(path: ".gitmodules").path,
                     "submodule.FixtureSubmodule.url", "https://example.invalid/FixtureSubmodule"])
        _ = try git(["-C", checkoutURL.path, "submodule", "sync", "--", "Vendor/Submodule"])
        _ = try git(["-C", checkoutURL.path, "add", ".gitmodules", "Vendor/Submodule"])
        _ = try git(["-C", checkoutURL.path, "commit", "-m", "Add submodule"])
    }

    private func addCRLFFixture(to checkoutURL: URL) throws {
        try Data("*.bat text eol=crlf\n".utf8)
            .write(to: checkoutURL.appending(path: ".gitattributes"))
        try Data("@echo off\necho fixture\n".utf8)
            .write(to: checkoutURL.appending(path: "Fixture.bat"))
        _ = try git(["-C", checkoutURL.path, "add", ".gitattributes", "Fixture.bat"])
        _ = try git(["-C", checkoutURL.path, "commit", "-m", "Add CRLF fixture"])
        try FileManager.default.removeItem(at: checkoutURL.appending(path: "Fixture.bat"))
        _ = try git(["-C", checkoutURL.path, "checkout", "--", "Fixture.bat"])
    }

    private func addTrackedSymlinkFixture(to checkoutURL: URL, destination: String) throws {
        let directoryURL = checkoutURL.appending(path: ".claude")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: directoryURL.appending(path: "skills").path,
                                                   withDestinationPath: destination)
        _ = try git(["-C", checkoutURL.path, "add", ".claude/skills"])
        _ = try git(["-C", checkoutURL.path, "commit", "-m", "Add symlink fixture"])
    }

    private func mutateWorkspaceState(_ fixture: Fixture,
                                      mutation: (inout [String: Any]) throws -> Void) throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.workspaceStateURL)) as? [String: Any])
        var object = try XCTUnwrap(root["object"] as? [String: Any])
        try mutation(&object)
        root["object"] = object
        try jsonData(root).write(to: fixture.workspaceStateURL)
    }

    private func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(try permissions(of: url), 0o700)
    }

    private func permissions(of url: URL) throws -> mode_t {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return information.st_mode & 0o777
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false",
                             "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_OPTIONAL_LOCKS": "0", "HOME": FileManager.default.temporaryDirectory.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ElementCallCandidateSourcePackagesTests",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(data: outputData, encoding: .utf8) ?? "git failed"])
        }
        guard let value = String(data: outputData, encoding: .utf8) else {
            throw NSError(domain: "ElementCallCandidateSourcePackagesTests",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "git returned non-UTF-8 output"])
        }
        return value
    }
}
