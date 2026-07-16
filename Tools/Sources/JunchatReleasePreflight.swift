import Foundation

enum JunchatReleasePreflight {
    struct Preparation {
        let currentVersion: JunchatReleaseVersion
        let nextVersion: JunchatReleaseVersion
    }

    enum PreflightError: LocalizedError {
        case unexpectedGeneratedXcodeProject

        var errorDescription: String? {
            "XcodeGen did not produce the exact release metadata update expected from project.yml."
        }
    }

    static func prepareBeforeRemoteMutation<RemoteResult>(projectYAML: String,
                                                          changelog: String,
                                                          xcodeProject: String,
                                                          releaseDate: String,
                                                          generateXcodeProject: (String) async throws -> String,
                                                          remoteMutation: (Preparation) async throws -> RemoteResult) async throws -> (Preparation, RemoteResult) {
        let currentVersion = try JunchatReleaseVersion.parse(projectYAML)
        let nextVersion = try currentVersion.nextPatch()
        _ = try JunchatReleaseNotes.updatedChangelog(existingContent: changelog,
                                                     version: currentVersion.name,
                                                     generatedNotes: "- Release preparation feasibility check",
                                                     releaseDate: releaseDate)
        let updatedProjectYAML = try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                                              name: nextVersion.name,
                                                                              build: nextVersion.build)
        let expectedXcodeProject = try JunchatReleaseXcodeProject.updatedContent(xcodeProject,
                                                                                 from: currentVersion,
                                                                                 to: nextVersion)
        let generatedXcodeProject = try await generateXcodeProject(updatedProjectYAML)
        guard generatedXcodeProject == expectedXcodeProject else {
            throw PreflightError.unexpectedGeneratedXcodeProject
        }

        let preparation = Preparation(currentVersion: currentVersion, nextVersion: nextVersion)
        let remoteResult = try await remoteMutation(preparation)
        return (preparation, remoteResult)
    }

    static func validateCurrentRepository() async throws {
        let projectDirectory = URL.projectDirectory
        let xcodeGenGate = projectDirectory.appending(path: "ci_scripts/verify_xcodegen_is_current.sh")
        try await CI.run(.path("/bin/bash"), [xcodeGenGate.path])
        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())

        let projectYAML = try String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.projectYAMLPath),
                                     encoding: .utf8)
        let changelog = try String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.changelogPath),
                                   encoding: .utf8)
        let xcodeProject = try String(contentsOf: projectDirectory.appending(path: JunchatReleasePreparation.xcodeProjectPath),
                                      encoding: .utf8)
        let releaseDate = Date().formatted(.iso8601.year().month().day())

        _ = try await prepareBeforeRemoteMutation(projectYAML: projectYAML,
                                                  changelog: changelog,
                                                  xcodeProject: xcodeProject,
                                                  releaseDate: releaseDate,
                                                  generateXcodeProject: generateXcodeProject) { _ in () }
        try await JunchatReleasePreparation.validateCleanRepositoryStatus(CI.gitRepositoryStatus())
    }

    static func generateXcodeProject(updatedProjectYAML: String) async throws -> String {
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
}
