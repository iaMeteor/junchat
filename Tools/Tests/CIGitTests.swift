import Foundation
@testable import Tools
import XCTest

final class CIGitTests: XCTestCase {
    func testRunRejectsSignalTermination() async {
        do {
            try await CI.run(.path("/bin/zsh"), ["-c", "kill -TERM $$"])
            XCTFail("Expected a signal-terminated subprocess to fail.")
        } catch { }
    }

    func testBuildsBranchPushWithAnExplicitExpectedCommitLease() throws {
        let archivedCommit = String(repeating: "a", count: 40)
        let preparedCommit = String(repeating: "b", count: 40)
        let repository = try GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git")

        XCTAssertEqual(CI.gitBranchPushArguments(branch: "release/ios",
                                                 expectedLocalCommit: preparedCommit,
                                                 expectedRemoteCommit: archivedCommit,
                                                 repository: repository), [
                "push",
                "--force-with-lease=refs/heads/release/ios:\(archivedCommit)",
                "https://github.com/acme/junchat-ios.git",
                "\(preparedCommit):refs/heads/release/ios"
            ])
    }

    func testReleaseIdentityRejectsCIEnvironmentAndCheckoutBranchMismatch() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        try await fixture.git(["remote", "add", "origin", "git@github.com:acme/junchat-ios.git"])
        let checkedOutBranch = try await fixture.gitOutput(["symbolic-ref", "--short", "HEAD"])

        do {
            _ = try await CI.gitReleaseIdentityForTesting(repositoryPath: fixture.repository.path,
                                                          ciBranch: "refs/heads/not-\(checkedOutBranch)")
            XCTFail("Expected CI_BRANCH and the symbolic checkout branch to match")
        } catch { }
    }

    func testPinnedReleasePushRejectsRepositoryMutationBeforeInvokingPush() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        try await fixture.git(["remote", "add", "origin", "git@github.com:acme/junchat-ios.git"])
        let checkedOutBranch = try await fixture.gitOutput(["symbolic-ref", "--short", "HEAD"])
        let identity = try await CI.gitReleaseIdentityForTesting(repositoryPath: fixture.repository.path,
                                                                 ciBranch: checkedOutBranch)
        try await fixture.git(["remote", "set-url", "origin", "git@github.com:other/fork.git"])

        let pushMarker = fixture.root.appending(path: "push-invoked")
        let fakeGit = fixture.root.appending(path: "recording-git")
        let script = """
        #!/bin/bash
        set -euo pipefail
        for argument in "$@"; do
            if [[ "$argument" = push ]]; then
                printf '%s\\n' invoked > "\(pushMarker.path)"
            fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        do {
            try await CI.gitPushBranchForTesting(identity: identity,
                                                 expectedLocalCommit: fixture.headCommit,
                                                 expectedRemoteCommit: fixture.baselineCommit,
                                                 repositoryPath: fixture.repository.path,
                                                 gitExecutablePath: fakeGit.path)
            XCTFail("Expected a changed origin to fail before push")
        } catch { }

        XCTAssertFalse(FileManager.default.fileExists(atPath: pushMarker.path))
    }

    func testParsesTheExactModeForEachChangedFile() throws {
        let oldCommit = String(repeating: "b", count: 40)
        let newCommit = String(repeating: "c", count: 40)
        let output = ":100644 120000 \(oldCommit) \(newCommit) M\0project.yml\0"

        XCTAssertEqual(try CI.gitChangedFiles(fromRawDiff: output), [
            .init(path: "project.yml", mode: "120000")
        ])
    }

    func testReleaseCommitUsesCommandScopedIdentityWithoutChangingTheCallerGlobalIdentity() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let globalConfiguration = fixture.root.appending(path: "caller.gitconfig")
        try await fixture.git(["config", "--file", globalConfiguration.path, "user.name", "Caller Name"])
        try await fixture.git(["config", "--file", globalConfiguration.path, "user.email", "caller@example.com"])
        let identityBefore = try await fixture.gitOutput(["config", "--file", globalConfiguration.path, "--get-regexp", "^user\\."])
        let trackedFile = fixture.repository.appending(path: "history.txt")
        try "prepared\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await fixture.git(["add", "history.txt"])

        try await CI.gitCommitForTesting(message: "Prepare release",
                                         repositoryPath: fixture.repository.path,
                                         globalConfigurationPath: globalConfiguration.path)

        let identityAfter = try await fixture.gitOutput(["config", "--file", globalConfiguration.path, "--get-regexp", "^user\\."])
        let commitIdentity = try await fixture.gitOutput(["show", "-s", "--format=%an <%ae>", "HEAD"])
        XCTAssertEqual(identityAfter, identityBefore)
        XCTAssertEqual(commitIdentity, "Element CI <ci@element.io>")
    }

    func testNightlyTagPublicationDoesNotChangeTheCallerGlobalIdentity() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let globalConfiguration = fixture.root.appending(path: "caller.gitconfig")
        try await fixture.git(["config", "--file", globalConfiguration.path, "user.name", "Caller Name"])
        try await fixture.git(["config", "--file", globalConfiguration.path, "user.email", "caller@example.com"])
        let identityBefore = try await fixture.gitOutput(["config", "--file", globalConfiguration.path, "--get-regexp", "^user\\."])

        try await publish("nightly/1.8.2.36",
                          fixture: fixture,
                          globalConfigurationPath: globalConfiguration.path)

        let identityAfter = try await fixture.gitOutput(["config", "--file", globalConfiguration.path, "--get-regexp", "^user\\."])
        XCTAssertEqual(identityAfter, identityBefore)
    }

    func testNightlyTagPublicationIsIdempotentForMatchingLocalAndRemoteTags() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let tagName = "nightly/1.8.2.37"

        try await publish(tagName, fixture: fixture)
        try await publish(tagName, fixture: fixture)

        let remoteCommit = try await fixture.remoteTagCommit(tagName)
        XCTAssertEqual(remoteCommit, fixture.headCommit)
    }

    func testNightlyTagPublicationAcceptsAnAnnotatedLocalTagThatPeelsToHead() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let tagName = "nightly/1.8.2.38"
        try await fixture.git(["tag", "-a", tagName, "-m", "Nightly", fixture.headCommit])

        try await publish(tagName, fixture: fixture)

        let remoteCommit = try await fixture.remoteTagCommit(tagName)
        XCTAssertEqual(remoteCommit, fixture.headCommit)
    }

    func testNightlyTagPublicationRejectsMismatchedLocalAndRemoteTags() async throws {
        let localMismatch = try await LocalGitFixture.make()
        defer { localMismatch.remove() }
        let localTagName = "nightly/1.8.2.39"
        try await localMismatch.git(["tag", localTagName, localMismatch.baselineCommit])

        do {
            try await publish(localTagName, fixture: localMismatch)
            XCTFail("Expected a mismatched local tag to fail closed")
        } catch { }
        let matchingLocalTags = try await localMismatch.remoteTags(matching: localTagName)
        XCTAssertEqual(matchingLocalTags, "")

        let remoteMismatch = try await LocalGitFixture.make()
        defer { remoteMismatch.remove() }
        let remoteTagName = "nightly/1.8.2.40"
        try await remoteMismatch.git(["push",
                                      remoteMismatch.remote.path,
                                      "\(remoteMismatch.baselineCommit):refs/tags/\(remoteTagName)"])

        do {
            try await publish(remoteTagName, fixture: remoteMismatch)
            XCTFail("Expected a mismatched remote tag to fail closed")
        } catch { }
        let mismatchedRemoteCommit = try await remoteMismatch.remoteTagCommit(remoteTagName)
        XCTAssertEqual(mismatchedRemoteCommit, remoteMismatch.baselineCommit)
    }

    func testNightlyTagPublicationAcceptsAnExactRemoteAfterSignalTerminatedPush() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let tagName = "nightly/1.8.2.41"
        let fakeGit = fixture.root.appending(path: "signal-after-push-git")
        let script = """
        #!/bin/bash
        set -euo pipefail
        is_push=0
        for argument in "$@"; do
            if [[ "$argument" = push ]]; then
                is_push=1
            fi
        done
        /usr/bin/git "$@"
        if [[ "$is_push" = 1 ]]; then
            kill -TERM "$$"
        fi
        """
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        try await publish(tagName, fixture: fixture, gitExecutablePath: fakeGit.path)

        let remoteCommit = try await fixture.remoteTagCommit(tagName)
        XCTAssertEqual(remoteCommit, fixture.headCommit)
    }

    func testNightlyTagPublicationRejectsAFailedPushWhenTheRemoteTagIsAbsent() async throws {
        let fixture = try await LocalGitFixture.make()
        defer { fixture.remove() }
        let tagName = "nightly/1.8.2.42"
        let fakeGit = fixture.root.appending(path: "fail-before-push-git")
        let script = """
        #!/bin/bash
        set -euo pipefail
        for argument in "$@"; do
            if [[ "$argument" = push ]]; then
                exit 1
            fi
        done
        exec /usr/bin/git "$@"
        """
        try script.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        do {
            try await publish(tagName, fixture: fixture, gitExecutablePath: fakeGit.path)
            XCTFail("Expected an unconfirmed failed push to fail closed")
        } catch { }

        let remoteTags = try await fixture.remoteTags(matching: tagName)
        XCTAssertEqual(remoteTags, "")
    }

    private func publish(_ tagName: String,
                         fixture: LocalGitFixture,
                         gitExecutablePath: String? = nil,
                         globalConfigurationPath: String? = nil) async throws {
        try await CI.gitPushTagForTesting(tagName: tagName,
                                          expectedCommit: fixture.headCommit,
                                          remoteURL: fixture.remote.path,
                                          repositoryPath: fixture.repository.path,
                                          gitExecutablePath: gitExecutablePath,
                                          globalConfigurationPath: globalConfigurationPath)
    }
}

private struct LocalGitFixture {
    let root: URL
    let repository: URL
    let remote: URL
    let baselineCommit: String
    let headCommit: String

    static func make() async throws -> LocalGitFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = LocalGitFixture(root: root,
                                      repository: repository,
                                      remote: remote,
                                      baselineCommit: "",
                                      headCommit: "")
        try await fixture.gitCommand(["init", "--bare", remote.path])
        try await fixture.gitCommand(["init", repository.path])
        try await fixture.git(["config", "user.name", "Release Test"])
        try await fixture.git(["config", "user.email", "release-test@example.com"])

        let trackedFile = repository.appending(path: "history.txt")
        try "baseline\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await fixture.git(["add", "history.txt"])
        try await fixture.git(["commit", "-m", "Baseline"])
        let baselineCommit = try await fixture.gitOutput(["rev-parse", "HEAD"])

        try "head\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await fixture.git(["commit", "-am", "Head"])
        let headCommit = try await fixture.gitOutput(["rev-parse", "HEAD"])

        return LocalGitFixture(root: root,
                               repository: repository,
                               remote: remote,
                               baselineCommit: baselineCommit,
                               headCommit: headCommit)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        try await gitCommand(["-C", repository.path] + arguments)
    }

    @discardableResult
    func gitBare(_ arguments: [String]) async throws -> String {
        try await gitCommand(["--git-dir", remote.path] + arguments)
    }

    func gitOutput(_ arguments: [String]) async throws -> String {
        try await git(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteTagCommit(_ tagName: String) async throws -> String {
        try await gitBare(["rev-parse", "refs/tags/\(tagName)^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteTags(matching tagName: String) async throws -> String {
        try await gitBare(["tag", "--list", tagName])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func gitCommand(_ arguments: [String]) async throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw LocalGitError.commandFailed(arguments)
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard let outputString = String(data: outputData, encoding: .utf8) else {
            throw LocalGitError.invalidOutputEncoding
        }
        return outputString
    }

    private enum LocalGitError: Error {
        case commandFailed([String])
        case invalidOutputEncoding
    }
}
