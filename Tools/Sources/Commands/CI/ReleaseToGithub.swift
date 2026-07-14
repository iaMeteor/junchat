import ArgumentParser
import Foundation

struct ReleaseToGitHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release-to-github",
                                                    abstract: "Creates or reuses a GitHub draft release and updates JUNCHAT_CHANGES.md with generated release notes.")

    enum ReleaseError: LocalizedError {
        case missingGitHubToken
        case incompatiblePreparedChangelog
        case invalidPreparationCommit

        var errorDescription: String? {
            switch self {
            case .missingGitHubToken:
                return "The GITHUB_TOKEN environment variable is not set."
            case .incompatiblePreparedChangelog:
                return "The release preparation commit does not contain the exact generated changelog entry."
            case .invalidPreparationCommit:
                return "The generated release preparation commit does not match its validated marker."
            }
        }
    }

    func run() async throws {
        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())

        let currentVersion = try CI.readReleaseVersion()
        let currentCommitMessage = try await CI.gitCurrentCommitMessage()
        if let preparation = try JunchatReleasePreparation.parseIfPresent(currentCommitMessage) {
            try await preparation.validateResume(parentCommits: CI.gitCurrentCommitParents(),
                                                 currentVersion: currentVersion,
                                                 changedPaths: CI.gitCurrentCommitChangedPaths())
            let repository = try await CI.gitRepository()
            let releaseBody = try await createOrReuseGitHubDraft(version: preparation.releaseVersion.name,
                                                                 releaseCommit: preparation.releaseCommit,
                                                                 repository: repository)
            guard try preparedChangelogMatches(version: preparation.releaseVersion.name,
                                               generatedNotes: releaseBody,
                                               releaseDate: preparation.releaseDate) else {
                throw ReleaseError.incompatiblePreparedChangelog
            }

            try await CI.gitPush()
            logger.info("Resumed release preparation for \(preparation.releaseVersion.name) without creating a new release.")
            return
        }

        let repository = try await CI.gitRepository()
        let releaseCommit = try await CI.gitCurrentCommit()
        let releaseDate = Date().formatted(.iso8601.year().month().day())
        let preparation = try JunchatReleasePreparation(releaseVersion: currentVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: releaseDate)
        logger.info("Ensuring GitHub draft release for version \(currentVersion.name)…")

        let releaseBody = try await createOrReuseGitHubDraft(version: currentVersion.name,
                                                             releaseCommit: releaseCommit,
                                                             repository: repository)

        try updateChangelog(version: currentVersion.name,
                            generatedNotes: releaseBody,
                            releaseDate: releaseDate)

        let changesFilePath = URL.projectDirectory.appendingPathComponent("JUNCHAT_CHANGES.md").path
        try await CI.run(.name("git"), ["add", changesFilePath])

        logger.info("Successfully prepared GitHub draft release \(currentVersion.name) and updated JUNCHAT_CHANGES.md.")
        
        let targetFilePath = "project.yml"
        let xcodeProjectFilePath = "ElementX.xcodeproj/project.pbxproj"
        let nextVersion = try currentVersion.nextPatch()
        try JunchatReleaseVersion.updateProjectFile(at: URL.projectDirectory.appending(path: targetFilePath),
                                                    name: nextVersion.name,
                                                    build: nextVersion.build,
                                                    allowExactNoOp: false)
        logger.info("Version updated from \(currentVersion.name) (\(currentVersion.build)) to \(nextVersion.name) (\(nextVersion.build))")

        try await CI.run(.name("xcodegen"))

        try await CI.gitConfigureGlobals()

        try await CI.run(.name("git"), ["add", targetFilePath, xcodeProjectFilePath])
        try await CI.run(.name("git"), ["commit", "-m", preparation.commitMessage])

        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
        guard let committedPreparation = try await JunchatReleasePreparation.parseIfPresent(CI.gitCurrentCommitMessage()),
              committedPreparation == preparation else {
            throw ReleaseError.invalidPreparationCommit
        }
        try await committedPreparation.validateResume(parentCommits: CI.gitCurrentCommitParents(),
                                                      currentVersion: nextVersion,
                                                      changedPaths: CI.gitCurrentCommitChangedPaths())
        
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

    private func updateChangelog(version: String,
                                 generatedNotes: String,
                                 releaseDate: String) throws {
        let changesURL = URL.projectDirectory.appending(component: "JUNCHAT_CHANGES.md")
        let existingContent = try String(contentsOf: changesURL, encoding: .utf8)
        let newContent = try JunchatReleaseNotes.updatedChangelog(existingContent: existingContent,
                                                                  version: version,
                                                                  generatedNotes: generatedNotes,
                                                                  releaseDate: releaseDate)

        if newContent != existingContent {
            try newContent.write(to: changesURL, atomically: true, encoding: .utf8)
        }
        logger.info("Updated JUNCHAT_CHANGES.md with release notes.")
    }

    private func preparedChangelogMatches(version: String,
                                          generatedNotes: String,
                                          releaseDate: String) throws -> Bool {
        let changesURL = URL.projectDirectory.appending(component: "JUNCHAT_CHANGES.md")
        let existingContent = try String(contentsOf: changesURL, encoding: .utf8)
        let expectedContent = try JunchatReleaseNotes.updatedChangelog(existingContent: existingContent,
                                                                       version: version,
                                                                       generatedNotes: generatedNotes,
                                                                       releaseDate: releaseDate)
        return expectedContent == existingContent
    }
}
