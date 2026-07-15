import Foundation

enum XcodeCloudReleaseEnvironment {
    enum EnvironmentError: LocalizedError {
        case invalidValue(variable: String, expected: String)
        case missingWorkflowID

        var errorDescription: String? {
            switch self {
            case .invalidValue(let variable, let expected):
                "release-to-github requires \(variable)=\(expected) from Xcode Cloud."
            case .missingWorkflowID:
                "release-to-github requires a nonempty CI_WORKFLOW_ID from Xcode Cloud."
            }
        }
    }

    static func validate(_ environment: [String: String]) throws {
        let requiredValues = [
            "CI": "TRUE",
            "CI_XCODE_CLOUD": "TRUE",
            "CI_WORKFLOW": "Release",
            "CI_XCODEBUILD_ACTION": "archive"
        ]
        for (variable, expected) in requiredValues where environment[variable] != expected {
            throw EnvironmentError.invalidValue(variable: variable, expected: expected)
        }

        guard let workflowID = environment["CI_WORKFLOW_ID"],
              !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnvironmentError.missingWorkflowID
        }
    }

    static func perform(environment: [String: String],
                        operation: () async throws -> Void) async throws {
        try validate(environment)
        try await operation()
    }
}
