import ArgumentParser
import Foundation

struct ValidateJunchatReleasePreflight: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-junchat-release-preflight",
                                                    abstract: "Validates local release metadata and XcodeGen output without remote access.")

    @Option(help: "The private path where the validated release artifact binding will be created.")
    var artifactBindingPath: String

    @Option(help: "The private path where the expected binding digest will be created.")
    var artifactBindingDigestPath: String

    @Option(help: "The absolute codesign executable path used by release artifact validation.")
    var codesignExecutablePath = "/usr/bin/codesign"

    @Option(help: "The absolute otool executable path used by release artifact validation.")
    var otoolExecutablePath = "/usr/bin/otool"

    @Option(help: "The absolute dwarfdump executable path used by release artifact validation.")
    var dwarfdumpExecutablePath = "/usr/bin/dwarfdump"

    func run() async throws {
        let commandRunner = ReleaseArtifactCommandRunner.production(codesignExecutablePath: codesignExecutablePath,
                                                                    otoolExecutablePath: otoolExecutablePath,
                                                                    dwarfdumpExecutablePath: dwarfdumpExecutablePath)
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
