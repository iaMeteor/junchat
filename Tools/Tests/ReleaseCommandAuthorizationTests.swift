@testable import Tools
import XCTest

final class ReleaseCommandAuthorizationTests: XCTestCase {
    func testTagNightlyRejectsInvalidLocalAndReleaseIdentitiesBeforeEveryProtectedOperation() async {
        var command = TagNightly()
        command.buildNumber = "37"
        command.artifactBindingPath = "/private/tmp/release-artifacts.json"
        command.expectedArtifactBindingDigest = String(repeating: "a", count: 64)
        let invalidEnvironments = [
            [:],
            validEnvironment(workflow: .release),
            validEnvironment(workflow: .nightly).merging(["CI_XCODEBUILD_ACTION": "build"]) { _, replacement in replacement }
        ]
        var versionReads = 0
        var bindingReads = 0
        var pushes = 0

        for environment in invalidEnvironments {
            do {
                try await command.run(environment: environment,
                                      readMarketingVersion: {
                                          versionReads += 1
                                          return "1.8.2"
                                      },
                                      revalidateBinding: { _, _ in bindingReads += 1 },
                                      pushTag: { _ in pushes += 1 })
                XCTFail("Expected tag-nightly to reject an invalid archive identity")
            } catch { }
        }

        XCTAssertEqual(versionReads, 0)
        XCTAssertEqual(bindingReads, 0)
        XCTAssertEqual(pushes, 0)
    }

    func testTagNightlyAllowsTheExactNightlyArchiveIdentity() async throws {
        var command = TagNightly()
        command.buildNumber = "37"
        command.artifactBindingPath = "/private/tmp/release-artifacts.json"
        command.expectedArtifactBindingDigest = String(repeating: "a", count: 64)
        var events = [String]()

        try await command.run(environment: validEnvironment(workflow: .nightly),
                              readMarketingVersion: {
                                  events.append("version")
                                  return "1.8.2"
                              },
                              revalidateBinding: { _, _ in events.append("binding") },
                              pushTag: {
                                  events.append("push:\($0)")
                              })

        XCTAssertEqual(events, ["version", "binding", "push:nightly/1.8.2.37"])
    }

    func testUploadRejectsInvalidIdentityBeforeTokenBindingOrSentry() async {
        let command = uploadCommand()
        let invalidEnvironments = [
            [:],
            validEnvironment(workflow: .release).merging(["CI_XCODE_CLOUD": "FALSE"]) { _, replacement in replacement },
            validEnvironment(workflow: .nightly).merging(["CI_WORKFLOW": "Pull Request"]) { _, replacement in replacement }
        ]
        var tokenReads = 0
        var bindingReads = 0
        var uploads = 0

        for environment in invalidEnvironments {
            do {
                try await command.run(environment: { environment },
                                      readSentryAuthToken: {
                                          tokenReads += 1
                                          return "test-token"
                                      },
                                      revalidateBinding: { _, _ in
                                          bindingReads += 1
                                          return self.releaseArtifacts(dSYMsPath: command.dsymPath)
                                      },
                                      upload: { _ in uploads += 1 })
                XCTFail("Expected upload-dsyms to reject an invalid archive identity")
            } catch { }
        }

        XCTAssertEqual(tokenReads, 0)
        XCTAssertEqual(bindingReads, 0)
        XCTAssertEqual(uploads, 0)
    }

    func testUploadAllowsReleaseAndNightlyArchiveIdentities() async throws {
        for workflow in [XcodeCloudReleaseEnvironment.Workflow.release, .nightly] {
            let command = uploadCommand()
            var tokenReads = 0
            var bindingReads = 0
            var uploads = 0

            try await command.run(environment: { self.validEnvironment(workflow: workflow) },
                                  readSentryAuthToken: {
                                      tokenReads += 1
                                      return "test-token"
                                  },
                                  revalidateBinding: { _, _ in
                                      bindingReads += 1
                                      return self.releaseArtifacts(dSYMsPath: command.dsymPath)
                                  },
                                  upload: { _ in uploads += 1 })

            XCTAssertEqual(tokenReads, 1)
            XCTAssertEqual(bindingReads, 1)
            XCTAssertEqual(uploads, 1)
        }
    }

    func testUploadReauthorizesBeforeRetryingSentry() async {
        let command = uploadCommand(maxRetries: 3)
        var environmentReads = 0
        var tokenReads = 0
        var bindingReads = 0
        var uploads = 0

        do {
            try await command.run(environment: {
                                      environmentReads += 1
                                      return environmentReads < 3 ? self.validEnvironment(workflow: .release) : [:]
                                  },
                                  readSentryAuthToken: {
                                      tokenReads += 1
                                      return "test-token"
                                  },
                                  revalidateBinding: { _, _ in
                                      bindingReads += 1
                                      return self.releaseArtifacts(dSYMsPath: command.dsymPath)
                                  },
                                  upload: { _ in
                                      uploads += 1
                                      throw StubError.uploadFailed
                                  })
            XCTFail("Expected the changed retry identity to fail closed")
        } catch { }

        XCTAssertEqual(environmentReads, 3)
        XCTAssertEqual(tokenReads, 1)
        XCTAssertEqual(bindingReads, 1)
        XCTAssertEqual(uploads, 1)
    }

    private func validEnvironment(workflow: XcodeCloudReleaseEnvironment.Workflow) -> [String: String] {
        [
            "CI": "TRUE",
            "CI_XCODE_CLOUD": "TRUE",
            "CI_WORKFLOW": workflow.rawValue,
            "CI_WORKFLOW_ID": "test-workflow-id",
            "CI_XCODEBUILD_ACTION": "archive"
        ]
    }

    private func releaseArtifacts(dSYMsPath: String) -> JunchatReleasePreflight.ReleaseArtifacts {
        let dSYMsURL = URL(filePath: dSYMsPath)
        return .init(archiveURL: dSYMsURL.deletingLastPathComponent(),
                     signedAppURL: dSYMsURL.deletingLastPathComponent().appending(path: "Junchat.app"),
                     dSYMsURL: dSYMsURL)
    }

    private func uploadCommand(maxRetries: Int = 5) -> UploadDSYMs {
        var command = UploadDSYMs()
        command.dsymPath = "/private/tmp/Junchat.xcarchive/dSYMs"
        command.artifactBindingPath = "/private/tmp/release-artifacts.json"
        command.expectedArtifactBindingDigest = String(repeating: "a", count: 64)
        command.orgSlug = "element"
        command.projectSlug = "element-x-ios"
        command.url = "https://sentry.tools.element.io/"
        command.maxRetries = maxRetries
        return command
    }

    private enum StubError: Error {
        case uploadFailed
    }
}
