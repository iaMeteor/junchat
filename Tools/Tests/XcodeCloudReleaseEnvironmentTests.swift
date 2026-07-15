@testable import Tools
import XCTest

final class XcodeCloudReleaseEnvironmentTests: XCTestCase {
    private let validEnvironment = [
        "CI": "TRUE",
        "CI_XCODE_CLOUD": "TRUE",
        "CI_WORKFLOW": "Release",
        "CI_WORKFLOW_ID": "42",
        "CI_XCODEBUILD_ACTION": "archive"
    ]

    func testAcceptsTheXcodeCloudReleaseArchiveEnvironment() throws {
        XCTAssertNoThrow(try XcodeCloudReleaseEnvironment.validate(validEnvironment))
    }

    func testRejectsLocalAndOtherXcodeCloudWorkflowEnvironments() {
        let missingValueEnvironments = validEnvironment.keys.map { missingKey in
            validEnvironment.filter { $0.key != missingKey }
        }
        let invalidEnvironments: [[String: String]] = missingValueEnvironments + [
            [:],
            validEnvironment.merging(["CI": "true"]) { _, replacement in replacement },
            validEnvironment.merging(["CI_XCODE_CLOUD": "FALSE"]) { _, replacement in replacement },
            validEnvironment.merging(["CI_WORKFLOW": "Nightly"]) { _, replacement in replacement },
            validEnvironment.merging(["CI_WORKFLOW_ID": "   "]) { _, replacement in replacement },
            validEnvironment.merging(["CI_XCODEBUILD_ACTION": "build"]) { _, replacement in replacement }
        ]

        for environment in invalidEnvironments {
            XCTAssertThrowsError(try XcodeCloudReleaseEnvironment.validate(environment))
        }
    }

    func testRejectsBeforeRunningTheProtectedOperation() async {
        var operationRan = false

        do {
            try await XcodeCloudReleaseEnvironment.perform(environment: [:]) {
                operationRan = true
            }
            XCTFail("Expected a local invocation to fail closed")
        } catch { }

        XCTAssertFalse(operationRan)
    }
}
