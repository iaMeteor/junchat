import Foundation

enum XcodeCloudReleaseEnvironment {
    enum Workflow: String {
        case release = "Release"
        case nightly = "Nightly"
    }

    enum EnvironmentError: LocalizedError {
        case invalidValue(commandName: String, variable: String, expected: String)
        case missingWorkflowID(commandName: String)

        var errorDescription: String? {
            switch self {
            case .invalidValue(let commandName, let variable, let expected):
                "\(commandName) requires \(variable)=\(expected) from Xcode Cloud."
            case .missingWorkflowID(let commandName):
                "\(commandName) requires a nonempty CI_WORKFLOW_ID from Xcode Cloud."
            }
        }
    }

    static func validate(_ environment: [String: String],
                         commandName: String,
                         expectedWorkflow: Workflow) throws {
        try validate(environment,
                     commandName: commandName,
                     allowedWorkflows: [expectedWorkflow])
    }

    static func validate(_ environment: [String: String],
                         commandName: String,
                         allowedWorkflows: [Workflow]) throws {
        let requiredValues = [
            (variable: "CI", expected: "TRUE"),
            (variable: "CI_XCODE_CLOUD", expected: "TRUE"),
            (variable: "CI_XCODEBUILD_ACTION", expected: "archive")
        ]
        for requirement in requiredValues where environment[requirement.variable] != requirement.expected {
            throw EnvironmentError.invalidValue(commandName: commandName,
                                                variable: requirement.variable,
                                                expected: requirement.expected)
        }

        let expectedWorkflows = allowedWorkflows.map(\.rawValue)
        guard let workflow = environment["CI_WORKFLOW"],
              expectedWorkflows.contains(workflow) else {
            throw EnvironmentError.invalidValue(commandName: commandName,
                                                variable: "CI_WORKFLOW",
                                                expected: expectedWorkflows.joined(separator: " or "))
        }

        guard let workflowID = environment["CI_WORKFLOW_ID"],
              !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnvironmentError.missingWorkflowID(commandName: commandName)
        }
    }

    static func perform(environment: [String: String],
                        commandName: String,
                        expectedWorkflow: Workflow,
                        operation: () async throws -> Void) async throws {
        try validate(environment,
                     commandName: commandName,
                     expectedWorkflow: expectedWorkflow)
        try await operation()
    }

    static func perform(environment: [String: String],
                        commandName: String,
                        allowedWorkflows: [Workflow],
                        operation: () async throws -> Void) async throws {
        try validate(environment,
                     commandName: commandName,
                     allowedWorkflows: allowedWorkflows)
        try await operation()
    }
}
