import ArgumentParser
import Foundation

struct ReleaseToGitHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release-to-github",
                                                    abstract: "Creates a GitHub release and updates JUNCHAT_CHANGES.md with generated release notes.")

    enum ReleaseError: LocalizedError {
        case missingGitHubToken
        case failedToCreateRelease(String)
        case failedToParseResponse

        var errorDescription: String? {
            switch self {
            case .missingGitHubToken:
                return "The GITHUB_TOKEN environment variable is not set."
            case .failedToCreateRelease(let message):
                return "Failed to create GitHub release: \(message)"
            case .failedToParseResponse:
                return "Failed to parse the GitHub API response."
            }
        }
    }

    func run() async throws {
        let currentVersion = try CI.readReleaseVersion()
        let repository = try await CI.gitRepository()
        let releaseCommit = try await CI.gitCurrentCommit()
        logger.info("Creating GitHub release for version \(currentVersion.name)…")

        let releaseBody = try await createGitHubRelease(version: currentVersion.name,
                                                        releaseCommit: releaseCommit,
                                                        repository: repository)

        try updateChangelog(version: currentVersion.name, generatedNotes: releaseBody)

        let changesFilePath = URL.projectDirectory.appendingPathComponent("JUNCHAT_CHANGES.md").path
        try await CI.run(.name("git"), ["add", changesFilePath])

        logger.info("Successfully created GitHub release \(currentVersion.name) and updated JUNCHAT_CHANGES.md.")
        
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
    }

    // MARK: - Private

    private func createGitHubRelease(version: String,
                                     releaseCommit: String,
                                     repository: GitHubRepository) async throws -> String {
        guard let apiToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !apiToken.isEmpty
        else {
            throw ReleaseError.missingGitHubToken
        }
        
        var request = URLRequest(url: repository.releasesAPIURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["tag_name": "release/\(version)",
                                   "name": version,
                                   "target_commitish": releaseCommit,
                                   "generate_release_notes": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReleaseError.failedToParseResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ReleaseError.failedToCreateRelease("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releaseBody = json["body"] as? String else {
            throw ReleaseError.failedToParseResponse
        }
        
        return releaseBody
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
