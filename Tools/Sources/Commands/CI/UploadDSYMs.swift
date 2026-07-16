import ArgumentParser
import Foundation
import Subprocess

struct UploadDSYMs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload-dsyms",
                                                    abstract: "Uploads dSYMs to Sentry using sentry-cli.",
                                                    discussion: "Requires the SENTRY_AUTH_TOKEN environment variable to be set.")

    @Option(help: "The path to the dSYMs directory or file to upload.")
    var dsymPath: String

    @Option(help: "The private validated release artifact binding path.")
    var artifactBindingPath: String

    @Option(help: "The expected SHA-256 digest of the release artifact binding.")
    var expectedArtifactBindingDigest: String

    @Option(help: "The Sentry organization slug.")
    var orgSlug = "element"

    @Option(help: "The Sentry project slug.")
    var projectSlug = "element-x-ios"

    @Option(help: "The Sentry server URL.")
    var url = "https://sentry.tools.element.io/"

    @Option(help: "The maximum number of upload attempts.")
    var maxRetries = 5

    func run() async throws {
        guard ProcessInfo.processInfo.environment["SENTRY_AUTH_TOKEN"]?.isEmpty == false else {
            throw ValidationError("SENTRY_AUTH_TOKEN environment variable is not set.")
        }

        let arguments: Arguments = [
            "--url", url,
            "dif", "upload",
            "--org", orgSlug,
            "--project", projectSlug,
            "--log-level", "debug",
            dsymPath
        ]

        var lastError: Swift.Error?

        for attempt in 1...maxRetries {
            do {
                logger.info("\n📡 Uploading dSYMs to Sentry (attempt \(attempt)/\(maxRetries))…\n")
                let artifacts = try JunchatReleaseArtifacts.revalidateBinding(atPath: artifactBindingPath,
                                                                              expectedDigest: expectedArtifactBindingDigest)
                let requestedDSYMsURL = URL(filePath: dsymPath)
                guard dsymPath == requestedDSYMsURL.path,
                      dsymPath == requestedDSYMsURL.standardizedFileURL.path,
                      dsymPath == requestedDSYMsURL.resolvingSymlinksInPath().path,
                      requestedDSYMsURL == artifacts.dSYMsURL else {
                    throw ValidationError("The dSYM upload path does not match the validated release artifact binding.")
                }
                try await CI.run(.name("sentry-cli"), arguments)
                logger.info("\n✅ Successfully uploaded dSYMs to Sentry.\n")
                return
            } catch {
                lastError = error
                logger.error("\n❌ Sentry upload attempt \(attempt) failed: \(error.localizedDescription)\n")
            }
        }

        if let lastError {
            throw lastError
        }
    }
}
