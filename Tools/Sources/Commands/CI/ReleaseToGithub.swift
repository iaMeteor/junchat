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

    @Option(help: "The private validated release artifact binding path.")
    var artifactBindingPath: String

    @Option(help: "The expected SHA-256 digest of the release artifact binding.")
    var expectedArtifactBindingDigest: String

    func run() async throws {
        try await XcodeCloudReleaseEnvironment.perform(environment: ProcessInfo.processInfo.environment) {
            try await runInValidatedEnvironment()
        }
    }

    private func runInValidatedEnvironment() async throws {
        try revalidateReleaseArtifacts(validateProjectMetadata: true)
        try await JunchatReleasePreflight.validateCurrentRepositoryFiles()
        try revalidateReleaseArtifacts(validateProjectMetadata: true)
        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())

        let currentCommit = try await CI.gitCurrentCommit()
        let currentContents = try await archivedReleaseContents(commit: currentCommit)
        let currentVersion = try JunchatReleaseVersion.parse(currentContents.projectYAML)
        let currentCommitMessage = try await CI.gitCommitMessage(commit: currentCommit)
        let identity = try await CI.gitReleaseIdentity()
        let repository = identity.repository
        let branch = identity.branch
        let apiToken = try githubToken()
        let releaseAPI = GitHubReleaseAPI()
        if let preparation = try JunchatReleasePreparation.parseIfPresent(currentCommitMessage) {
            try await resumePreparation(preparation,
                                        preparationCommit: currentCommit,
                                        currentContents: currentContents,
                                        currentVersion: currentVersion,
                                        identity: identity,
                                        apiToken: apiToken,
                                        releaseAPI: releaseAPI)
            return
        }

        let releaseCommit = currentCommit
        let releaseDate = Date().formatted(.iso8601.year().month().day())
        let (localPreparation, releaseDraft) = try await JunchatReleasePreflight.prepareBeforeRemoteMutation(projectYAML: currentContents.projectYAML,
                                                                                                             changelog: currentContents.changelog,
                                                                                                             xcodeProject: currentContents.xcodeProject,
                                                                                                             releaseDate: releaseDate,
                                                                                                             generateXcodeProject: JunchatReleasePreflight.generateXcodeProject) { localPreparation in
            try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
            logger.info("Ensuring GitHub draft release for version \(localPreparation.currentVersion.name)…")
            return try await createOrReuseGitHubDraft(version: localPreparation.currentVersion.name,
                                                      releaseCommit: releaseCommit,
                                                      branch: branch,
                                                      repository: repository,
                                                      releaseAPI: releaseAPI,
                                                      apiToken: apiToken,
                                                      authorizeCreation: true)
        }
        let preparation = try JunchatReleasePreparation(releaseVersion: localPreparation.currentVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: releaseDate)

        if try await releaseAPI.isPreparationAlreadyPushed(branch: branch,
                                                           releaseVersion: localPreparation.currentVersion,
                                                           releaseCommit: releaseCommit,
                                                           generatedNotes: releaseDraft.body,
                                                           releaseDraft: releaseDraft,
                                                           repository: repository,
                                                           token: apiToken) {
            logger.info("The exact release preparation for \(localPreparation.currentVersion.name) was already pushed by an earlier build of this commit.")
            try await validateCapturedCommitStillCheckedOut(releaseCommit)
            try revalidateReleaseArtifacts()
            return
        }

        try updateChangelog(version: localPreparation.currentVersion.name,
                            generatedNotes: releaseDraft.body,
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
                                                 generatedNotes: releaseDraft.body)
        logger.info("Successfully prepared GitHub draft release \(localPreparation.currentVersion.name) and updated JUNCHAT_CHANGES.md.")
        logger.info("Version updated from \(localPreparation.currentVersion.name) (\(localPreparation.currentVersion.build)) to \(localPreparation.nextVersion.name) (\(localPreparation.nextVersion.build))")

        try await CI.run(.name("git"), [
            "add",
            JunchatReleasePreparation.changelogPath,
            JunchatReleasePreparation.projectYAMLPath,
            JunchatReleasePreparation.xcodeProjectPath
        ])
        try await CI.gitCommit(message: preparation.commitMessage)

        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
        let preparationCommit = try await CI.gitCurrentCommit()
        guard let committedPreparation = try await JunchatReleasePreparation.parseIfPresent(CI.gitCommitMessage(commit: preparationCommit)),
              committedPreparation == preparation else {
            throw ReleaseError.invalidPreparationCommit
        }
        try await committedPreparation.validateResume(parentCommits: CI.gitCommitParents(commit: preparationCommit),
                                                      currentVersion: localPreparation.nextVersion,
                                                      changedFiles: CI.gitCommitChangedFiles(commit: preparationCommit))
        let committedContents = try await archivedReleaseContents(commit: preparationCommit)
        try committedPreparation.validatePreparedContents(archivedProjectYAML: currentContents.projectYAML,
                                                          preparedProjectYAML: committedContents.projectYAML,
                                                          archivedChangelog: currentContents.changelog,
                                                          preparedChangelog: committedContents.changelog,
                                                          archivedXcodeProject: currentContents.xcodeProject,
                                                          preparedXcodeProject: committedContents.xcodeProject,
                                                          generatedNotes: releaseDraft.body)

        try await pushOrAcceptRemotePreparation(preparation: preparation,
                                                preparationCommit: preparationCommit,
                                                releaseDraft: releaseDraft,
                                                generatedNotes: releaseDraft.body,
                                                identity: identity,
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

    private func resumePreparation(_ preparation: JunchatReleasePreparation,
                                   preparationCommit: String,
                                   currentContents: ReleaseContents,
                                   currentVersion: JunchatReleaseVersion,
                                   identity: CI.GitReleaseIdentity,
                                   apiToken: String,
                                   releaseAPI: GitHubReleaseAPI) async throws {
        let repository = identity.repository
        let branch = identity.branch
        try await preparation.validateResume(parentCommits: CI.gitCommitParents(commit: preparationCommit),
                                             currentVersion: currentVersion,
                                             changedFiles: CI.gitCommitChangedFiles(commit: preparationCommit))
        let archivedContents = try await archivedReleaseContents(commit: preparation.releaseCommit)
        try preparation.validatePreparedMetadata(archivedProjectYAML: archivedContents.projectYAML,
                                                 preparedProjectYAML: currentContents.projectYAML,
                                                 archivedXcodeProject: archivedContents.xcodeProject,
                                                 preparedXcodeProject: currentContents.xcodeProject)
        let releaseDraft = try await createOrReuseGitHubDraft(version: preparation.releaseVersion.name,
                                                              releaseCommit: preparation.releaseCommit,
                                                              branch: branch,
                                                              repository: repository,
                                                              releaseAPI: releaseAPI,
                                                              apiToken: apiToken,
                                                              authorizeCreation: false)
        let releaseBody = releaseDraft.body
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
                                                           releaseDraft: releaseDraft,
                                                           repository: repository,
                                                           token: apiToken) {
            logger.info("The exact release preparation for \(preparation.releaseVersion.name) is already present on the remote branch.")
            try await validateCapturedCommitStillCheckedOut(preparationCommit)
            try revalidateReleaseArtifacts()
            return
        }
        try await pushOrAcceptRemotePreparation(preparation: preparation,
                                                preparationCommit: preparationCommit,
                                                releaseDraft: releaseDraft,
                                                generatedNotes: releaseBody,
                                                identity: identity,
                                                releaseAPI: releaseAPI,
                                                apiToken: apiToken)
        logger.info("Resumed release preparation for \(preparation.releaseVersion.name) without creating a new release.")
    }

    private func createOrReuseGitHubDraft(version: String,
                                          releaseCommit: String,
                                          branch: String,
                                          repository: GitHubRepository,
                                          releaseAPI: GitHubReleaseAPI,
                                          apiToken: String,
                                          authorizeCreation: Bool) async throws -> GitHubDraftRelease {
        let authorization = authorizeCreation
            ? GitHubDraftCreationAuthorization(branch: branch, expectedCommit: releaseCommit)
            : nil
        return try await releaseAPI.createOrReuseDraftSnapshot(version: version,
                                                               targetCommit: releaseCommit,
                                                               repository: repository,
                                                               token: apiToken,
                                                               creationAuthorization: authorization) {
            try revalidateReleaseArtifacts()
        }
    }

    private func pushOrAcceptRemotePreparation(preparation: JunchatReleasePreparation,
                                               preparationCommit: String,
                                               releaseDraft: GitHubDraftRelease,
                                               generatedNotes: String,
                                               identity: CI.GitReleaseIdentity,
                                               releaseAPI: GitHubReleaseAPI,
                                               apiToken: String) async throws {
        do {
            try await releaseAPI.pushAfterRevalidatingDraft(releaseDraft,
                                                            repository: identity.repository,
                                                            token: apiToken) {
                try await validateCapturedCommitStillCheckedOut(preparationCommit)
                try revalidateReleaseArtifacts()
                try await CI.gitPush(identity: identity,
                                     expectedLocalCommit: preparationCommit,
                                     expectedRemoteCommit: preparation.releaseCommit)
            }
        } catch GitHubReleaseAPI.PushAttemptError.pushFailed(let pushError) {
            guard pushError is CI.GitPushError else {
                throw pushError
            }
            guard try await releaseAPI.isPreparationAlreadyPushed(branch: identity.branch,
                                                                  releaseVersion: preparation.releaseVersion,
                                                                  releaseCommit: preparation.releaseCommit,
                                                                  generatedNotes: generatedNotes,
                                                                  releaseDraft: releaseDraft,
                                                                  repository: identity.repository,
                                                                  token: apiToken) else {
                throw pushError
            }
            logger.info("A concurrent build already pushed the exact release preparation commit.")
            try await validateCapturedCommitStillCheckedOut(preparationCommit)
            try revalidateReleaseArtifacts()
            return
        }
        guard try await releaseAPI.isPreparationAlreadyPushed(branch: identity.branch,
                                                              releaseVersion: preparation.releaseVersion,
                                                              releaseCommit: preparation.releaseCommit,
                                                              generatedNotes: generatedNotes,
                                                              releaseDraft: releaseDraft,
                                                              repository: identity.repository,
                                                              token: apiToken) else {
            throw GitHubReleaseAPI.APIError.incompatibleExistingPreparation
        }
        try await validateCapturedCommitStillCheckedOut(preparationCommit)
        try revalidateReleaseArtifacts()
    }

    private func validateCapturedCommitStillCheckedOut(_ expectedCommit: String) async throws {
        guard try await CI.gitCurrentCommit() == expectedCommit else {
            throw ReleaseError.invalidPreparationCommit
        }
    }

    @discardableResult
    private func revalidateReleaseArtifacts(validateProjectMetadata: Bool = false) throws -> JunchatReleasePreflight.ReleaseArtifacts {
        try JunchatReleaseArtifacts.revalidateBinding(atPath: artifactBindingPath,
                                                      expectedDigest: expectedArtifactBindingDigest,
                                                      validateProjectMetadata: validateProjectMetadata)
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
