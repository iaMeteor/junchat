import ArgumentParser

struct ValidateJunchatReleasePreflight: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-junchat-release-preflight",
                                                    abstract: "Validates local release metadata and XcodeGen output without remote access.")

    func run() async throws {
        try await JunchatReleasePreflight.validateCurrentRepository()
    }
}
