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
        let repository = try await CI.gitRepository()
        let branch = try await CI.gitCurrentBranchName()
        let apiToken = try githubToken()
        let releaseAPI = GitHubReleaseAPI()
        if let preparation = try JunchatReleasePreparation.parseIfPresent(currentCommitMessage) {
            try await preparation.validateResume(parentCommits: CI.gitCurrentCommitParents(),
                                                 currentVersion: currentVersion,
                                                 changedPaths: CI.gitCurrentCommitChangedPaths())
            let remoteCommit = try await releaseAPI.remoteBranchCommit(branch: branch,
                                                                       repository: repository,
                                                                       token: apiToken)
            let releaseBody = try await createOrReuseGitHubDraft(version: preparation.releaseVersion.name,
                                                                 releaseCommit: preparation.releaseCommit,
                                                                 repository: repository,
                                                                 releaseAPI: releaseAPI,
                                                                 apiToken: apiToken,
                                                                 allowCreation: remoteCommit == preparation.releaseCommit)
            guard try preparedChangelogMatches(version: preparation.releaseVersion.name,
                                               generatedNotes: releaseBody,
                                               releaseDate: preparation.releaseDate) else {
                throw ReleaseError.incompatiblePreparedChangelog
            }

            if try await releaseAPI.isPreparationAlreadyPushed(branch: branch,
                                                               releaseVersion: preparation.releaseVersion,
                                                               releaseCommit: preparation.releaseCommit,
                                                               generatedNotes: releaseBody,
                                                               repository: repository,
                                                               token: apiToken) {
                logger.info("The exact release preparation for \(preparation.releaseVersion.name) is already present on the remote branch.")
                return
            }
            try await pushOrAcceptRemotePreparation(branch: branch,
                                                    preparation: preparation,
                                                    generatedNotes: releaseBody,
                                                    repository: repository,
                                                    releaseAPI: releaseAPI,
                                                    apiToken: apiToken)
            logger.info("Resumed release preparation for \(preparation.releaseVersion.name) without creating a new release.")
            return
        }

        let releaseCommit = try await CI.gitCurrentCommit()
        let releaseDate = Date().formatted(.iso8601.year().month().day())
        let preparation = try JunchatReleasePreparation(releaseVersion: currentVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: releaseDate)
        logger.info("Ensuring GitHub draft release for version \(currentVersion.name)…")

        let remoteCommit = try await releaseAPI.remoteBranchCommit(branch: branch,
                                                                   repository: repository,
                                                                   token: apiToken)
        let releaseBody = try await createOrReuseGitHubDraft(version: currentVersion.name,
                                                             releaseCommit: releaseCommit,
                                                             repository: repository,
                                                             releaseAPI: releaseAPI,
                                                             apiToken: apiToken,
                                                             allowCreation: remoteCommit == releaseCommit)

        if try await releaseAPI.isPreparationAlreadyPushed(branch: branch,
                                                           releaseVersion: currentVersion,
                                                           releaseCommit: releaseCommit,
                                                           generatedNotes: releaseBody,
                                                           repository: repository,
                                                           token: apiToken) {
            logger.info("The exact release preparation for \(currentVersion.name) was already pushed by an earlier build of this commit.")
            return
        }

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
        
        try await pushOrAcceptRemotePreparation(branch: branch,
                                                preparation: preparation,
                                                generatedNotes: releaseBody,
                                                repository: repository,
                                                releaseAPI: releaseAPI,
                                                apiToken: apiToken)
        logger.info("GitHub release \(currentVersion.name) remains a draft pending explicit publication approval.")
    }

    // MARK: - Private

    private func createOrReuseGitHubDraft(version: String,
                                          releaseCommit: String,
                                          repository: GitHubRepository,
                                          releaseAPI: GitHubReleaseAPI,
                                          apiToken: String,
                                          allowCreation: Bool) async throws -> String {
        try await releaseAPI.createOrReuseDraft(version: version,
                                                targetCommit: releaseCommit,
                                                repository: repository,
                                                token: apiToken,
                                                allowCreation: allowCreation)
    }

    private func pushOrAcceptRemotePreparation(branch: String,
                                               preparation: JunchatReleasePreparation,
                                               generatedNotes: String,
                                               repository: GitHubRepository,
                                               releaseAPI: GitHubReleaseAPI,
                                               apiToken: String) async throws {
        do {
            try await CI.gitPush()
        } catch {
            guard try await releaseAPI.isPreparationAlreadyPushed(branch: branch,
                                                                  releaseVersion: preparation.releaseVersion,
                                                                  releaseCommit: preparation.releaseCommit,
                                                                  generatedNotes: generatedNotes,
                                                                  repository: repository,
                                                                  token: apiToken) else {
                throw error
            }
            logger.info("A concurrent build already pushed the exact release preparation commit.")
        }
    }

    private func githubToken() throws -> String {
        guard let apiToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !apiToken.isEmpty else {
            throw ReleaseError.missingGitHubToken
        }
        return apiToken
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
