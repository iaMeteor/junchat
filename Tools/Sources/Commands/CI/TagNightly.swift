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
        try await run(environment: ProcessInfo.processInfo.environment,
                      readMarketingVersion: CI.readMarketingVersion,
                      revalidateBinding: { bindingPath, expectedDigest in
                          _ = try JunchatReleaseArtifacts.revalidateBinding(atPath: bindingPath,
                                                                            expectedDigest: expectedDigest,
                                                                            validateProjectMetadata: true)
                      },
                      pushTag: { try await CI.gitPush(tagName: $0) })
    }

    func run(environment: [String: String],
             readMarketingVersion: () throws -> String,
             revalidateBinding: (_ bindingPath: String, _ expectedDigest: String) throws -> Void,
             pushTag: (_ tagName: String) async throws -> Void) async throws {
        try await XcodeCloudReleaseEnvironment.perform(environment: environment,
                                                       commandName: "tag-nightly",
                                                       expectedWorkflow: .nightly) {
            guard !buildNumber.isEmpty else {
                throw ValidationError("Invalid build number.")
            }
            let currentVersion = try readMarketingVersion()
            let tagName = "nightly/\(currentVersion).\(buildNumber)"

            try revalidateBinding(artifactBindingPath, expectedArtifactBindingDigest)
            try await pushTag(tagName)

            logger.info("\n🚀 Successfully tagged nightly: \(tagName)\n")
        }
    }
}
