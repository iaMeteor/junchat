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
        let repository = try GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git")

        XCTAssertEqual(CI.gitBranchPushArguments(branch: "release/ios",
                                                 expectedRemoteCommit: archivedCommit,
                                                 repository: repository), [
                "push",
                "--force-with-lease=refs/heads/release/ios:\(archivedCommit)",
                "https://github.com/acme/junchat-ios.git",
                "HEAD:refs/heads/release/ios"
            ])
    }

    func testParsesTheExactModeForEachChangedFile() throws {
        let oldCommit = String(repeating: "b", count: 40)
        let newCommit = String(repeating: "c", count: 40)
        let output = ":100644 120000 \(oldCommit) \(newCommit) M\0project.yml\0"

        XCTAssertEqual(try CI.gitChangedFiles(fromRawDiff: output), [
            .init(path: "project.yml", mode: "120000")
        ])
    }
}
