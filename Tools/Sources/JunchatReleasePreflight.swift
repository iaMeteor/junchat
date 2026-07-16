import Foundation

enum JunchatReleasePreflight {
    struct ReleaseArtifacts {
        let archiveURL: URL
        let signedAppURL: URL
        let dSYMsURL: URL
    }

    struct Preparation {
        let currentVersion: JunchatReleaseVersion
        let nextVersion: JunchatReleaseVersion
    }

    enum PreflightError: LocalizedError {
        case invalidArtifactPath(variable: String)
        case invalidArtifactStructure(path: String)
        case invalidPropertyList(path: String)
        case unexpectedSignedAppPath
        case unexpectedGeneratedXcodeProject

        var errorDescription: String? {
            switch self {
            case .invalidArtifactPath(let variable):
                "Release preflight requires \(variable) to be a canonical absolute path without symlinks."
            case .invalidArtifactStructure(let path):
                "Release preflight requires a valid archive artifact at \(path)."
            case .invalidPropertyList(let path):
                "Release preflight requires a valid property list at \(path)."
            case .unexpectedSignedAppPath:
                "CI_APP_STORE_SIGNED_APP_PATH must identify the signed Junchat.app inside CI_ARCHIVE_PATH."
            case .unexpectedGeneratedXcodeProject:
                "XcodeGen did not produce the exact release metadata update expected from project.yml."
            }
        }
    }

    static func performAfterValidatingReleaseArtifacts<Result>(environment: [String: String],
                                                               fileManager: FileManager = .default,
                                                               operation: (ReleaseArtifacts) async throws -> Result) async throws -> Result {
        let artifacts = try validateReleaseArtifacts(environment: environment, fileManager: fileManager)
        return try await operation(artifacts)
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

    static func validateCurrentRepository(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        try await performAfterValidatingReleaseArtifacts(environment: environment) { _ in
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

    private static func validateReleaseArtifacts(environment: [String: String],
                                                 fileManager: FileManager) throws -> ReleaseArtifacts {
        let archiveURL = try canonicalArtifactURL(variable: "CI_ARCHIVE_PATH",
                                                  environment: environment,
                                                  expectedExtension: "xcarchive")
        try requireDirectory(archiveURL, fileManager: fileManager)

        let archiveInfoURL = archiveURL.appending(path: "Info.plist")
        let appURL = archiveURL.appending(path: "Products/Applications/Junchat.app")
        let appInfoURL = appURL.appending(path: "Info.plist")
        let appExecutableURL = appURL.appending(path: "Junchat")
        let dSYMsURL = archiveURL.appending(path: "dSYMs")
        let dSYMURL = dSYMsURL.appending(path: "Junchat.app.dSYM")
        let dSYMInfoURL = dSYMURL.appending(path: "Contents/Info.plist")
        let dwarfURL = dSYMURL.appending(path: "Contents/Resources/DWARF/Junchat")

        try requireDirectory(appURL, fileManager: fileManager)
        try requireDirectory(dSYMsURL, fileManager: fileManager)
        try requireDirectory(dSYMURL, fileManager: fileManager)
        try requireRegularFile(appExecutableURL, fileManager: fileManager)
        try requireRegularFile(dwarfURL, fileManager: fileManager)

        let archiveInfo = try propertyList(at: archiveInfoURL, fileManager: fileManager)
        guard archiveInfo["ArchiveVersion"] as? Int == 2,
              archiveInfo["Name"] as? String == "Junchat",
              let applicationProperties = archiveInfo["ApplicationProperties"] as? [String: Any],
              applicationProperties["ApplicationPath"] as? String == "Applications/Junchat.app" else {
            throw PreflightError.invalidPropertyList(path: archiveInfoURL.path)
        }

        let appInfo = try propertyList(at: appInfoURL, fileManager: fileManager)
        guard appInfo["CFBundleExecutable"] as? String == "Junchat",
              appInfo["CFBundleIdentifier"] as? String == "com.heyujk.junchat",
              appInfo["CFBundlePackageType"] as? String == "APPL" else {
            throw PreflightError.invalidPropertyList(path: appInfoURL.path)
        }

        let dSYMInfo = try propertyList(at: dSYMInfoURL, fileManager: fileManager)
        guard dSYMInfo["CFBundlePackageType"] as? String == "dSYM" else {
            throw PreflightError.invalidPropertyList(path: dSYMInfoURL.path)
        }

        let signedAppURL = try canonicalArtifactURL(variable: "CI_APP_STORE_SIGNED_APP_PATH",
                                                    environment: environment,
                                                    expectedExtension: "app")
        guard signedAppURL == appURL else {
            throw PreflightError.unexpectedSignedAppPath
        }

        return ReleaseArtifacts(archiveURL: archiveURL,
                                signedAppURL: signedAppURL,
                                dSYMsURL: dSYMsURL)
    }

    private static func canonicalArtifactURL(variable: String,
                                             environment: [String: String],
                                             expectedExtension: String) throws -> URL {
        guard let path = environment[variable],
              !path.isEmpty,
              NSString(string: path).isAbsolutePath else {
            throw PreflightError.invalidArtifactPath(variable: variable)
        }
        let url = URL(filePath: path)
        guard path == url.path,
              path == url.standardizedFileURL.path,
              path == url.resolvingSymlinksInPath().path,
              url.pathExtension == expectedExtension else {
            throw PreflightError.invalidArtifactPath(variable: variable)
        }
        return url
    }

    private static func requireDirectory(_ url: URL, fileManager: FileManager) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw PreflightError.invalidArtifactStructure(path: url.path)
        }
    }

    private static func requireRegularFile(_ url: URL, fileManager: FileManager) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber,
              size.intValue > 0 else {
            throw PreflightError.invalidArtifactStructure(path: url.path)
        }
    }

    private static func propertyList(at url: URL, fileManager: FileManager) throws -> [String: Any] {
        try requireRegularFile(url, fileManager: fileManager)
        do {
            let data = try Data(contentsOf: url)
            guard let propertyList = try PropertyListSerialization.propertyList(from: data,
                                                                                options: [],
                                                                                format: nil) as? [String: Any] else {
                throw PreflightError.invalidPropertyList(path: url.path)
            }
            return propertyList
        } catch let error as PreflightError {
            throw error
        } catch {
            throw PreflightError.invalidPropertyList(path: url.path)
        }
    }
}
