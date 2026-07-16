import ArgumentParser
import Foundation

struct ValidateJunchatReleasePreflight: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-junchat-release-preflight",
                                                    abstract: "Validates local release metadata and XcodeGen output without remote access.")

    @Option(help: "The private path where the validated release artifact binding will be created.")
    var artifactBindingPath: String

    @Option(help: "The private path where the expected binding digest will be created.")
    var artifactBindingDigestPath: String

    func run() async throws {
        try await run(commandRunner: .production())
    }

    func run(commandRunner: ReleaseArtifactCommandRunner) async throws {
        guard let digest = try await JunchatReleasePreflight.validateCurrentRepository(commandRunner: commandRunner,
                                                                                       artifactBindingURL: URL(filePath: artifactBindingPath)) else {
            throw ValidationError("Release artifact preflight did not create a binding digest.")
        }
        try writePrivateDigest(digest, to: URL(filePath: artifactBindingDigestPath))
    }

    private func writePrivateDigest(_ digest: String, to url: URL) throws {
        let fileManager = FileManager.default
        let parentURL = url.deletingLastPathComponent()
        let parentAttributes = try fileManager.attributesOfItem(atPath: parentURL.path)
        let parentPermissions = (parentAttributes[.posixPermissions] as? NSNumber)?.intValue
        guard NSString(string: url.path).isAbsolutePath,
              url.path == url.standardizedFileURL.path,
              parentURL.path == parentURL.resolvingSymlinksInPath().path,
              parentAttributes[.type] as? FileAttributeType == .typeDirectory,
              let parentPermissions,
              parentPermissions & 0o077 == 0,
              !fileManager.fileExists(atPath: url.path) else {
            throw ValidationError("The release artifact binding digest path must be new, canonical, and absolute.")
        }
        let temporaryURL = parentURL.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporaryURL.path,
                                     contents: Data("\(digest)\n".utf8),
                                     attributes: [.posixPermissions: 0o600]) else {
            throw ValidationError("Could not create the private release artifact binding digest.")
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.moveItem(at: temporaryURL, to: url)
    }
}
