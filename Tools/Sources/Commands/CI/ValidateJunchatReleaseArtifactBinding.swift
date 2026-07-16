import ArgumentParser
import Foundation

struct ValidateJunchatReleaseArtifactBinding: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-junchat-release-artifact-binding",
                                                    abstract: "Revalidates an exact release artifact binding without remote access.")

    @Option(help: "The private validated release artifact binding path.")
    var artifactBindingPath: String

    @Option(help: "The expected SHA-256 digest of the release artifact binding.")
    var expectedArtifactBindingDigest: String

    func run() throws {
        _ = try JunchatReleaseArtifacts.revalidateBinding(atPath: artifactBindingPath,
                                                          expectedDigest: expectedArtifactBindingDigest,
                                                          validateProjectMetadata: true)
    }
}
