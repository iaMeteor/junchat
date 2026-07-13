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

        let changed = try JunchatReleaseVersion.updateProjectFile(at: projectURL,
                                                                  name: versionName,
                                                                  build: buildNumber)
        guard changed else {
            logger.info("JunChat iOS version metadata already matches the requested values.")
            return
        }

        try Zsh.run(command: "xcodegen")
        logger.info("Updated JunChat iOS to \(versionName) (\(buildNumber)).")
    }
}
