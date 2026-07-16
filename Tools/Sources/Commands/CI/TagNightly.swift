import ArgumentParser
import Foundation
import Yams

struct TagNightly: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tags the current commit as a nightly build and pushes the tag.")

    @Option(help: "The build number to include in the tag.")
    var buildNumber: String

    @Option(help: "The private validated release artifact binding path.")
    var artifactBindingPath: String

    @Option(help: "The expected SHA-256 digest of the release artifact binding.")
    var expectedArtifactBindingDigest: String

    func run() async throws {
        guard !buildNumber.isEmpty else {
            throw ValidationError("Invalid build number.")
        }
        let currentVersion = try CI.readMarketingVersion()
        let tagName = "nightly/\(currentVersion).\(buildNumber)"

        _ = try JunchatReleaseArtifacts.revalidateBinding(atPath: artifactBindingPath,
                                                          expectedDigest: expectedArtifactBindingDigest,
                                                          validateProjectMetadata: true)
        try await CI.gitPush(tagName: tagName)

        logger.info("\n🚀 Successfully tagged nightly: \(tagName)\n")
    }
}
