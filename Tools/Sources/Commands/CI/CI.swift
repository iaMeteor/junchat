import ArgumentParser
import Foundation
import Subprocess

// swiftlint:disable:next type_name
struct CI: ParsableCommand {
    struct GitReleaseIdentity: Equatable {
        let repository: GitHubRepository
        let originURL: String
        let branch: String
    }

    enum GitPushError: LocalizedError {
        case pushFailed

        var errorDescription: String? {
            "Authenticated git push failed."
        }
    }

    private struct GitPushSandbox {
        let rootURL: URL
        let gitDirectoryURL: URL
        let remoteName: String
        let remoteURL: String
        let environment: Environment
        let gitExecutable: Executable

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func arguments(_ command: [String]) -> [String] {
            ["--git-dir", gitDirectoryURL.path] + command
        }
    }

    static let configuration = CommandConfiguration(abstract: "CI workflow commands that can be run both locally and in CI environments.",
                                                    subcommands: [
                                                        PreviewTests.self,
                                                        AccessibilityTests.self,
                                                        UnitTests.self,
                                                        UITests.self,
                                                        IntegrationTests.self,
                                                        RunTests.self,
                                                        ConfigureNightly.self,
                                                        ConfigureProduction.self,
                                                        ValidateJunchatReleasePreflight.self,
                                                        CurrentReleaseVersion.self,
                                                        PublishedJunchatReleaseTags.self,
                                                        TagNightly.self,
                                                        UploadDSYMs.self,
                                                        ReleaseToGitHub.self
                                                    ])
    
    static let testOutputDirectory = "test_output"
    
    /// Reads the version metadata used by XcodeGen from `project.yml`.
    static func readReleaseVersion() throws -> JunchatReleaseVersion {
        let projectURL = URL.projectDirectory.appending(component: "project.yml")
        return try JunchatReleaseVersion.parse(String(contentsOf: projectURL, encoding: .utf8))
    }

    /// Reads the `MARKETING_VERSION` from `project.yml`.
    static func readMarketingVersion() throws -> String {
        try readReleaseVersion().name
    }
    
    // MARK: - Linting
    
    /// Runs SwiftFormat in lint mode against the current directory.
    static func lint() async throws {
        logger.info("\n🔍 Running SwiftFormat lint…\n")
        
        do {
            try await run(.name("swiftformat"), ["--lint", "."])
        } catch {
            logger.error("\n❌ SwiftFormat failed.\n")
            throw error
        }
        logger.info("\n✅ SwiftFormat passed.\n")
    }
    
    // MARK: - Test Results
    
    /// Collects coverage from an xcresult bundle using xcresultparser (cobertura format).
    /// Failures are non-fatal — the output file simply won't be created.
    static func collectCoverage(resultBundle: String, target: String = "ElementX", outputName: String) async {
        let projectPath = URL.projectDirectory.path
        let resultBundlePath = "\(testOutputDirectory)/\(resultBundle)"
        let outputPath = "\(testOutputDirectory)/\(outputName)"
        
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            logger.error("\n❌ Result bundle not found at \(resultBundlePath), skipping coverage collection.\n")
            return
        }
        
        do {
            try await run(.path("/bin/zsh"), ["-cu", "xcresultparser -q -o cobertura -t \(target) -p \(projectPath) \(resultBundlePath) > \(outputPath)"])
            logger.info("\n📊 Coverage report: \(outputPath)\n")
        } catch {
            logger.error("\n❌ Failed to collect coverage for \(resultBundle): \(error.localizedDescription)\n")
        }
    }
    
    /// Collects test results from an xcresult bundle using xcresultparser (junit format).
    /// Failures are non-fatal — the output file simply won't be created.
    static func collectTestResults(resultBundle: String, outputName: String) async {
        let projectPath = URL.projectDirectory.path
        let resultBundlePath = "\(testOutputDirectory)/\(resultBundle)"
        let outputPath = "\(testOutputDirectory)/\(outputName)"
        
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            logger.info(" Result bundle not found at \(resultBundlePath), skipping test result collection.")
            return
        }
        
        do {
            try await run(.path("/bin/zsh"), ["-cu", "xcresultparser -q -o junit -p \(projectPath) \(resultBundlePath) > \(outputPath)"])
            logger.info("📋 Test results: \(outputPath)")
        } catch {
            logger.error("\n❌ Failed to collect test results for \(resultBundle): \(error.localizedDescription)\n")
        }
    }
    
    /// Zips xcresult bundles in the test output directory for faster artifact uploads.
    static func zipResults(bundles: [String], outputName: String) async {
        let bundleArgs = bundles.joined(separator: " ")
        do {
            logger.info("\n📦 Zipping test results…")
            try await run(.path("/bin/zsh"), ["-cu", "cd \(testOutputDirectory) && zip -rq \(outputName) \(bundleArgs)"])
            logger.info("📦 Zipped: \(testOutputDirectory)/\(outputName)\n")
        } catch {
            logger.error("\n❌ Failed to zip results: \(error.localizedDescription)\n")
        }
    }
    
    // MARK: - Shell Interaction
    
    @discardableResult
    static func run<Output: OutputProtocol, Error: ErrorOutputProtocol>(_ executable: Executable,
                                                                        _ arguments: Arguments = [],
                                                                        environment: Environment = .inherit,
                                                                        output: Output = .standardOutput,
                                                                        error: Error = .standardError) async throws -> CollectedResult<Output, Error> {
        logger.info("Running \(executable), with arguments: \(arguments)")
        
        let result = try await Subprocess.run(executable,
                                              arguments: arguments,
                                              environment: environment,
                                              output: output,
                                              error: error)
        
        guard result.terminationStatus.isSuccess else {
            throw ExitCode.failure
        }
        
        return result
    }
    
    // MARK: - Git
    
    static func gitCommit(message: String) async throws {
        try await CI.run(.name("git"), Arguments(gitCommitArguments(message: message)))
    }

    static func gitCommitForTesting(message: String,
                                    repositoryPath: String,
                                    globalConfigurationPath: String) async throws {
        try await CI.run(.path("/usr/bin/git"),
                         Arguments(["-C", repositoryPath] + gitCommitArguments(message: message)),
                         environment: .inherit.updating(["GIT_CONFIG_GLOBAL": globalConfigurationPath]))
    }

    private static func gitCommitArguments(message: String) -> [String] {
        [
            "-c", "user.name=Element CI",
            "-c", "user.email=ci@element.io",
            "commit", "-m", message
        ]
    }

    static func gitRepository() async throws -> GitHubRepository {
        let rawURL = try await rawOriginURL(gitExecutable: .path("/usr/bin/git"),
                                            argumentPrefix: [],
                                            environment: isolatedGitEnvironment())
        return try GitHubRepository(remoteURL: rawURL)
    }

    static func gitReleaseIdentity() async throws -> GitReleaseIdentity {
        try await gitReleaseIdentity(gitExecutable: .path("/usr/bin/git"),
                                     argumentPrefix: [],
                                     environment: isolatedGitEnvironment(),
                                     ciBranch: ProcessInfo.processInfo.environment["CI_BRANCH"])
    }

    static func gitReleaseIdentityForTesting(repositoryPath: String,
                                             ciBranch: String?) async throws -> GitReleaseIdentity {
        try await gitReleaseIdentity(gitExecutable: .path("/usr/bin/git"),
                                     argumentPrefix: ["-C", repositoryPath],
                                     environment: isolatedGitEnvironment(),
                                     ciBranch: ciBranch)
    }

    static func gitCurrentCommit() async throws -> String {
        guard let commit = try await CI.run(.name("git"),
                                            ["rev-parse", "--verify", "HEAD"],
                                            output: .string(limit: 4096)).standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
            !commit.isEmpty else {
            throw ValidationError("Could not determine the release commit.")
        }
        return commit
    }

    static func gitRepositoryStatus() async throws -> String {
        try await CI.run(.name("git"),
                         ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                         output: .string(limit: 1_048_576)).standardOutput ?? ""
    }

    static func gitCurrentCommitMessage() async throws -> String {
        guard let message = try await CI.run(.name("git"),
                                             ["show", "-s", "--format=%B", "HEAD"],
                                             output: .string(limit: 65536)).standardOutput else {
            throw ValidationError("Could not determine the current commit message.")
        }
        return message
    }

    static func gitCurrentCommitParents() async throws -> [String] {
        guard let output = try await CI.run(.name("git"),
                                            ["show", "-s", "--format=%P", "HEAD"],
                                            output: .string(limit: 4096)).standardOutput else {
            throw ValidationError("Could not determine the current commit parents.")
        }
        return output.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func gitCurrentCommitChangedFiles() async throws -> [JunchatReleasePreparation.ChangedFile] {
        guard let output = try await CI.run(.name("git"),
                                            ["diff-tree", "--no-commit-id", "--raw", "--no-renames", "-r", "-z", "HEAD"],
                                            output: .string(limit: 1_048_576)).standardOutput else {
            throw ValidationError("Could not determine the current commit files and modes.")
        }
        return try gitChangedFiles(fromRawDiff: output)
    }

    static func gitChangedFiles(fromRawDiff output: String) throws -> [JunchatReleasePreparation.ChangedFile] {
        let fields = output.split(separator: "\0").map(String.init)
        guard fields.count.isMultiple(of: 2) else {
            throw ValidationError("Git returned malformed raw diff output.")
        }

        return try stride(from: 0, to: fields.count, by: 2).map { index in
            let metadata = fields[index].split(whereSeparator: \.isWhitespace)
            let path = fields[index + 1]
            guard metadata.count == 5,
                  metadata[0].hasPrefix(":"),
                  metadata[0].count == 7,
                  metadata[1].count == 6,
                  metadata[4] == "M",
                  !path.isEmpty else {
                throw ValidationError("Git returned an unsupported raw diff entry.")
            }
            return JunchatReleasePreparation.ChangedFile(path: path, mode: String(metadata[1]))
        }
    }

    static func gitFileContents(path: String, commit: String) async throws -> String {
        guard let output = try await CI.run(.name("git"),
                                            ["show", "\(commit):\(path)"],
                                            output: .string(limit: 5_242_880)).standardOutput else {
            throw ValidationError("Could not read \(path) from the archived release commit.")
        }
        return output
    }

    static func gitPush(tagName: String) async throws {
        let repository = try await CI.gitRepository()
        let expectedCommit = try await gitCurrentCommit()
        try await gitPushTag(tagName: tagName,
                             expectedCommit: expectedCommit,
                             remoteURL: repository.httpsURL.absoluteString,
                             gitConfiguration: authenticatedGitConfiguration(),
                             gitExecutable: .path("/usr/bin/git"),
                             argumentPrefix: [],
                             allowFileTransport: false)
    }

    static func gitPushTagForTesting(tagName: String,
                                     expectedCommit: String,
                                     remoteURL: String,
                                     repositoryPath: String,
                                     gitExecutablePath: String? = nil,
                                     globalConfigurationPath: String? = nil) async throws {
        let executable: Executable = if let gitExecutablePath {
            .name(gitExecutablePath)
        } else {
            .path("/usr/bin/git")
        }
        var parentEnvironment = ProcessInfo.processInfo.environment
        parentEnvironment["GIT_CONFIG_GLOBAL"] = globalConfigurationPath
        try await gitPushTag(tagName: tagName,
                             expectedCommit: expectedCommit,
                             remoteURL: remoteURL,
                             gitConfiguration: [],
                             gitExecutable: executable,
                             argumentPrefix: ["-C", repositoryPath],
                             allowFileTransport: true,
                             parentEnvironment: parentEnvironment)
    }

    static func gitPush(identity: GitReleaseIdentity,
                        expectedLocalCommit: String,
                        expectedRemoteCommit: String) async throws {
        try await gitPushBranch(identity: identity,
                                expectedLocalCommit: expectedLocalCommit,
                                expectedRemoteCommit: expectedRemoteCommit,
                                remoteURL: identity.repository.httpsURL.absoluteString,
                                gitConfiguration: authenticatedGitConfiguration(),
                                gitExecutable: .path("/usr/bin/git"),
                                argumentPrefix: [],
                                ciBranch: ProcessInfo.processInfo.environment["CI_BRANCH"],
                                allowFileTransport: false)
    }

    static func gitPushBranchForTesting(identity: GitReleaseIdentity,
                                        expectedLocalCommit: String,
                                        expectedRemoteCommit: String,
                                        remoteURL: String? = nil,
                                        repositoryPath: String,
                                        gitExecutablePath: String,
                                        globalConfigurationPath: String? = nil) async throws {
        var parentEnvironment = ProcessInfo.processInfo.environment
        parentEnvironment["GIT_CONFIG_GLOBAL"] = globalConfigurationPath
        try await gitPushBranch(identity: identity,
                                expectedLocalCommit: expectedLocalCommit,
                                expectedRemoteCommit: expectedRemoteCommit,
                                remoteURL: remoteURL ?? identity.repository.httpsURL.absoluteString,
                                gitConfiguration: [],
                                gitExecutable: .name(gitExecutablePath),
                                argumentPrefix: ["-C", repositoryPath],
                                ciBranch: identity.branch,
                                allowFileTransport: remoteURL != nil,
                                parentEnvironment: parentEnvironment)
    }

    static func gitBranchPushArguments(branch: String,
                                       expectedLocalCommit: String,
                                       expectedRemoteCommit: String,
                                       repository: GitHubRepository) -> [String] {
        let branchReference = "refs/heads/\(branch)"
        return [
            "push",
            "--force-with-lease=\(branchReference):\(expectedRemoteCommit)",
            repository.httpsURL.absoluteString,
            "\(expectedLocalCommit):\(branchReference)"
        ]
    }

    private static func authenticatedGitConfiguration() throws -> [(key: String, value: String)] {
        guard let apiToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !apiToken.isEmpty else {
            throw ValidationError("GITHUB_TOKEN environment variable is not set.")
        }

        let credentials = Data("x-access-token:\(apiToken)".utf8).base64EncodedString()
        return [("http.https://github.com/.extraheader", "AUTHORIZATION: basic \(credentials)")]
    }

    private static func gitPushBranch(identity: GitReleaseIdentity,
                                      expectedLocalCommit: String,
                                      expectedRemoteCommit: String,
                                      remoteURL: String,
                                      gitConfiguration: [(key: String, value: String)],
                                      gitExecutable: Executable,
                                      argumentPrefix: [String],
                                      ciBranch: String?,
                                      allowFileTransport: Bool,
                                      parentEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let localEnvironment = isolatedGitEnvironment(parentEnvironment: parentEnvironment)
        let currentIdentity = try await gitReleaseIdentity(gitExecutable: gitExecutable,
                                                           argumentPrefix: argumentPrefix,
                                                           environment: localEnvironment,
                                                           ciBranch: ciBranch)
        guard currentIdentity == identity else {
            throw ValidationError("The release repository or checked-out branch changed after preflight.")
        }

        let resolvedLocalCommit = try await gitOutput(gitExecutable,
                                                      arguments: argumentPrefix + ["rev-parse", "--verify", "\(expectedLocalCommit)^{commit}"],
                                                      environment: localEnvironment)
        guard resolvedLocalCommit == expectedLocalCommit else {
            throw ValidationError("The release preparation commit changed before push.")
        }

        let objectDirectory = try await gitObjectDirectory(gitExecutable: gitExecutable,
                                                           argumentPrefix: argumentPrefix,
                                                           environment: localEnvironment)
        let sandbox = try await makeGitPushSandbox(remoteURL: remoteURL,
                                                   objectDirectory: objectDirectory,
                                                   gitConfiguration: gitConfiguration,
                                                   gitExecutable: gitExecutable,
                                                   allowFileTransport: allowFileTransport,
                                                   parentEnvironment: parentEnvironment)
        defer { sandbox.remove() }
        let branchReference = "refs/heads/\(identity.branch)"
        let arguments = [
            "push",
            "--force-with-lease=\(branchReference):\(expectedRemoteCommit)",
            sandbox.remoteName,
            "\(expectedLocalCommit):\(branchReference)"
        ]
        do {
            try await validateGitPushDestination(sandbox)
            try await runGit(sandbox.gitExecutable,
                             arguments: sandbox.arguments(arguments),
                             environment: sandbox.environment)
            try await validateGitPushDestination(sandbox)
        } catch {
            throw GitPushError.pushFailed
        }
    }

    private static func gitReleaseIdentity(gitExecutable: Executable,
                                           argumentPrefix: [String],
                                           environment: Environment,
                                           ciBranch: String?) async throws -> GitReleaseIdentity {
        let originURL = try await rawOriginURL(gitExecutable: gitExecutable,
                                               argumentPrefix: argumentPrefix,
                                               environment: environment)
        let repository = try GitHubRepository(remoteURL: originURL)
        let checkedOutBranch = try await gitOutput(gitExecutable,
                                                   arguments: argumentPrefix + ["symbolic-ref", "--quiet", "--short", "HEAD"],
                                                   environment: environment)
        guard !checkedOutBranch.isEmpty else {
            throw ValidationError("Could not determine the checked-out symbolic branch.")
        }

        let branch: String
        if let ciBranch = ciBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !ciBranch.isEmpty {
            let prefix = "refs/heads/"
            branch = ciBranch.hasPrefix(prefix) ? String(ciBranch.dropFirst(prefix.count)) : ciBranch
            guard branch == checkedOutBranch else {
                throw ValidationError("CI_BRANCH does not match the checked-out symbolic branch.")
            }
        } else {
            branch = checkedOutBranch
        }

        try await runGit(gitExecutable,
                         arguments: argumentPrefix + ["check-ref-format", "--branch", branch],
                         environment: environment)
        return GitReleaseIdentity(repository: repository,
                                  originURL: originURL,
                                  branch: branch)
    }

    private static func rawOriginURL(gitExecutable: Executable,
                                     argumentPrefix: [String],
                                     environment: Environment) async throws -> String {
        try await gitOutput(gitExecutable,
                            arguments: argumentPrefix + ["config", "--local", "--no-includes", "--get", "remote.origin.url"],
                            environment: environment)
    }

    private static func gitPushTag(tagName: String,
                                   expectedCommit: String,
                                   remoteURL: String,
                                   gitConfiguration: [(key: String, value: String)],
                                   gitExecutable: Executable,
                                   argumentPrefix: [String],
                                   allowFileTransport: Bool,
                                   parentEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let localEnvironment = isolatedGitEnvironment(parentEnvironment: parentEnvironment)
        let tagReference = "refs/tags/\(tagName)"
        try await runGit(gitExecutable,
                         arguments: argumentPrefix + ["check-ref-format", tagReference],
                         environment: localEnvironment)

        let resolvedExpectedCommit = try await gitOutput(gitExecutable,
                                                         arguments: argumentPrefix + ["rev-parse", "--verify", "\(expectedCommit)^{commit}"],
                                                         environment: localEnvironment)
        guard resolvedExpectedCommit == expectedCommit else {
            throw ValidationError("The nightly tag target is not the exact current commit.")
        }

        let localCommit = try await localTagCommit(tagReference,
                                                   gitExecutable: gitExecutable,
                                                   argumentPrefix: argumentPrefix,
                                                   environment: localEnvironment)
        if let localCommit, localCommit != expectedCommit {
            throw ValidationError("The local nightly tag already points to another commit.")
        }

        let objectDirectory = try await gitObjectDirectory(gitExecutable: gitExecutable,
                                                           argumentPrefix: argumentPrefix,
                                                           environment: localEnvironment)
        let sandbox = try await makeGitPushSandbox(remoteURL: remoteURL,
                                                   objectDirectory: objectDirectory,
                                                   gitConfiguration: gitConfiguration,
                                                   gitExecutable: gitExecutable,
                                                   allowFileTransport: allowFileTransport,
                                                   parentEnvironment: parentEnvironment)
        defer { sandbox.remove() }
        let remoteCommit = try await remoteTagCommit(tagReference, sandbox: sandbox)
        if let remoteCommit, remoteCommit != expectedCommit {
            throw ValidationError("The remote nightly tag already points to another commit.")
        }

        try await ensureLocalTag(tagName: tagName,
                                 tagReference: tagReference,
                                 expectedCommit: expectedCommit,
                                 existingCommit: localCommit,
                                 gitExecutable: gitExecutable,
                                 argumentPrefix: argumentPrefix,
                                 environment: localEnvironment)

        guard try await localTagCommit(tagReference,
                                       gitExecutable: gitExecutable,
                                       argumentPrefix: argumentPrefix,
                                       environment: localEnvironment) == expectedCommit else {
            throw ValidationError("The local nightly tag does not point to the exact current commit.")
        }
        guard remoteCommit == nil else { return }

        let tagObject = try await gitOutput(gitExecutable,
                                            arguments: argumentPrefix + ["rev-parse", "--verify", tagReference],
                                            environment: localEnvironment)
        try await runGit(sandbox.gitExecutable,
                         arguments: sandbox.arguments(["update-ref", tagReference, tagObject]),
                         environment: sandbox.environment)
        do {
            try await validateGitPushDestination(sandbox)
            try await runGit(sandbox.gitExecutable,
                             arguments: sandbox.arguments(["push", sandbox.remoteName, "\(tagReference):\(tagReference)"]),
                             environment: sandbox.environment)
            try await validateGitPushDestination(sandbox)
        } catch {
            guard try await remoteTagCommit(tagReference, sandbox: sandbox) == expectedCommit else {
                throw ValidationError("Authenticated git push failed.")
            }
            return
        }

        guard try await remoteTagCommit(tagReference, sandbox: sandbox) == expectedCommit else {
            throw ValidationError("The pushed nightly tag could not be verified on the remote.")
        }
    }

    private static func ensureLocalTag(tagName: String,
                                       tagReference: String,
                                       expectedCommit: String,
                                       existingCommit: String?,
                                       gitExecutable: Executable,
                                       argumentPrefix: [String],
                                       environment: Environment) async throws {
        guard existingCommit == nil else { return }
        do {
            try await runGit(gitExecutable,
                             arguments: argumentPrefix + [
                                 "-c", "core.hooksPath=/dev/null",
                                 "-c", "tag.gpgSign=false",
                                 "tag", tagName, expectedCommit
                             ],
                             environment: environment)
        } catch {
            guard try await localTagCommit(tagReference,
                                           gitExecutable: gitExecutable,
                                           argumentPrefix: argumentPrefix,
                                           environment: environment) == expectedCommit else {
                throw error
            }
        }
    }

    private static func localTagCommit(_ tagReference: String,
                                       gitExecutable: Executable,
                                       argumentPrefix: [String],
                                       environment: Environment) async throws -> String? {
        let output = try await gitOutput(gitExecutable,
                                         arguments: argumentPrefix + ["for-each-ref", "--format=%(refname)", tagReference],
                                         environment: environment)
        guard !output.isEmpty else { return nil }
        guard output == tagReference else {
            throw ValidationError("Git returned an ambiguous local nightly tag reference.")
        }
        return try await gitOutput(gitExecutable,
                                   arguments: argumentPrefix + ["rev-parse", "--verify", "\(tagReference)^{commit}"],
                                   environment: environment)
    }

    private static func remoteTagCommit(_ tagReference: String,
                                        sandbox: GitPushSandbox) async throws -> String? {
        try await validateGitPushDestination(sandbox)
        let output = try await gitOutput(sandbox.gitExecutable,
                                         arguments: sandbox.arguments(["ls-remote",
                                                                       sandbox.remoteName,
                                                                       tagReference,
                                                                       "\(tagReference)^{}"]),
                                         environment: sandbox.environment)
        try await validateGitPushDestination(sandbox)
        guard !output.isEmpty else { return nil }

        var tagObject: String?
        var peeledCommit: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else {
                throw ValidationError("Git returned a malformed remote nightly tag reference.")
            }
            let commit = String(fields[0])
            switch String(fields[1]) {
            case tagReference where tagObject == nil:
                tagObject = commit
            case "\(tagReference)^{}" where peeledCommit == nil:
                peeledCommit = commit
            default:
                throw ValidationError("Git returned an ambiguous remote nightly tag reference.")
            }
        }
        guard let tagObject else {
            throw ValidationError("Git returned a peeled nightly tag without its tag reference.")
        }
        return peeledCommit ?? tagObject
    }

    private static func isolatedGitEnvironment(configuration: [(key: String, value: String)] = [],
                                               allowFileTransport: Bool = false,
                                               parentEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Environment {
        _ = parentEnvironment
        var gitConfiguration = [
            (key: "core.hooksPath", value: "/dev/null"),
            (key: "credential.interactive", value: "never"),
            (key: "protocol.allow", value: "never"),
            (key: "protocol.ext.allow", value: "never"),
            (key: "protocol.https.allow", value: "always")
        ]
        if allowFileTransport {
            gitConfiguration.append((key: "protocol.file.allow", value: "always"))
        }
        gitConfiguration.append(contentsOf: configuration)

        var environment: [Environment.Key: String] = [
            "GCM_INTERACTIVE": "never",
            "GIT_ASKPASS": "/usr/bin/false",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_PROTOCOL_FROM_USER": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "HOME": "/var/empty",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SSH_ASKPASS": "/usr/bin/false",
            "XDG_CONFIG_HOME": "/var/empty"
        ]
        environment["GIT_CONFIG_COUNT"] = String(gitConfiguration.count)
        for (index, entry) in gitConfiguration.enumerated() {
            environment[Environment.Key(rawValue: "GIT_CONFIG_KEY_\(index)")!] = entry.key
            environment[Environment.Key(rawValue: "GIT_CONFIG_VALUE_\(index)")!] = entry.value
        }
        return .custom(environment)
    }

    private static func gitObjectDirectory(gitExecutable: Executable,
                                           argumentPrefix: [String],
                                           environment: Environment) async throws -> URL {
        let path = try await gitOutput(gitExecutable,
                                       arguments: argumentPrefix + [
                                           "rev-parse",
                                           "--path-format=absolute",
                                           "--git-path", "objects"
                                       ],
                                       environment: environment)
        guard NSString(string: path).isAbsolutePath,
              !path.contains("\n") else {
            throw ValidationError("Could not isolate the release repository object database.")
        }
        let objectDirectory = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: objectDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ValidationError("Could not isolate the release repository object database.")
        }
        return objectDirectory
    }

    private static func makeGitPushSandbox(remoteURL: String,
                                           objectDirectory: URL,
                                           gitConfiguration: [(key: String, value: String)],
                                           gitExecutable: Executable,
                                           allowFileTransport: Bool,
                                           parentEnvironment: [String: String]) async throws -> GitPushSandbox {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "junchat-git-push-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gitDirectoryURL = rootURL.appending(path: "repository.git", directoryHint: .isDirectory)
        let remoteName = "validated-release-destination"
        let environment = isolatedGitEnvironment(configuration: gitConfiguration,
                                                 allowFileTransport: allowFileTransport,
                                                 parentEnvironment: parentEnvironment)
        let sandbox = GitPushSandbox(rootURL: rootURL,
                                     gitDirectoryURL: gitDirectoryURL,
                                     remoteName: remoteName,
                                     remoteURL: remoteURL,
                                     environment: environment,
                                     gitExecutable: gitExecutable)
        do {
            try FileManager.default.createDirectory(at: rootURL,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try await runGit(gitExecutable,
                             arguments: ["init", "--bare", gitDirectoryURL.path],
                             environment: environment)
            let alternatesURL = gitDirectoryURL.appending(path: "objects/info/alternates")
            try Data("\(objectDirectory.path)\n".utf8).write(to: alternatesURL, options: .withoutOverwriting)
            try await runGit(gitExecutable,
                             arguments: sandbox.arguments([
                                 "config", "--local", "--no-includes",
                                 "remote.\(remoteName).url", remoteURL
                             ]),
                             environment: environment)
            try await validateGitPushDestination(sandbox)
            return sandbox
        } catch {
            sandbox.remove()
            throw error
        }
    }

    private static func validateGitPushDestination(_ sandbox: GitPushSandbox) async throws {
        let destinations = try await gitOutput(sandbox.gitExecutable,
                                               arguments: sandbox.arguments([
                                                   "remote", "get-url", "--push", "--all", sandbox.remoteName
                                               ]),
                                               environment: sandbox.environment)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard destinations == [sandbox.remoteURL] else {
            throw ValidationError("Git push destination validation failed closed.")
        }
    }

    private static func runGit(_ executable: Executable,
                               arguments: [String],
                               environment: Environment) async throws {
        try await CI.run(executable,
                         Arguments(arguments),
                         environment: environment)
    }

    private static func gitOutput(_ executable: Executable,
                                  arguments: [String],
                                  environment: Environment) async throws -> String {
        guard let output = try await CI.run(executable,
                                            Arguments(arguments),
                                            environment: environment,
                                            output: .string(limit: 1_048_576)).standardOutput else {
            throw ValidationError("Git returned no output.")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
