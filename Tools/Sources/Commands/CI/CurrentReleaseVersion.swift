import ArgumentParser

struct CurrentReleaseVersion: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current-release-version",
                                                    abstract: "Prints the current marketing version without changing the project.")

    func run() throws {
        try print(CI.readMarketingVersion())
    }
}
