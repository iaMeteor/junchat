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
}

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
