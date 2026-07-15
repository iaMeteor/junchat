import ArgumentParser
import CommandLineTools
import Foundation

struct SetJunchatReleaseVersion: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-junchat-release-version",
                                                    abstract: "Validates and updates the JunChat iOS marketing version and build number.")

    @Option(help: "Semantic MAJOR.MINOR.PATCH marketing version.")
    var versionName: String

    @Option(help: "Globally increasing positive build number.")
    var buildNumber: Int

    @Flag(help: "Validate the requested metadata without changing project.yml.")
    var validateOnly = false

    func run() throws {
        let projectURL = URL.projectDirectory.appending(path: "project.yml")
        if validateOnly {
            let projectYAML = try String(contentsOf: projectURL, encoding: .utf8)
            _ = try JunchatReleaseVersion.updatedProjectYAML(projectYAML,
                                                             name: versionName,
                                                             build: buildNumber,
                                                             allowExactNoOp: true)
            logger.info("JunChat iOS version metadata is valid.")
            return
        }

        let changed = try Self.updateProject(at: projectURL,
                                             versionName: versionName,
                                             buildNumber: buildNumber) {
            try Zsh.run(command: "xcodegen")
        }
        if changed {
            logger.info("Updated JunChat iOS to \(versionName) (\(buildNumber)).")
        } else {
            logger.info("Regenerated the Xcode project for existing JunChat iOS version \(versionName) (\(buildNumber)).")
        }
    }

    @discardableResult
    static func updateProject(at projectURL: URL,
                              versionName: String,
                              buildNumber: Int,
                              generateXcodeProject: () throws -> Void) throws -> Bool {
        let changed = try JunchatReleaseVersion.updateProjectFile(at: projectURL,
                                                                  name: versionName,
                                                                  build: buildNumber)
        try generateXcodeProject()

        let generatedProjectYAML = try String(contentsOf: projectURL, encoding: .utf8)
        guard try JunchatReleaseVersion.parse(generatedProjectYAML) == JunchatReleaseVersion(name: versionName,
                                                                                             build: buildNumber) else {
            throw JunchatReleaseVersion.VersionError.roundTripFailed
        }
        return changed
    }
}
