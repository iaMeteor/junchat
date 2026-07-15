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
}
