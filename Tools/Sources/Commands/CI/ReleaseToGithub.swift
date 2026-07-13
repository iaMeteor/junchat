import ArgumentParser
import Foundation

struct ReleaseToGitHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release-to-github",
                                                    abstract: "Creates or reuses a GitHub draft release and updates JUNCHAT_CHANGES.md with generated release notes.")

    enum ReleaseError: LocalizedError {
        case missingGitHubToken

        var errorDescription: String? {
            switch self {
            case .missingGitHubToken:
                return "The GITHUB_TOKEN environment variable is not set."
            }
        }
    }

    func run() async throws {
        let currentVersion = try CI.readReleaseVersion()
        let repository = try await CI.gitRepository()
        let releaseCommit = try await CI.gitCurrentCommit()
        logger.info("Ensuring GitHub draft release for version \(currentVersion.name)…")

        let releaseBody = try await createOrReuseGitHubDraft(version: currentVersion.name,
                                                             releaseCommit: releaseCommit,
                                                             repository: repository)

        try updateChangelog(version: currentVersion.name, generatedNotes: releaseBody)

        let changesFilePath = URL.projectDirectory.appendingPathComponent("JUNCHAT_CHANGES.md").path
        try await CI.run(.name("git"), ["add", changesFilePath])

        logger.info("Successfully prepared GitHub draft release \(currentVersion.name) and updated JUNCHAT_CHANGES.md.")
        
        let targetFilePath = "project.yml"
        let xcodeProjPath = "ElementX.xcodeproj"
        let nextVersion = try currentVersion.nextPatch()
        try JunchatReleaseVersion.updateProjectFile(at: URL.projectDirectory.appending(path: targetFilePath),
                                                    name: nextVersion.name,
                                                    build: nextVersion.build,
                                                    allowExactNoOp: false)
        logger.info("Version updated from \(currentVersion.name) (\(currentVersion.build)) to \(nextVersion.name) (\(nextVersion.build))")

        try await CI.run(.name("xcodegen"))

        try await CI.gitConfigureGlobals()

        try await CI.run(.name("git"), ["add", targetFilePath, xcodeProjPath])
        try await CI.run(.name("git"), ["commit", "-m", "Prepare next release"])
        
        try await CI.gitPush()
        logger.info("GitHub release \(currentVersion.name) remains a draft pending explicit publication approval.")
    }

    // MARK: - Private

    private func createOrReuseGitHubDraft(version: String,
                                          releaseCommit: String,
                                          repository: GitHubRepository) async throws -> String {
        guard let apiToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !apiToken.isEmpty
        else {
            throw ReleaseError.missingGitHubToken
        }

        return try await GitHubReleaseAPI().createOrReuseDraft(version: version,
                                                               targetCommit: releaseCommit,
                                                               repository: repository,
                                                               token: apiToken)
    }

    private func updateChangelog(version: String, generatedNotes: String) throws {
        let changesURL = URL.projectDirectory.appending(component: "JUNCHAT_CHANGES.md")

        let releaseDate = Date().formatted(.iso8601.year().month().day())
        let existingContent = try String(contentsOf: changesURL, encoding: .utf8)
        let newContent = try JunchatReleaseNotes.updatedChangelog(existingContent: existingContent,
                                                                  version: version,
                                                                  generatedNotes: generatedNotes,
                                                                  releaseDate: releaseDate)

        try newContent.write(to: changesURL, atomically: true, encoding: .utf8)
        logger.info("Updated JUNCHAT_CHANGES.md with release notes.")
    }
}
