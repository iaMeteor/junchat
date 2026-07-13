@testable import Tools
import XCTest

final class GitHubRepositoryTests: XCTestCase {
    func testParsesSupportedGitHubOriginFormats() throws {
        let remotes = [
            "git@github.com:iaMeteor/junchat.git",
            "ssh://git@github.com/iaMeteor/junchat.git",
            "https://github.com/iaMeteor/junchat.git",
            "https://github.com/iaMeteor/junchat"
        ]

        for remote in remotes {
            let repository = try GitHubRepository(remoteURL: remote)

            XCTAssertEqual(repository.slug, "iaMeteor/junchat")
            XCTAssertEqual(repository.httpsURL.absoluteString, "https://github.com/iaMeteor/junchat.git")
            XCTAssertEqual(repository.releasesAPIURL.absoluteString,
                           "https://api.github.com/repos/iaMeteor/junchat/releases")
        }
    }

    func testRejectsNonGitHubOrAmbiguousOrigins() throws {
        for remote in [
            "git@example.com:iaMeteor/junchat.git",
            "git@github.com:../junchat.git",
            "https://token@github.com/iaMeteor/junchat.git",
            "ssh://someone@github.com/iaMeteor/junchat.git",
            "https://github.com/iaMeteor",
            "https://github.com/iaMeteor/junchat/extra",
            "not a remote"
        ] {
            XCTAssertThrowsError(try GitHubRepository(remoteURL: remote))
        }
    }
}
