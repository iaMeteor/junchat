import ArgumentParser
import Foundation
import Subprocess

struct CI: ParsableCommand {
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
    
    static func gitConfigureGlobals() async throws {
        try await CI.run(.name("git"), ["config", "--global", "user.name", "Element CI"])
        try await CI.run(.name("git"), ["config", "--global", "user.email", "ci@element.io"])
    }
    
    static func gitRepository() async throws -> GitHubRepository {
        guard let rawURL = try await CI.run(.name("git"), ["ls-remote", "--get-url", "origin"],
                                            output: .string(limit: 4096)).standardOutput else {
            throw ValidationError("Could not determine the git remote URL.")
        }

        return try GitHubRepository(remoteURL: rawURL)
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
        let environment = try authenticatedGitEnvironment()
        let expectedCommit = try await gitCurrentCommit()
        try await gitPushTag(tagName: tagName,
                             expectedCommit: expectedCommit,
                             remoteURL: repository.httpsURL.absoluteString,
                             environment: environment,
                             gitExecutable: .name("git"),
                             argumentPrefix: [])
    }

    static func gitPushTagForTesting(tagName: String,
                                     expectedCommit: String,
                                     remoteURL: String,
                                     repositoryPath: String,
                                     gitExecutablePath: String? = nil) async throws {
        let executable: Executable = if let gitExecutablePath {
            .name(gitExecutablePath)
        } else {
            .path("/usr/bin/git")
        }
        try await gitPushTag(tagName: tagName,
                             expectedCommit: expectedCommit,
                             remoteURL: remoteURL,
                             environment: .inherit,
                             gitExecutable: executable,
                             argumentPrefix: ["-C", repositoryPath])
    }

    static func gitPush(branch: String, expectedRemoteCommit: String) async throws {
        let repository = try await CI.gitRepository()
        try await authenticatedGitPush(Arguments(gitBranchPushArguments(branch: branch,
                                                                        expectedRemoteCommit: expectedRemoteCommit,
                                                                        repository: repository)),
                                       environment: authenticatedGitEnvironment())
    }

    static func gitBranchPushArguments(branch: String,
                                       expectedRemoteCommit: String,
                                       repository: GitHubRepository) -> [String] {
        let branchReference = "refs/heads/\(branch)"
        return [
            "push",
            "--force-with-lease=\(branchReference):\(expectedRemoteCommit)",
            repository.httpsURL.absoluteString,
            "HEAD:\(branchReference)"
        ]
    }

    private static func authenticatedGitEnvironment() throws -> Environment {
        guard let apiToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !apiToken.isEmpty else {
            throw ValidationError("GITHUB_TOKEN environment variable is not set.")
        }

        let credentials = Data("x-access-token:\(apiToken)".utf8).base64EncodedString()
        return Environment.inherit.updating([
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic \(credentials)"
        ])
    }

    private static func authenticatedGitPush(_ arguments: Arguments, environment: Environment) async throws {
        do {
            try await CI.run(.name("git"), arguments, environment: environment)
        } catch {
            throw ValidationError("Authenticated git push failed.")
        }
    }

    private static func gitPushTag(tagName: String,
                                   expectedCommit: String,
                                   remoteURL: String,
                                   environment: Environment,
                                   gitExecutable: Executable,
                                   argumentPrefix: [String]) async throws {
        let tagReference = "refs/tags/\(tagName)"
        try await runGit(gitExecutable,
                         arguments: argumentPrefix + ["check-ref-format", tagReference],
                         environment: environment)

        let resolvedExpectedCommit = try await gitOutput(gitExecutable,
                                                         arguments: argumentPrefix + ["rev-parse", "--verify", "\(expectedCommit)^{commit}"],
                                                         environment: environment)
        guard resolvedExpectedCommit == expectedCommit else {
            throw ValidationError("The nightly tag target is not the exact current commit.")
        }

        let localCommit = try await localTagCommit(tagReference,
                                                   gitExecutable: gitExecutable,
                                                   argumentPrefix: argumentPrefix,
                                                   environment: environment)
        if let localCommit, localCommit != expectedCommit {
            throw ValidationError("The local nightly tag already points to another commit.")
        }

        let remoteCommit = try await remoteTagCommit(tagReference,
                                                     remoteURL: remoteURL,
                                                     gitExecutable: gitExecutable,
                                                     argumentPrefix: argumentPrefix,
                                                     environment: environment)
        if let remoteCommit, remoteCommit != expectedCommit {
            throw ValidationError("The remote nightly tag already points to another commit.")
        }

        if localCommit == nil {
            do {
                try await runGit(gitExecutable,
                                 arguments: argumentPrefix + ["tag", tagName, expectedCommit],
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

        guard try await localTagCommit(tagReference,
                                       gitExecutable: gitExecutable,
                                       argumentPrefix: argumentPrefix,
                                       environment: environment) == expectedCommit else {
            throw ValidationError("The local nightly tag does not point to the exact current commit.")
        }
        guard remoteCommit == nil else { return }

        let pushArguments = argumentPrefix + ["push", remoteURL, "\(tagReference):\(tagReference)"]
        do {
            try await runGit(gitExecutable,
                             arguments: pushArguments,
                             environment: environment)
        } catch {
            guard try await remoteTagCommit(tagReference,
                                            remoteURL: remoteURL,
                                            gitExecutable: gitExecutable,
                                            argumentPrefix: argumentPrefix,
                                            environment: environment) == expectedCommit else {
                throw ValidationError("Authenticated git push failed.")
            }
            return
        }

        guard try await remoteTagCommit(tagReference,
                                        remoteURL: remoteURL,
                                        gitExecutable: gitExecutable,
                                        argumentPrefix: argumentPrefix,
                                        environment: environment) == expectedCommit else {
            throw ValidationError("The pushed nightly tag could not be verified on the remote.")
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
                                        remoteURL: String,
                                        gitExecutable: Executable,
                                        argumentPrefix: [String],
                                        environment: Environment) async throws -> String? {
        let output = try await gitOutput(gitExecutable,
                                         arguments: argumentPrefix + ["ls-remote", remoteURL, tagReference, "\(tagReference)^{}"],
                                         environment: environment)
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

    static func gitCurrentBranchName() async throws -> String {
        let branchName: String
        if let cloudBranch = ProcessInfo.processInfo.environment["CI_BRANCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cloudBranch.isEmpty {
            let prefix = "refs/heads/"
            branchName = cloudBranch.hasPrefix(prefix) ? String(cloudBranch.dropFirst(prefix.count)) : cloudBranch
        } else {
            guard let currentBranch = try await CI.run(.name("git"),
                                                       ["symbolic-ref", "--quiet", "--short", "HEAD"],
                                                       output: .string(limit: 4096)).standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                !currentBranch.isEmpty else {
                throw ValidationError("Could not determine the branch to push.")
            }
            branchName = currentBranch
        }

        try await CI.run(.name("git"), ["check-ref-format", "--branch", branchName])
        return branchName
    }
}
