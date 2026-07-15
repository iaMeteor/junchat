import ArgumentParser
import Foundation

struct ReleaseToGitHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release-to-github",
                                                    abstract: "Creates or reuses a GitHub draft release and updates JUNCHAT_CHANGES.md with generated release notes.")

    enum ReleaseError: LocalizedError {
        case missingGitHubToken
        case invalidPreparationCommit

        var errorDescription: String? {
            switch self {
            case .missingGitHubToken:
                return "The GITHUB_TOKEN environment variable is not set."
            case .invalidPreparationCommit:
                return "The generated release preparation commit does not match its validated marker."
            }
        }
    }

    func run() async throws {
        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())

        let currentContents = try localReleaseContents()
        let currentVersion = try JunchatReleaseVersion.parse(currentContents.projectYAML)
        let currentCommitMessage = try await CI.gitCurrentCommitMessage()
        let repository = try await CI.gitRepository()
        let branch = try await CI.gitCurrentBranchName()
        let apiToken = try githubToken()
        let releaseAPI = GitHubReleaseAPI()
        if let preparation = try JunchatReleasePreparation.parseIfPresent(currentCommitMessage) {
            try await preparation.validateResume(parentCommits: CI.gitCurrentCommitParents(),
                                                 currentVersion: currentVersion,
                                                 changedPaths: CI.gitCurrentCommitChangedPaths())
            let archivedContents = try await archivedReleaseContents(commit: preparation.releaseCommit)
            try preparation.validatePreparedMetadata(archivedProjectYAML: archivedContents.projectYAML,
                                                     preparedProjectYAML: currentContents.projectYAML,
                                                     archivedXcodeProject: archivedContents.xcodeProject,
                                                     preparedXcodeProject: currentContents.xcodeProject)
            let releaseBody = try await createOrReuseGitHubDraft(version: preparation.releaseVersion.name,
                                                                 releaseCommit: preparation.releaseCommit,
                                                                 repository: repository,
                                                                 releaseAPI: releaseAPI,
                                                                 apiToken: apiToken,
                                                                 allowCreation: false)
            try preparation.validatePreparedContents(archivedProjectYAML: archivedContents.projectYAML,
                                                     preparedProjectYAML: currentContents.projectYAML,
                                                     archivedChangelog: archivedContents.changelog,
                                                     preparedChangelog: currentContents.changelog,
                                                     archivedXcodeProject: archivedContents.xcodeProject,
                                                     preparedXcodeProject: currentContents.xcodeProject,
                                                     generatedNotes: releaseBody)

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
        let (localPreparation, releaseBody) = try await JunchatReleasePreflight.prepareBeforeRemoteMutation(projectYAML: currentContents.projectYAML,
                                                                                                            changelog: currentContents.changelog,
                                                                                                            xcodeProject: currentContents.xcodeProject,
                                                                                                            releaseDate: releaseDate,
                                                                                                            generateXcodeProject: generateXcodeProjectForPreflight,
                                                                                                            remoteMutation: { localPreparation in
                                                                                                                try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
                                                                                                                logger.info("Ensuring GitHub draft release for version \(localPreparation.currentVersion.name)…")
                                                                                                                let remoteCommit = try await releaseAPI.remoteBranchCommit(branch: branch,
                                                                                                                                                                           repository: repository,
                                                                                                                                                                           token: apiToken)
                                                                                                                return try await createOrReuseGitHubDraft(version: localPreparation.currentVersion.name,
                                                                                                                                                          releaseCommit: releaseCommit,
                                                                                                                                                          repository: repository,
                                                                                                                                                          releaseAPI: releaseAPI,
                                                                                                                                                          apiToken: apiToken,
                                                                                                                                                          allowCreation: remoteCommit == releaseCommit)
                                                                                                            })
        let preparation = try JunchatReleasePreparation(releaseVersion: localPreparation.currentVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: releaseDate)

        if try await releaseAPI.isPreparationAlreadyPushed(branch: branch,
                                                           releaseVersion: localPreparation.currentVersion,
                                                           releaseCommit: releaseCommit,
                                                           generatedNotes: releaseBody,
                                                           repository: repository,
                                                           token: apiToken) {
            logger.info("The exact release preparation for \(localPreparation.currentVersion.name) was already pushed by an earlier build of this commit.")
            return
        }

        try updateChangelog(version: localPreparation.currentVersion.name,
                            generatedNotes: releaseBody,
                            releaseDate: releaseDate)

        guard try JunchatReleaseVersion.updateProjectFile(at: URL.projectDirectory.appending(path: JunchatReleasePreparation.projectYAMLPath),
                                                          name: localPreparation.nextVersion.name,
                                                          build: localPreparation.nextVersion.build,
                                                          allowExactNoOp: false) else {
            throw ReleaseError.invalidPreparationCommit
        }

        try await CI.run(.name("xcodegen"))

        let preparedContents = try localReleaseContents()
        try preparation.validatePreparedContents(archivedProjectYAML: currentContents.projectYAML,
                                                 preparedProjectYAML: preparedContents.projectYAML,
                                                 archivedChangelog: currentContents.changelog,
                                                 preparedChangelog: preparedContents.changelog,
                                                 archivedXcodeProject: currentContents.xcodeProject,
                                                 preparedXcodeProject: preparedContents.xcodeProject,
                                                 generatedNotes: releaseBody)
        logger.info("Successfully prepared GitHub draft release \(localPreparation.currentVersion.name) and updated JUNCHAT_CHANGES.md.")
        logger.info("Version updated from \(localPreparation.currentVersion.name) (\(localPreparation.currentVersion.build)) to \(localPreparation.nextVersion.name) (\(localPreparation.nextVersion.build))")

        try await CI.gitConfigureGlobals()

        try await CI.run(.name("git"), [
            "add",
            JunchatReleasePreparation.changelogPath,
            JunchatReleasePreparation.projectYAMLPath,
            JunchatReleasePreparation.xcodeProjectPath
        ])
        try await CI.run(.name("git"), ["commit", "-m", preparation.commitMessage])

        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
        guard let committedPreparation = try await JunchatReleasePreparation.parseIfPresent(CI.gitCurrentCommitMessage()),
              committedPreparation == preparation else {
            throw ReleaseError.invalidPreparationCommit
        }
        try await committedPreparation.validateResume(parentCommits: CI.gitCurrentCommitParents(),
                                                      currentVersion: localPreparation.nextVersion,
                                                      changedPaths: CI.gitCurrentCommitChangedPaths())
        let committedContents = try localReleaseContents()
        try committedPreparation.validatePreparedContents(archivedProjectYAML: currentContents.projectYAML,
                                                          preparedProjectYAML: committedContents.projectYAML,
                                                          archivedChangelog: currentContents.changelog,
                                                          preparedChangelog: committedContents.changelog,
                                                          archivedXcodeProject: currentContents.xcodeProject,
                                                          preparedXcodeProject: committedContents.xcodeProject,
                                                          generatedNotes: releaseBody)

        try await pushOrAcceptRemotePreparation(branch: branch,
                                                preparation: preparation,
                                                generatedNotes: releaseBody,
                                                repository: repository,
                                                releaseAPI: releaseAPI,
                                                apiToken: apiToken)
        logger.info("GitHub release \(localPreparation.currentVersion.name) remains a draft pending explicit publication approval.")
    }

    // MARK: - Private

    private struct ReleaseContents {
        let projectYAML: String
        let changelog: String
        let xcodeProject: String
    }

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

    private func localReleaseContents() throws -> ReleaseContents {
        let projectDirectory = URL.projectDirectory
        return try ReleaseContents(projectYAML: String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.projectYAMLPath),
                                                       encoding: .utf8),
                                   changelog: String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.changelogPath),
                                                     encoding: .utf8),
                                   xcodeProject: String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.xcodeProjectPath),
                                                        encoding: .utf8))
    }

    private func archivedReleaseContents(commit: String) async throws -> ReleaseContents {
        let projectYAML = try await CI.gitFileContents(path: JunchatReleasePreparation.projectYAMLPath, commit: commit)
        let changelog = try await CI.gitFileContents(path: JunchatReleasePreparation.changelogPath, commit: commit)
        let xcodeProject = try await CI.gitFileContents(path: JunchatReleasePreparation.xcodeProjectPath, commit: commit)
        return ReleaseContents(projectYAML: projectYAML,
                               changelog: changelog,
                               xcodeProject: xcodeProject)
    }

    private func generateXcodeProjectForPreflight(updatedProjectYAML: String) async throws -> String {
        let projectDirectory = URL.projectDirectory
        let projectURL = projectDirectory.appending(path: JunchatReleasePreparation.projectYAMLPath)
        let xcodeProjectURL = projectDirectory.appending(path: JunchatReleasePreparation.xcodeProjectPath)
        let projectSnapshot = try JunchatReleaseFile.Snapshot(url: projectURL)
        let xcodeProjectSnapshot = try JunchatReleaseFile.Snapshot(url: xcodeProjectURL)

        let generationResult: Result<String, Swift.Error>
        do {
            try JunchatReleaseFile.write(updatedProjectYAML, to: projectURL)
            try await CI.run(.name("xcodegen"))
            let generatedXcodeProject = try String(contentsOf: xcodeProjectURL, encoding: .utf8)
            generationResult = .success(generatedXcodeProject)
        } catch {
            generationResult = .failure(error)
        }

        var restorationError: Swift.Error?
        do {
            try xcodeProjectSnapshot.restore()
        } catch {
            restorationError = error
        }
        do {
            try projectSnapshot.restore()
        } catch {
            restorationError = restorationError ?? error
        }
        if let restorationError {
            throw restorationError
        }
        return try generationResult.get()
    }

    private func updateChangelog(version: String,
                                 generatedNotes: String,
                                 releaseDate: String) throws {
        let changesURL = URL.projectDirectory.appending(component: "JUNCHAT_CHANGES.md")
        try JunchatReleaseNotes.updateChangelogFile(at: changesURL,
                                                    version: version,
                                                    generatedNotes: generatedNotes,
                                                    releaseDate: releaseDate)
        logger.info("Updated JUNCHAT_CHANGES.md with release notes.")
    }
}
