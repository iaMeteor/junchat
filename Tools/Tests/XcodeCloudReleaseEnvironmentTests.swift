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
        XCTAssertNoThrow(try XcodeCloudReleaseEnvironment.validate(validEnvironment,
                                                                   commandName: "release-to-github",
                                                                   expectedWorkflow: .release))
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
            XCTAssertThrowsError(try XcodeCloudReleaseEnvironment.validate(environment,
                                                                           commandName: "release-to-github",
                                                                           expectedWorkflow: .release))
        }
    }

    func testRejectsBeforeRunningTheProtectedOperation() async {
        var operationRan = false

        do {
            try await XcodeCloudReleaseEnvironment.perform(environment: [:],
                                                           commandName: "release-to-github",
                                                           expectedWorkflow: .release) {
                operationRan = true
            }
            XCTFail("Expected a local invocation to fail closed")
        } catch { }

        XCTAssertFalse(operationRan)
    }

    func testNightlyCommandAuthorizationRunsOnlyForTheNightlyArchiveIdentity() async {
        var releaseSideEffects = 0
        do {
            try await XcodeCloudReleaseEnvironment.perform(environment: validEnvironment,
                                                           commandName: "tag-nightly",
                                                           expectedWorkflow: .nightly) {
                releaseSideEffects += 1
            }
        } catch { }

        var nightlySideEffects = 0
        let nightlyEnvironment = validEnvironment.merging(["CI_WORKFLOW": "Nightly"]) { _, replacement in replacement }
        do {
            try await XcodeCloudReleaseEnvironment.perform(environment: nightlyEnvironment,
                                                           commandName: "tag-nightly",
                                                           expectedWorkflow: .nightly) {
                nightlySideEffects += 1
            }
        } catch { }

        XCTAssertEqual(releaseSideEffects, 0)
        XCTAssertEqual(nightlySideEffects, 1)
    }

    func testUploadAuthorizationRunsOnlyForReleaseOrNightlyArchiveIdentities() async {
        let validEnvironments = [
            validEnvironment,
            validEnvironment.merging(["CI_WORKFLOW": "Nightly"]) { _, replacement in replacement }
        ]
        var sideEffects = 0

        for environment in validEnvironments {
            do {
                try await XcodeCloudReleaseEnvironment.perform(environment: environment,
                                                               commandName: "upload-dsyms",
                                                               allowedWorkflows: [.release, .nightly]) {
                    sideEffects += 1
                }
            } catch { }
        }

        XCTAssertEqual(sideEffects, 2)
    }
}
