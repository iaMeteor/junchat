import ArgumentParser
import Foundation

struct PublishedJunchatReleaseTags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "published-junchat-release-tags",
                                                    abstract: "Prints published, non-prerelease JunChat release tags from GitHub.")

    @Option(help: "The repository remote URL used to identify the GitHub repository.")
    var repositoryURL: String

    func run() async throws {
        guard let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty else {
            throw ValidationError("GITHUB_TOKEN environment variable is not set.")
        }

        let repository = try GitHubRepository(remoteURL: repositoryURL)
        let tags = try await GitHubReleaseAPI().publishedReleaseTags(repository: repository,
                                                                     token: token)
        for tag in tags {
            print(tag)
        }
    }
}
