import ArgumentParser
import Foundation

struct PublishedJunchatReleaseTags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "published-junchat-release-tags",
                                                    abstract: "Prints published JunChat release IDs, tags and peeled commits from GitHub.")

    @Option(help: "The repository remote URL used to identify the GitHub repository.")
    var repositoryURL: String

    func run() async throws {
        guard let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty else {
            throw ValidationError("GITHUB_TOKEN environment variable is not set.")
        }

        let repository = try GitHubRepository(remoteURL: repositoryURL)
        let releases = try await GitHubReleaseAPI().publishedReleases(repository: repository,
                                                                      token: token)
        let snapshot = releases.map { "\($0.id)\t\($0.tagName)\t\($0.tagCommit)" }
            .joined(separator: "\n")
        if !snapshot.isEmpty {
            FileHandle.standardOutput.write(Data("\(snapshot)\n".utf8))
        }
    }
}
