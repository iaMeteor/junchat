import Foundation
@testable import Tools
import XCTest

final class GitHubReleaseAPITests: XCTestCase {
    func testReusesAnExistingMatchingDraftWithoutCreatingAnotherRelease() async throws {
        let targetCommit = String(repeating: "a", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, [releaseRecord(targetCommit: targetCommit)])
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        let requests = stub.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.query, "per_page=100&page=1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertFalse(try XCTUnwrap(requests[0].url?.absoluteString).contains("secret"))
    }

    func testCreatesADraftOnlyWhenNoExistingReleaseMatches() async throws {
        let targetCommit = String(repeating: "b", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(201, releaseRecord(targetCommit: targetCommit))
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "https://github.com/acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        let requests = stub.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(payload["draft"] as? Bool, true)
        XCTAssertEqual(payload["target_commitish"] as? String, targetCommit)
    }

    func testDoesNotCreateADraftWhenRemotePreparationValidationRequiresAnExistingOne() async throws {
        let targetCommit = String(repeating: "2", count: 40)
        let stub = GitHubHTTPStub(responses: [.json(200, [])])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        do {
            _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                 targetCommit: targetCommit,
                                                 repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                 token: "secret",
                                                 allowCreation: false)
            XCTFail("Expected validation-only lookup to reject a missing draft")
        } catch {
            XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET"])
        }
    }

    func testRejectsAnExistingPublishedOrMisdirectedRelease() async throws {
        let targetCommit = String(repeating: "c", count: 40)
        let invalidRecords = [
            releaseRecord(targetCommit: targetCommit, draft: false),
            releaseRecord(targetCommit: String(repeating: "d", count: 40))
        ]

        for record in invalidRecords {
            let stub = GitHubHTTPStub(responses: [.json(200, [record])])
            let api = GitHubReleaseAPI(dataLoader: stub.data(for:))
            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected an incompatible existing release to fail closed")
            } catch {
                XCTAssertEqual(stub.requests.count, 1)
            }
        }
    }

    func testSearchesAdditionalReleasePagesBeforeCreating() async throws {
        let targetCommit = String(repeating: "e", count: 40)
        let firstPage = (0..<100).map { index in
            releaseRecord(version: "9.9.\(index)", targetCommit: targetCommit)
        }
        let stub = GitHubHTTPStub(responses: [
            .json(200, firstPage),
            .json(200, [releaseRecord(targetCommit: targetCommit)])
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        _ = try await api.createOrReuseDraft(version: "1.8.2",
                                             targetCommit: targetCommit,
                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                             token: "secret")

        XCTAssertEqual(stub.requests.map { $0.url?.query }, ["per_page=100&page=1", "per_page=100&page=2"])
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET"])
    }

    func testReusesACompatibleDraftCreatedByAConcurrentRetry() async throws {
        let targetCommit = String(repeating: "f", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(422, ["message": "already_exists"]),
            .json(200, [releaseRecord(targetCommit: targetCommit)])
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "POST", "GET"])
    }

    func testRecognizesAnAlreadyPushedPreparationWhenRebuildingTheArchivedCommit() async throws {
        let releaseCommit = String(repeating: "a", count: 40)
        let preparationCommit = String(repeating: "b", count: 40)
        let releaseVersion = JunchatReleaseVersion(name: "1.8.2", build: 37)
        let preparation = try JunchatReleasePreparation(releaseVersion: releaseVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: "2026-07-14")
        let preparedProject = try JunchatReleaseVersion.updatedProjectYAML(releaseProjectYAML,
                                                                           name: "1.8.3",
                                                                           build: 38)
        let preparedChanges = try JunchatReleaseNotes.updatedChangelog(existingContent: releaseChangelog,
                                                                       version: releaseVersion.name,
                                                                       generatedNotes: "## Highlights\n- Fixed retry",
                                                                       releaseDate: preparation.releaseDate)
        let stub = GitHubHTTPStub(responses: [
            .json(200, referenceRecord(commit: preparationCommit)),
            .json(200, preparationCommitRecord(commit: preparationCommit,
                                               preparation: preparation)),
            .json(200, contentRecord(releaseProjectYAML)),
            .json(200, contentRecord(preparedProject)),
            .json(200, contentRecord(releaseChangelog)),
            .json(200, contentRecord(preparedChanges))
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        let isPrepared = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                                  releaseVersion: releaseVersion,
                                                                  releaseCommit: releaseCommit,
                                                                  generatedNotes: "## Highlights\n- Fixed retry",
                                                                  repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                                  token: "secret")

        XCTAssertTrue(isPrepared)
        XCTAssertEqual(stub.requests.count, 6)
        XCTAssertTrue(try XCTUnwrap(stub.requests.first?.url?.absoluteString).contains("heads/release/ios"))
    }

    func testRemoteBranchAtTheArchivedCommitStillNeedsPreparation() async throws {
        let releaseCommit = String(repeating: "c", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, referenceRecord(commit: releaseCommit))
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        let isPrepared = try await api.isPreparationAlreadyPushed(branch: "junchat",
                                                                  releaseVersion: JunchatReleaseVersion(name: "1.8.2", build: 37),
                                                                  releaseCommit: releaseCommit,
                                                                  generatedNotes: "- Fixed retry",
                                                                  repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                                  token: "secret")

        XCTAssertFalse(isPrepared)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testRejectsUnrelatedRemoteBranchAdvancement() async throws {
        let releaseCommit = String(repeating: "d", count: 40)
        let preparationCommit = String(repeating: "e", count: 40)
        let preparation = try JunchatReleasePreparation(releaseVersion: .init(name: "1.8.2", build: 37),
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: "2026-07-14")
        let stub = GitHubHTTPStub(responses: [
            .json(200, referenceRecord(commit: preparationCommit)),
            .json(200, preparationCommitRecord(commit: preparationCommit,
                                               preparation: preparation,
                                               changedPaths: ["Unrelated.swift"]))
        ])
        let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

        do {
            _ = try await api.isPreparationAlreadyPushed(branch: "junchat",
                                                         releaseVersion: preparation.releaseVersion,
                                                         releaseCommit: releaseCommit,
                                                         generatedNotes: "- Fixed retry",
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret")
            XCTFail("Expected unrelated remote advancement to fail closed")
        } catch {
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testRejectsPreparationWithUnexpectedVersionOrChangelogContent() async throws {
        let releaseCommit = String(repeating: "f", count: 40)
        let preparationCommit = String(repeating: "1", count: 40)
        let releaseVersion = JunchatReleaseVersion(name: "1.8.2", build: 37)
        let preparation = try JunchatReleasePreparation(releaseVersion: releaseVersion,
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: "2026-07-14")
        let preparedProject = try JunchatReleaseVersion.updatedProjectYAML(releaseProjectYAML,
                                                                           name: "1.8.3",
                                                                           build: 38)
        let preparedChanges = try JunchatReleaseNotes.updatedChangelog(existingContent: releaseChangelog,
                                                                       version: releaseVersion.name,
                                                                       generatedNotes: "- Fixed retry",
                                                                       releaseDate: preparation.releaseDate)
        let invalidContents = [
            (project: releaseProjectYAML, changelog: preparedChanges, expectedRequests: 4),
            (project: preparedProject, changelog: preparedChanges + "Tampered\n", expectedRequests: 6)
        ]

        for invalidContent in invalidContents {
            let stub = GitHubHTTPStub(responses: [
                .json(200, referenceRecord(commit: preparationCommit)),
                .json(200, preparationCommitRecord(commit: preparationCommit,
                                                   preparation: preparation)),
                .json(200, contentRecord(releaseProjectYAML)),
                .json(200, contentRecord(invalidContent.project)),
                .json(200, contentRecord(releaseChangelog)),
                .json(200, contentRecord(invalidContent.changelog))
            ])
            let api = GitHubReleaseAPI(dataLoader: stub.data(for:))

            do {
                _ = try await api.isPreparationAlreadyPushed(branch: "junchat",
                                                             releaseVersion: releaseVersion,
                                                             releaseCommit: releaseCommit,
                                                             generatedNotes: "- Fixed retry",
                                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                             token: "secret")
                XCTFail("Expected modified preparation content to fail closed")
            } catch {
                XCTAssertEqual(stub.requests.count, invalidContent.expectedRequests)
            }
        }
    }
}

private let releaseProjectYAML = """
settings:
  MARKETING_VERSION: 1.8.2
  CURRENT_PROJECT_VERSION: 37
"""

private let releaseChangelog = """
# JunChat iOS Changes

JunChat fork release notes are recorded here.
"""

private func releaseRecord(version: String = "1.8.2",
                           targetCommit: String,
                           draft: Bool = true) -> [String: Any] {
    [
        "tag_name": "release/\(version)",
        "name": version,
        "target_commitish": targetCommit,
        "body": "Generated notes",
        "draft": draft
    ]
}

private func referenceRecord(commit: String) -> [String: Any] {
    ["object": ["sha": commit]]
}

private func preparationCommitRecord(commit: String,
                                     preparation: JunchatReleasePreparation,
                                     changedPaths: [String] = [
                                         "JUNCHAT_CHANGES.md",
                                         "project.yml",
                                         "ElementX.xcodeproj/project.pbxproj"
                                     ]) -> [String: Any] {
    [
        "sha": commit,
        "commit": ["message": preparation.commitMessage],
        "parents": [["sha": preparation.releaseCommit]],
        "files": changedPaths.map { ["filename": $0, "status": "modified"] }
    ]
}

private func contentRecord(_ content: String) -> [String: Any] {
    [
        "encoding": "base64",
        "content": Data(content.utf8).base64EncodedString()
    ]
}

private final class GitHubHTTPStub: @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let data: Data

        static func json(_ statusCode: Int, _ object: Any) -> Response {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                preconditionFailure("Test release response must be valid JSON")
            }
            return Response(statusCode: statusCode,
                            data: data)
        }
    }

    private let lock = NSLock()
    private var pendingResponses: [Response]
    private var recordedRequests = [URLRequest]()

    init(responses: [Response]) {
        pendingResponses = responses
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            recordedRequests.append(request)
            guard !pendingResponses.isEmpty else {
                throw StubError.missingResponse
            }
            let response = pendingResponses.removeFirst()
            guard let httpResponse = try HTTPURLResponse(url: XCTUnwrap(request.url),
                                                         statusCode: response.statusCode,
                                                         httpVersion: nil,
                                                         headerFields: nil) else {
                throw StubError.invalidResponse
            }
            return (response.data, httpResponse)
        }
    }

    private enum StubError: Error {
        case invalidResponse
        case missingResponse
    }
}
