import ArgumentParser

struct CurrentReleaseVersion: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current-release-version",
                                                    abstract: "Prints the current marketing version without changing the project.")

    @Flag(name: .long, help: "Also print the current build number, separated by a tab.")
    var includeBuild = false

    func run() throws {
        let version = try CI.readReleaseVersion()
        if includeBuild {
            print("\(version.name)\t\(version.build)")
        } else {
            print(version.name)
        }
    }
}
