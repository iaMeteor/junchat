import CryptoKit
import Foundation
@testable import Tools
import XCTest

final class GitHubReleaseAPITests: XCTestCase {
    func testListsPublishedReleaseIdentityAndPeeledCommitAcrossEveryPage() async throws {
        let annotatedTagObject = String(repeating: "9", count: 40)
        let firstPublishedCommit = String(repeating: "b", count: 40)
        let secondPublishedCommit = String(repeating: "f", count: 40)
        var firstPage = (0..<96).map { index in
            releaseRecord(version: "9.9.\(index)", targetCommit: String(repeating: "a", count: 40))
        }
        firstPage.append(releaseRecord(version: "1.8.1",
                                       targetCommit: firstPublishedCommit,
                                       id: 181,
                                       draft: false,
                                       publishedAt: "2026-07-01T00:00:00Z"))
        firstPage.append(releaseRecord(version: "1.8.0",
                                       targetCommit: String(repeating: "c", count: 40),
                                       draft: false,
                                       prerelease: true,
                                       publishedAt: "2026-06-01T00:00:00Z"))
        firstPage.append(releaseRecord(version: "1.7.9",
                                       targetCommit: String(repeating: "d", count: 40),
                                       draft: false))
        firstPage.append(releaseRecord(version: "notes-only",
                                       targetCommit: String(repeating: "e", count: 40),
                                       draft: false,
                                       publishedAt: "2026-05-01T00:00:00Z",
                                       tagPrefix: "notes/"))
        let stub = GitHubHTTPStub(responses: [
            .json(200, firstPage),
            .json(200, referenceRecord(commit: annotatedTagObject, type: "tag")),
            .json(200, tagObjectRecord(commit: firstPublishedCommit)),
            .json(200, [releaseRecord(version: "1.7.8",
                                      targetCommit: secondPublishedCommit,
                                      id: 178,
                                      draft: false,
                                      publishedAt: "2026-04-01T00:00:00Z")]),
            .json(200, referenceRecord(commit: secondPublishedCommit))
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        let releases = try await api.publishedReleases(repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                       token: "secret")

        XCTAssertEqual(releases, [
            GitHubPublishedRelease(id: 181,
                                   tagName: "release/1.8.1",
                                   tagCommit: firstPublishedCommit),
            GitHubPublishedRelease(id: 178,
                                   tagName: "release/1.7.8",
                                   tagCommit: secondPublishedCommit)
        ])
        XCTAssertEqual(stub.requests[0].url?.query, "per_page=100&page=1")
        XCTAssertEqual(stub.requests[1].url?.path, "/repos/acme/junchat-ios/git/ref/tags/release/1.8.1")
        XCTAssertEqual(stub.requests[2].url?.path, "/repos/acme/junchat-ios/git/tags/\(annotatedTagObject)")
        XCTAssertEqual(stub.requests[3].url?.query, "per_page=100&page=2")
        XCTAssertEqual(stub.requests[4].url?.path, "/repos/acme/junchat-ios/git/ref/tags/release/1.7.8")
    }

    func testAuthenticatedGitHubResponsesAreNeverStoredInURLCache() async throws {
        let cache = URLCache(memoryCapacity: 1_000_000,
                             diskCapacity: 0,
                             diskPath: nil)
        let session = GitHubReleaseURLSession(protocolClasses: [CacheableGitHubURLProtocol.self]) {
            $0.urlCache = cache
        }
        CacheableGitHubURLProtocol.reset()
        defer {
            cache.removeAllCachedResponses()
            CacheableGitHubURLProtocol.reset()
        }
        let api = GitHubReleaseAPI(urlSession: session)

        let tags = try await api.publishedReleaseTags(repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                      token: "secret")

        XCTAssertEqual(tags, [])
        let request = try XCTUnwrap(CacheableGitHubURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(cache.cachedResponse(for: request))
    }

    func testDedicatedGitHubSessionUsesAnEphemeralCachelessConfiguration() {
        let session = GitHubReleaseURLSession()

        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy,
                       .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testDedicatedGitHubSessionIsReleasedAfterTheRequestCompletes() async throws {
        weak var weakSession: GitHubReleaseURLSession?
        CacheableGitHubURLProtocol.reset()
        defer { CacheableGitHubURLProtocol.reset() }

        do {
            let session = GitHubReleaseURLSession(protocolClasses: [CacheableGitHubURLProtocol.self])
            weakSession = session
            let api = GitHubReleaseAPI(urlSession: session)

            _ = try await api.publishedReleaseTags(repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                   token: "secret")
        }

        XCTAssertNil(weakSession)
    }

    func testReusesAnExistingMatchingDraftWithoutCreatingAnotherRelease() async throws {
        let targetCommit = String(repeating: "a", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, [releaseRecord(targetCommit: targetCommit)]),
            .json(200, referenceRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit))
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        let requests = stub.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.query, "per_page=100&page=1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertFalse(try XCTUnwrap(requests[0].url?.absoluteString).contains("secret"))
        let tagRequest = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(tagRequest.url?.path, "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2")
    }

    func testExistingDraftSuccessExitRejectsEveryCapturedReleaseRace() async throws {
        let targetCommit = String(repeating: "a", count: 40)

        for defect in capturedDraftRaceDefects(targetCommit: targetCommit) {
            let stub = GitHubHTTPStub(responses: [
                .json(200, [releaseRecord(targetCommit: targetCommit)]),
                .json(200, referenceRecord(commit: targetCommit))
            ] + defect.responses)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected existing-draft \(defect.name) to fail closed")
            } catch { }

            XCTAssertEqual(stub.requests.count, 2 + defect.responses.count)
            XCTAssertEqual(stub.requests.dropFirst(2).first?.url?.path, "/repos/acme/junchat-ios/releases/42")
        }
    }

    func testRevalidatesTheExactDraftAndTagImmediatelyBeforePush() async throws {
        let targetCommit = String(repeating: "a", count: 40)
        let annotatedTagObject = String(repeating: "9", count: 40)
        let draft = GitHubDraftRelease(id: 42,
                                       tagName: "release/1.8.2",
                                       name: "1.8.2",
                                       targetCommitish: targetCommit,
                                       body: "Generated notes",
                                       tagCommit: targetCommit)
        let stub = GitHubHTTPStub(responses: [
            .json(200, releaseRecord(targetCommit: targetCommit)),
            .json(200, referenceRecord(commit: annotatedTagObject, type: "tag")),
            .json(200, tagObjectRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit,
                                               tagObject: annotatedTagObject))
        let api = GitHubReleaseAPI(urlSession: stub)
        var requestsSeenAtPush = 0

        try await api.pushAfterRevalidatingDraft(draft,
                                                 repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                 token: "secret") {
            requestsSeenAtPush = stub.requests.count
        }

        XCTAssertEqual(requestsSeenAtPush, 3)
        XCTAssertEqual(stub.requests[0].url?.path, "/repos/acme/junchat-ios/releases/42")
        XCTAssertEqual(stub.requests[1].url?.path, "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2")
        XCTAssertEqual(stub.requests[2].url?.path, "/repos/acme/junchat-ios/git/tags/\(annotatedTagObject)")
        XCTAssertEqual(stub.requests.count, 6)
    }

    func testSuccessfulAndUncertainPushExitsRejectEveryCapturedReleaseRace() async throws {
        let targetCommit = String(repeating: "a", count: 40)
        let draft = GitHubDraftRelease(id: 42,
                                       tagName: "release/1.8.2",
                                       name: "1.8.2",
                                       targetCommitish: targetCommit,
                                       body: "Generated notes",
                                       tagCommit: targetCommit)

        for pushFails in [false, true] {
            for defect in capturedDraftRaceDefects(targetCommit: targetCommit) {
                let stub = GitHubHTTPStub(responses: [
                    .json(200, releaseRecord(targetCommit: targetCommit)),
                    .json(200, referenceRecord(commit: targetCommit))
                ] + defect.responses)
                let api = GitHubReleaseAPI(urlSession: stub)
                var pushRan = false

                do {
                    try await api.pushAfterRevalidatingDraft(draft,
                                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                             token: "secret") {
                        pushRan = true
                        if pushFails {
                            throw ReleaseRaceTestError.uncertainPush
                        }
                    }
                    XCTFail("Expected \(pushFails ? "uncertain" : "successful") push \(defect.name) to fail closed")
                } catch GitHubReleaseAPI.APIError.incompatibleExistingRelease { } catch GitHubReleaseAPI.APIError.failedRequest(statusCode: 404, message: _) { } catch {
                    XCTFail("Expected a captured release race, got \(error)")
                }

                XCTAssertTrue(pushRan)
                XCTAssertEqual(stub.requests.count, 2 + defect.responses.count)
                XCTAssertEqual(stub.requests.dropFirst(2).first?.url?.path, "/repos/acme/junchat-ios/releases/42")
            }
        }
    }

    func testDraftEditsPublicationDeletionAndTagMovesFailBeforePush() async throws {
        let targetCommit = String(repeating: "a", count: 40)
        let movedCommit = String(repeating: "b", count: 40)
        let draft = GitHubDraftRelease(id: 42,
                                       tagName: "release/1.8.2",
                                       name: "1.8.2",
                                       targetCommitish: targetCommit,
                                       body: "Generated notes",
                                       tagCommit: targetCommit)
        let defects: [(String, [GitHubHTTPStub.Response])] = [
            ("edited release ID", [.json(200, releaseRecord(targetCommit: targetCommit, id: 43))]),
            ("edited body", [.json(200, releaseRecord(targetCommit: targetCommit, body: "Edited notes"))]),
            ("edited name", [.json(200, releaseRecord(targetCommit: targetCommit, name: "Edited release"))]),
            ("edited target", [.json(200, releaseRecord(targetCommit: movedCommit))]),
            ("prerelease draft", [.json(200, releaseRecord(targetCommit: targetCommit, prerelease: true))]),
            ("published draft", [.json(200, releaseRecord(targetCommit: targetCommit,
                                                          draft: false,
                                                          publishedAt: "2026-07-16T00:00:00Z"))]),
            ("deleted draft", [.json(404, ["message": "Not Found"])]),
            ("edited tag", [.json(200, releaseRecord(version: "1.8.3", targetCommit: targetCommit))]),
            ("moved tag", [
                .json(200, releaseRecord(targetCommit: targetCommit)),
                .json(200, referenceRecord(commit: movedCommit))
            ])
        ]

        for (name, responses) in defects {
            let stub = GitHubHTTPStub(responses: responses)
            let api = GitHubReleaseAPI(urlSession: stub)
            var pushRan = false

            do {
                try await api.pushAfterRevalidatingDraft(draft,
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret") {
                    pushRan = true
                }
                XCTFail("Expected \(name) to fail closed")
            } catch { }

            XCTAssertFalse(pushRan, "Push ran after \(name)")
            XCTAssertEqual(stub.requests.first?.url?.path, "/repos/acme/junchat-ios/releases/42")
        }
    }

    func testReusesAnExistingDraftByItsPeeledTagInsteadOfTargetCommitish() async throws {
        let targetCommit = String(repeating: "1", count: 40)
        let tagObject = String(repeating: "2", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, [releaseRecord(targetCommit: "release-candidate")]),
            .json(200, referenceRecord(commit: tagObject, type: "tag")),
            .json(200, tagObjectRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit,
                                               targetCommitish: "release-candidate",
                                               tagObject: tagObject))
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.url?.path), [
            "/repos/acme/junchat-ios/releases",
            "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2",
            "/repos/acme/junchat-ios/git/tags/\(tagObject)",
            "/repos/acme/junchat-ios/releases/42",
            "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2",
            "/repos/acme/junchat-ios/git/tags/\(tagObject)"
        ])
    }

    func testCreatesADraftOnlyWhenNoExistingReleaseMatches() async throws {
        let targetCommit = String(repeating: "b", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(404, ["message": "Not Found"]),
            .json(201, releaseRecord(targetCommit: targetCommit)),
            .json(200, referenceRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit))
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "https://github.com/acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        let requests = stub.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "GET", "GET"])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(payload["draft"] as? Bool, true)
        XCTAssertEqual(payload["target_commitish"] as? String, targetCommit)
        let tagRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(tagRequest.url?.path, "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2")
    }

    func testCreatedDraftMutationExitRejectsEveryCapturedReleaseRace() async throws {
        let targetCommit = String(repeating: "b", count: 40)

        for defect in capturedDraftRaceDefects(targetCommit: targetCommit) {
            let stub = GitHubHTTPStub(responses: [
                .json(200, []),
                .json(404, ["message": "Not Found"]),
                .json(201, releaseRecord(targetCommit: targetCommit)),
                .json(200, referenceRecord(commit: targetCommit))
            ] + defect.responses)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected created-draft \(defect.name) to fail closed")
            } catch { }

            XCTAssertEqual(stub.requests.count, 4 + defect.responses.count)
            XCTAssertEqual(stub.requests.dropFirst(4).first?.url?.path, "/repos/acme/junchat-ios/releases/42")
        }
    }

    func testDraftPostcheckObservesATagCreatedAfterAStalePreflight404() async throws {
        let targetCommit = String(repeating: "b", count: 40)
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: [
            .get("/repos/acme/junchat-ios/releases", query: "per_page=100&page=1"): [
                .json(200, [])
            ],
            .get("/repos/acme/junchat-ios/git/ref/tags/release/1.8.2"): [
                .json(404, ["message": "Not Found"]),
                .json(200, referenceRecord(commit: targetCommit)),
                .json(200, referenceRecord(commit: targetCommit))
            ],
            .get("/repos/acme/junchat-ios/releases/42"): [
                .json(200, releaseRecord(targetCommit: targetCommit))
            ],
            .post("/repos/acme/junchat-ios/releases"): [
                .json(201, releaseRecord(targetCommit: targetCommit))
            ]
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "GET", "GET"])
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
        })
    }

    func testCreatesADraftOnlyWhenItsAnnotatedTagPeelsToTheArchivedCommit() async throws {
        let targetCommit = String(repeating: "3", count: 40)
        let tagObject = String(repeating: "4", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(404, ["message": "Not Found"]),
            .json(201, releaseRecord(targetCommit: targetCommit)),
            .json(200, referenceRecord(commit: tagObject, type: "tag")),
            .json(200, tagObjectRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit,
                                               tagObject: tagObject))
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.url?.path), [
            "/repos/acme/junchat-ios/releases",
            "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2",
            "/repos/acme/junchat-ios/releases",
            "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2",
            "/repos/acme/junchat-ios/git/tags/\(tagObject)",
            "/repos/acme/junchat-ios/releases/42",
            "/repos/acme/junchat-ios/git/ref/tags/release/1.8.2",
            "/repos/acme/junchat-ios/git/tags/\(tagObject)"
        ])
    }

    func testRejectsCreatedDraftWhenActualTagPeelsToAnotherCommit() async throws {
        let targetCommit = String(repeating: "5", count: 40)
        let wrongCommit = String(repeating: "6", count: 40)
        let tagObject = String(repeating: "7", count: 40)
        let tagResponses: [[GitHubHTTPStub.Response]] = [
            [.json(200, referenceRecord(commit: wrongCommit))],
            [
                .json(200, referenceRecord(commit: tagObject, type: "tag")),
                .json(200, tagObjectRecord(commit: wrongCommit))
            ]
        ]

        for tagResponse in tagResponses {
            let stub = GitHubHTTPStub(responses: [
                .json(200, []),
                .json(404, ["message": "Not Found"]),
                .json(201, releaseRecord(targetCommit: targetCommit))
            ] + tagResponse)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected the created draft's actual tag target to fail closed")
            } catch GitHubReleaseAPI.APIError.incompatibleExistingRelease {
                XCTAssertEqual(stub.requests.count, 3 + tagResponse.count)
            }
        }
    }

    func testRejectsAPreexistingMismatchedTagBeforeCreatingADraft() async throws {
        let targetCommit = String(repeating: "5", count: 40)
        let wrongCommit = String(repeating: "6", count: 40)
        let tagObject = String(repeating: "7", count: 40)
        let tagResponses: [[GitHubHTTPStub.Response]] = [
            [.json(200, referenceRecord(commit: wrongCommit))],
            [
                .json(200, referenceRecord(commit: tagObject, type: "tag")),
                .json(200, tagObjectRecord(commit: wrongCommit))
            ]
        ]

        for tagResponse in tagResponses {
            let stub = GitHubHTTPStub(responses: [
                .json(200, [])
            ] + tagResponse)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected a preexisting mismatched tag to fail closed")
            } catch {
                XCTAssertFalse(stub.requests.contains { $0.httpMethod == "POST" })
            }
        }
    }

    func testCreatesADraftWhenAPreexistingAnnotatedTagPeelsToTheArchivedCommit() async throws {
        let targetCommit = String(repeating: "5", count: 40)
        let tagObject = String(repeating: "7", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(200, referenceRecord(commit: tagObject, type: "tag")),
            .json(200, tagObjectRecord(commit: targetCommit)),
            .json(201, releaseRecord(targetCommit: targetCommit)),
            .json(200, referenceRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit))
        let api = GitHubReleaseAPI(urlSession: stub)

        _ = try await api.createOrReuseDraft(version: "1.8.2",
                                             targetCommit: targetCommit,
                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                             token: "secret")

        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "GET", "GET"])
    }

    func testRejectsAnUnreadablePreexistingAnnotatedTagBeforeCreatingADraft() async throws {
        let targetCommit = String(repeating: "5", count: 40)
        let tagObject = String(repeating: "7", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(200, referenceRecord(commit: tagObject, type: "tag")),
            .json(404, ["message": "Not Found"])
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                 targetCommit: targetCommit,
                                                 repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                 token: "secret")
            XCTFail("Expected an unreadable annotated tag to fail closed")
        } catch {
            XCTAssertFalse(stub.requests.contains { $0.httpMethod == "POST" })
        }
    }

    func testRejectsCreatedDraftWhenActualTagIsNotYetReadable() async throws {
        let targetCommit = String(repeating: "8", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(404, ["message": "Not Found"]),
            .json(201, releaseRecord(targetCommit: targetCommit)),
            .json(404, ["message": "Not Found"])
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                 targetCommit: targetCommit,
                                                 repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                 token: "secret")
            XCTFail("Expected a missing post-create tag ref to fail closed")
        } catch GitHubReleaseAPI.APIError.failedRequest(statusCode: 404, message: _) {
            XCTAssertEqual(stub.requests.count, 4)
        }
    }

    func testDoesNotCreateADraftWhenRemotePreparationValidationRequiresAnExistingOne() async throws {
        let targetCommit = String(repeating: "2", count: 40)
        let stub = GitHubHTTPStub(responses: [.json(200, [])])
        let api = GitHubReleaseAPI(urlSession: stub)

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

    func testRejectsAnExistingPublishedOrPrereleaseDraft() async throws {
        let targetCommit = String(repeating: "c", count: 40)
        let invalidRecords = [
            releaseRecord(targetCommit: targetCommit, draft: false),
            releaseRecord(targetCommit: targetCommit, prerelease: true)
        ]

        for record in invalidRecords {
            let stub = GitHubHTTPStub(responses: [.json(200, [record])])
            let api = GitHubReleaseAPI(urlSession: stub)
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

    func testRejectsAnExistingDraftWhoseTagPeelsToAnotherCommit() async throws {
        let targetCommit = String(repeating: "c", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, [releaseRecord(targetCommit: targetCommit)]),
            .json(200, referenceRecord(commit: String(repeating: "d", count: 40)))
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                 targetCommit: targetCommit,
                                                 repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                 token: "secret")
            XCTFail("Expected an existing draft with a mismatched tag to fail closed")
        } catch {
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testSearchesAdditionalReleasePagesBeforeCreating() async throws {
        let targetCommit = String(repeating: "e", count: 40)
        let firstPage = (0..<100).map { index in
            releaseRecord(version: "9.9.\(index)", targetCommit: targetCommit)
        }
        let stub = GitHubHTTPStub(responses: [
            .json(200, firstPage),
            .json(200, [releaseRecord(targetCommit: targetCommit)]),
            .json(200, referenceRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit))
        let api = GitHubReleaseAPI(urlSession: stub)

        _ = try await api.createOrReuseDraft(version: "1.8.2",
                                             targetCommit: targetCommit,
                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                             token: "secret")

        XCTAssertEqual(stub.requests.map { $0.url?.query }, ["per_page=100&page=1", "per_page=100&page=2", "", "", ""])
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET", "GET", "GET", "GET"])
    }

    func testReusesACompatibleDraftCreatedByAConcurrentRetry() async throws {
        let targetCommit = String(repeating: "f", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, []),
            .json(404, ["message": "Not Found"]),
            .json(422, ["message": "already_exists"]),
            .json(200, [releaseRecord(targetCommit: targetCommit)]),
            .json(200, referenceRecord(commit: targetCommit))
        ] + capturedDraftRevalidationResponses(targetCommit: targetCommit))
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "GET", "GET", "GET"])
    }

    func testConcurrentCreateRecoveryExitRejectsEveryCapturedReleaseRace() async throws {
        let targetCommit = String(repeating: "f", count: 40)

        for defect in capturedDraftRaceDefects(targetCommit: targetCommit) {
            let stub = GitHubHTTPStub(responses: [
                .json(200, []),
                .json(404, ["message": "Not Found"]),
                .json(422, ["message": "already_exists"]),
                .json(200, [releaseRecord(targetCommit: targetCommit)]),
                .json(200, referenceRecord(commit: targetCommit))
            ] + defect.responses)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.createOrReuseDraft(version: "1.8.2",
                                                     targetCommit: targetCommit,
                                                     repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                     token: "secret")
                XCTFail("Expected concurrent-create \(defect.name) to fail closed")
            } catch { }

            XCTAssertEqual(stub.requests.count, 5 + defect.responses.count)
            XCTAssertEqual(stub.requests.dropFirst(5).first?.url?.path, "/repos/acme/junchat-ios/releases/42")
        }
    }

    func testRetryAfter422ObservesTheNewDraftAndTagInsteadOfCachedAbsence() async throws {
        let targetCommit = String(repeating: "f", count: 40)
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: [
            .get("/repos/acme/junchat-ios/releases", query: "per_page=100&page=1"): [
                .json(200, []),
                .json(200, [releaseRecord(targetCommit: targetCommit)])
            ],
            .get("/repos/acme/junchat-ios/git/ref/tags/release/1.8.2"): [
                .json(404, ["message": "Not Found"]),
                .json(200, referenceRecord(commit: targetCommit)),
                .json(200, referenceRecord(commit: targetCommit))
            ],
            .get("/repos/acme/junchat-ios/releases/42"): [
                .json(200, releaseRecord(targetCommit: targetCommit))
            ],
            .post("/repos/acme/junchat-ios/releases"): [
                .json(422, ["message": "already_exists"])
            ]
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        let body = try await api.createOrReuseDraft(version: "1.8.2",
                                                    targetCommit: targetCommit,
                                                    repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                    token: "secret")

        XCTAssertEqual(body, "Generated notes")
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "GET", "GET", "GET"])
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
        })
    }

    func testRepeatedBranchVerificationObservesThePostMutationCommit() async throws {
        let archivedCommit = String(repeating: "a", count: 40)
        let preparedCommit = String(repeating: "b", count: 40)
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: [
            .get("/repos/acme/junchat-ios/git/ref/heads/release/ios"): [
                .json(200, referenceRecord(commit: archivedCommit)),
                .json(200, referenceRecord(commit: preparedCommit))
            ]
        ])
        let api = GitHubReleaseAPI(urlSession: stub)
        let repository = try GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git")

        let beforeMutation = try await api.remoteBranchCommit(branch: "release/ios",
                                                              repository: repository,
                                                              token: "secret")
        let afterMutation = try await api.remoteBranchCommit(branch: "release/ios",
                                                             repository: repository,
                                                             token: "secret")

        XCTAssertEqual(beforeMutation, archivedCommit)
        XCTAssertEqual(afterMutation, preparedCommit)
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
        })
    }

    func testRecognizesAnAlreadyPushedPreparationWhenRebuildingTheArchivedCommit() async throws {
        let fixture = try RemotePreparationBlobFixture()
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: fixture.responses())
        let api = GitHubReleaseAPI(urlSession: stub)

        let isPrepared = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                                  releaseVersion: fixture.preparation.releaseVersion,
                                                                  releaseCommit: fixture.releaseCommit,
                                                                  generatedNotes: fixture.generatedNotes,
                                                                  repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                                  token: "secret")

        XCTAssertTrue(isPrepared)
        XCTAssertEqual(stub.requests.count, 12)
        XCTAssertTrue(try XCTUnwrap(stub.requests.first?.url?.absoluteString).contains("heads/release/ios"))
        XCTAssertTrue(stub.requests.dropLast().suffix(2).allSatisfy { $0.url?.path.contains("/git/blobs/") == true })
        XCTAssertEqual(stub.requests.last?.url?.path,
                       "/repos/acme/junchat-ios/git/ref/heads/release/ios")
    }

    func testAlreadyPushedSuccessExitRejectsEveryCapturedReleaseRace() async throws {
        let fixture = try RemotePreparationBlobFixture()
        let draft = GitHubDraftRelease(id: 42,
                                       tagName: "release/1.8.2",
                                       name: "1.8.2",
                                       targetCommitish: fixture.releaseCommit,
                                       body: fixture.generatedNotes,
                                       tagCommit: fixture.releaseCommit)
        let repository = try GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git")
        let branchRoute = CacheAwareGitHubHTTPStub.Route.get("/repos/acme/junchat-ios/git/ref/heads/release/ios")
        let releaseRoute = CacheAwareGitHubHTTPStub.Route.get("/repos/acme/junchat-ios/releases/42")
        let tagRoute = CacheAwareGitHubHTTPStub.Route.get("/repos/acme/junchat-ios/git/ref/tags/release/1.8.2")

        for defect in capturedDraftRaceDefects(targetCommit: fixture.releaseCommit) {
            var responses = fixture.responses()
            responses[branchRoute] = Array(repeating: .json(200, referenceRecord(commit: fixture.preparationCommit)),
                                           count: 4)
            responses[releaseRoute] = [defect.responses[0]]
            if defect.responses.count > 1 {
                responses[tagRoute] = Array(defect.responses.dropFirst())
            }
            let stub = CacheAwareGitHubHTTPStub(responsesByRoute: responses)
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                             releaseVersion: fixture.preparation.releaseVersion,
                                                             releaseCommit: fixture.releaseCommit,
                                                             generatedNotes: fixture.generatedNotes,
                                                             releaseDraft: draft,
                                                             repository: repository,
                                                             token: "secret")
                XCTFail("Expected already-pushed \(defect.name) to fail closed")
            } catch { }

            XCTAssertEqual(stub.requests.filter { $0.url?.path == releaseRoute.path }.count, 1)
        }
    }

    func testAlreadyPushedSuccessExitRequiresStableRepeatedFinalBranchReads() async throws {
        let fixture = try RemotePreparationBlobFixture()
        let draft = GitHubDraftRelease(id: 42,
                                       tagName: "release/1.8.2",
                                       name: "1.8.2",
                                       targetCommitish: fixture.releaseCommit,
                                       body: fixture.generatedNotes,
                                       tagCommit: fixture.releaseCommit)
        var responses = fixture.responses()
        let branchRoute = CacheAwareGitHubHTTPStub.Route.get("/repos/acme/junchat-ios/git/ref/heads/release/ios")
        responses[branchRoute] = [
            .json(200, referenceRecord(commit: fixture.preparationCommit)),
            .json(200, referenceRecord(commit: fixture.preparationCommit)),
            .json(200, referenceRecord(commit: fixture.preparationCommit)),
            .json(200, referenceRecord(commit: String(repeating: "c", count: 40)))
        ]
        responses[.get("/repos/acme/junchat-ios/releases/42")] = [
            .json(200, releaseRecord(targetCommit: fixture.releaseCommit,
                                     body: fixture.generatedNotes))
        ]
        responses[.get("/repos/acme/junchat-ios/git/ref/tags/release/1.8.2")] = [
            .json(200, referenceRecord(commit: fixture.releaseCommit))
        ]
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: responses)
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                         releaseVersion: fixture.preparation.releaseVersion,
                                                         releaseCommit: fixture.releaseCommit,
                                                         generatedNotes: fixture.generatedNotes,
                                                         releaseDraft: draft,
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret")
            XCTFail("Expected the final moving branch read to fail closed")
        } catch GitHubReleaseAPI.APIError.incompatibleExistingPreparation { } catch {
            XCTFail("Expected incompatible preparation, got \(error)")
        }

        XCTAssertEqual(stub.requests.filter { $0.url?.path == branchRoute.path }.count, 4)
    }

    func testRejectsAnAlreadyPushedPreparationWhenTheBranchMovesDuringVerification() async throws {
        let fixture = try RemotePreparationBlobFixture()
        var responses = fixture.responses()
        let branchRoute = CacheAwareGitHubHTTPStub.Route.get("/repos/acme/junchat-ios/git/ref/heads/release/ios")
        responses[branchRoute] = [
            .json(200, referenceRecord(commit: fixture.preparationCommit)),
            .json(200, referenceRecord(commit: String(repeating: "c", count: 40)))
        ]
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: responses)
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                         releaseVersion: fixture.preparation.releaseVersion,
                                                         releaseCommit: fixture.releaseCommit,
                                                         generatedNotes: fixture.generatedNotes,
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret")
            XCTFail("Expected a moving preparation branch to fail closed")
        } catch GitHubReleaseAPI.APIError.incompatibleExistingPreparation { } catch {
            XCTFail("Expected incompatible preparation, got \(error)")
        }

        XCTAssertEqual(stub.requests.filter { $0.url?.path == branchRoute.path }.count, 2)
    }

    func testVerifiesAnXcodeProjectLargerThanOneMiBThroughCommitBoundGitBlobs() async throws {
        let largeReleaseXcodeProject = releaseXcodeProject + String(repeating: "// release padding\n", count: 70000)
        XCTAssertGreaterThan(Data(largeReleaseXcodeProject.utf8).count, 1_048_576)
        let fixture = try RemotePreparationBlobFixture(releaseXcodeProject: largeReleaseXcodeProject)
        let stub = CacheAwareGitHubHTTPStub(responsesByRoute: fixture.responses())
        let api = GitHubReleaseAPI(urlSession: stub)

        let isPrepared = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                                  releaseVersion: fixture.preparation.releaseVersion,
                                                                  releaseCommit: fixture.releaseCommit,
                                                                  generatedNotes: fixture.generatedNotes,
                                                                  repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                                  token: "secret")

        XCTAssertTrue(isPrepared)
        XCTAssertFalse(stub.requests.contains { $0.url?.path.contains("/contents/") == true })
        XCTAssertEqual(stub.requests.filter { $0.url?.path.contains("/git/blobs/") == true }.count, 6)
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData &&
                $0.value(forHTTPHeaderField: "Cache-Control") == "no-store"
        })
    }

    func testRejectsGitBlobIdentitySizeEncodingAndResponseMismatches() async throws {
        for defect in RemotePreparationBlobFixture.BlobDefect.allCases {
            let fixture = try RemotePreparationBlobFixture(blobDefect: defect)
            let stub = CacheAwareGitHubHTTPStub(responsesByRoute: fixture.responses())
            let api = GitHubReleaseAPI(urlSession: stub)

            do {
                _ = try await api.isPreparationAlreadyPushed(branch: "release/ios",
                                                             releaseVersion: fixture.preparation.releaseVersion,
                                                             releaseCommit: fixture.releaseCommit,
                                                             generatedNotes: fixture.generatedNotes,
                                                             repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                             token: "secret")
                XCTFail("Expected the Git Blob defect \(defect) to fail closed")
            } catch { }

            XCTAssertEqual(stub.requests.last?.url?.path, fixture.defectiveBlobPath)
        }
    }

    func testRejectsPreparationWithUnexpectedGitTreeMode() async throws {
        let releaseCommit = String(repeating: "4", count: 40)
        let preparationCommit = String(repeating: "5", count: 40)
        let preparation = try JunchatReleasePreparation(releaseVersion: .init(name: "1.8.2", build: 37),
                                                        releaseCommit: releaseCommit,
                                                        releaseDate: "2026-07-14")
        let stub = GitHubHTTPStub(responses: [
            .json(200, referenceRecord(commit: preparationCommit)),
            .json(200, preparationCommitRecord(commit: preparationCommit,
                                               preparation: preparation)),
            .json(200, preparationTreeRecord(modeOverrides: ["project.yml": "120000"]))
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.isPreparationAlreadyPushed(branch: "junchat",
                                                         releaseVersion: preparation.releaseVersion,
                                                         releaseCommit: releaseCommit,
                                                         generatedNotes: "- Fixed retry",
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret")
            XCTFail("Expected a symlinked preparation file to fail closed")
        } catch {
            XCTAssertEqual(stub.requests.count, 3)
        }
    }

    func testRemoteBranchAtTheArchivedCommitStillNeedsPreparation() async throws {
        let releaseCommit = String(repeating: "c", count: 40)
        let stub = GitHubHTTPStub(responses: [
            .json(200, referenceRecord(commit: releaseCommit))
        ])
        let api = GitHubReleaseAPI(urlSession: stub)

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
        let api = GitHubReleaseAPI(urlSession: stub)

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
            (project: releaseProjectYAML, changelog: preparedChanges, expectedRequests: 7),
            (project: preparedProject, changelog: preparedChanges + "Tampered\n", expectedRequests: 9)
        ]

        for invalidContent in invalidContents {
            let stub = GitHubHTTPStub(responses: preparationVerificationResponses(releaseCommit: releaseCommit,
                                                                                  preparationCommit: preparationCommit,
                                                                                  preparation: preparation,
                                                                                  preparedProject: invalidContent.project,
                                                                                  preparedChangelog: invalidContent.changelog,
                                                                                  preparedXcodeProject: preparedXcodeProject))
            let api = GitHubReleaseAPI(urlSession: stub)

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

    func testRejectsPreparationWithUnexpectedXcodeProjectContent() async throws {
        let releaseCommit = String(repeating: "2", count: 40)
        let preparationCommit = String(repeating: "3", count: 40)
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
        let stub = GitHubHTTPStub(responses: preparationVerificationResponses(releaseCommit: releaseCommit,
                                                                              preparationCommit: preparationCommit,
                                                                              preparation: preparation,
                                                                              preparedProject: preparedProject,
                                                                              preparedChangelog: preparedChanges,
                                                                              preparedXcodeProject: preparedXcodeProject + "Unrelated mutation\n"))
        let api = GitHubReleaseAPI(urlSession: stub)

        do {
            _ = try await api.isPreparationAlreadyPushed(branch: "junchat",
                                                         releaseVersion: releaseVersion,
                                                         releaseCommit: releaseCommit,
                                                         generatedNotes: "- Fixed retry",
                                                         repository: GitHubRepository(remoteURL: "git@github.com:acme/junchat-ios.git"),
                                                         token: "secret")
            XCTFail("Expected modified Xcode project content to fail closed")
        } catch {
            XCTAssertEqual(stub.requests.count, 11)
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

private let releaseXcodeProject = """
buildSettings = {
    CURRENT_PROJECT_VERSION = 37;
    MARKETING_VERSION = 1.8.2;
};
"""

private let preparedXcodeProject = """
buildSettings = {
    CURRENT_PROJECT_VERSION = 38;
    MARKETING_VERSION = 1.8.3;
};
"""

private struct RemotePreparationBlobFixture {
    enum BlobDefect: CaseIterable {
        case sha
        case size
        case encoding
        case bytes
        case responseType
        case httpError
    }

    let releaseCommit = String(repeating: "a", count: 40)
    let preparationCommit = String(repeating: "b", count: 40)
    let generatedNotes = "## Highlights\n- Fixed retry"
    let preparation: JunchatReleasePreparation
    let releaseContents: [String: String]
    let preparedContents: [String: String]
    let blobDefect: BlobDefect?

    init(releaseXcodeProject: String = releaseXcodeProject,
         blobDefect: BlobDefect? = nil) throws {
        preparation = try JunchatReleasePreparation(releaseVersion: .init(name: "1.8.2", build: 37),
                                                    releaseCommit: releaseCommit,
                                                    releaseDate: "2026-07-14")
        releaseContents = [
            JunchatReleasePreparation.projectYAMLPath: releaseProjectYAML,
            JunchatReleasePreparation.changelogPath: releaseChangelog,
            JunchatReleasePreparation.xcodeProjectPath: releaseXcodeProject
        ]
        preparedContents = try [
            JunchatReleasePreparation.projectYAMLPath: preparation.expectedProjectYAML(releaseProjectYAML),
            JunchatReleasePreparation.changelogPath: preparation.expectedChangelog(releaseChangelog,
                                                                                   generatedNotes: generatedNotes),
            JunchatReleasePreparation.xcodeProjectPath: preparation.expectedXcodeProject(releaseXcodeProject)
        ]
        self.blobDefect = blobDefect
    }

    var defectiveBlobPath: String {
        guard let content = preparedContents[JunchatReleasePreparation.xcodeProjectPath] else {
            preconditionFailure("The preparation fixture must include the Xcode project.")
        }
        return "/repos/acme/junchat-ios/git/blobs/\(gitBlobSHA(Data(content.utf8)))"
    }

    func responses() -> [CacheAwareGitHubHTTPStub.Route: [GitHubHTTPStub.Response]] {
        let releaseTree = String(repeating: "7", count: 40)
        var responses: [CacheAwareGitHubHTTPStub.Route: [GitHubHTTPStub.Response]] = [
            .get("/repos/acme/junchat-ios/git/ref/heads/release/ios"): [
                .json(200, referenceRecord(commit: preparationCommit)),
                .json(200, referenceRecord(commit: preparationCommit))
            ],
            .get("/repos/acme/junchat-ios/commits/\(preparationCommit)"): [
                .json(200, preparationCommitRecord(commit: preparationCommit,
                                                   preparation: preparation))
            ],
            .get("/repos/acme/junchat-ios/git/trees/\(preparationTree)", query: "recursive=1"): [
                .json(200, gitTreeRecord(sha: preparationTree, contents: preparedContents))
            ],
            .get("/repos/acme/junchat-ios/git/commits/\(releaseCommit)"): [
                .json(200, gitCommitRecord(sha: releaseCommit, tree: releaseTree))
            ],
            .get("/repos/acme/junchat-ios/git/trees/\(releaseTree)", query: "recursive=1"): [
                .json(200, gitTreeRecord(sha: releaseTree, contents: releaseContents))
            ]
        ]

        for contents in [releaseContents, preparedContents] {
            for path in JunchatReleasePreparation.expectedChangedPaths.sorted() {
                guard let content = contents[path] else {
                    preconditionFailure("The preparation fixture must include every expected path.")
                }
                let sha = gitBlobSHA(Data(content.utf8))
                var response = GitHubHTTPStub.Response.json(200, gitBlobRecord(content))
                if path == JunchatReleasePreparation.xcodeProjectPath,
                   contents == preparedContents,
                   let blobDefect {
                    response = defectiveResponse(blobDefect, content: content, sha: sha)
                }
                responses[.get("/repos/acme/junchat-ios/git/blobs/\(sha)")] = [response]
            }
        }
        return responses
    }

    private func defectiveResponse(_ defect: BlobDefect,
                                   content: String,
                                   sha: String) -> GitHubHTTPStub.Response {
        switch defect {
        case .sha:
            .json(200, gitBlobRecord(content, sha: String(repeating: "f", count: 40)))
        case .size:
            .json(200, gitBlobRecord(content, size: Data(content.utf8).count + 1))
        case .encoding:
            .json(200, gitBlobRecord(content, encoding: "none"))
        case .bytes:
            .json(200, gitBlobRecord("X" + content.dropFirst(),
                                     sha: sha,
                                     size: Data(content.utf8).count))
        case .responseType:
            .data(200, Data(content.utf8))
        case .httpError:
            .json(502, ["message": "Bad Gateway", "sha": sha])
        }
    }
}

private func gitCommitRecord(sha: String, tree: String) -> [String: Any] {
    ["sha": sha, "tree": ["sha": tree]]
}

private func gitTreeRecord(sha: String, contents: [String: String]) -> [String: Any] {
    [
        "sha": sha,
        "truncated": false,
        "tree": contents.keys.sorted().map { path in
            guard let content = contents[path] else {
                preconditionFailure("The tree fixture path must have content.")
            }
            let data = Data(content.utf8)
            return [
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": gitBlobSHA(data),
                "size": data.count
            ] as [String: Any]
        }
    ]
}

private func gitBlobRecord(_ content: String,
                           sha: String? = nil,
                           size: Int? = nil,
                           encoding: String = "base64") -> [String: Any] {
    let data = Data(content.utf8)
    return [
        "sha": sha ?? gitBlobSHA(data),
        "size": size ?? data.count,
        "encoding": encoding,
        "content": data.base64EncodedString()
    ]
}

private func gitBlobSHA(_ data: Data) -> String {
    var object = Data("blob \(data.count)\0".utf8)
    object.append(data)
    return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
}

private let preparationTree = String(repeating: "8", count: 40)

private enum ReleaseRaceTestError: Error {
    case uncertainPush
}

private func capturedDraftRevalidationResponses(targetCommit: String,
                                                targetCommitish: String? = nil,
                                                tagObject: String? = nil) -> [GitHubHTTPStub.Response] {
    var responses: [GitHubHTTPStub.Response] = [
        .json(200, releaseRecord(targetCommit: targetCommitish ?? targetCommit))
    ]
    if let tagObject {
        responses.append(.json(200, referenceRecord(commit: tagObject, type: "tag")))
        responses.append(.json(200, tagObjectRecord(commit: targetCommit)))
    } else {
        responses.append(.json(200, referenceRecord(commit: targetCommit)))
    }
    return responses
}

private func capturedDraftRaceDefects(targetCommit: String) -> [(name: String, responses: [GitHubHTTPStub.Response])] {
    let movedCommit = String(repeating: "e", count: 40)
    return [
        ("publication", [
            .json(200, releaseRecord(targetCommit: targetCommit,
                                     draft: false,
                                     publishedAt: "2026-07-16T00:00:00Z"))
        ]),
        ("edit", [
            .json(200, releaseRecord(targetCommit: targetCommit, body: "Edited notes"))
        ]),
        ("deletion", [
            .json(404, ["message": "Not Found"])
        ]),
        ("tag move", [
            .json(200, releaseRecord(targetCommit: targetCommit)),
            .json(200, referenceRecord(commit: movedCommit))
        ])
    ]
}

private func releaseRecord(version: String = "1.8.2",
                           targetCommit: String,
                           id: Int64 = 42,
                           name: String? = nil,
                           draft: Bool = true,
                           prerelease: Bool = false,
                           publishedAt: String? = nil,
                           tagPrefix: String = "release/",
                           body: String = "Generated notes") -> [String: Any] {
    var record: [String: Any] = [
        "id": id,
        "tag_name": "\(tagPrefix)\(version)",
        "name": name ?? version,
        "target_commitish": targetCommit,
        "body": body,
        "draft": draft,
        "prerelease": prerelease
    ]
    if let publishedAt {
        record["published_at"] = publishedAt
    }
    return record
}

private func referenceRecord(commit: String, type: String = "commit") -> [String: Any] {
    ["object": ["sha": commit, "type": type]]
}

private func tagObjectRecord(commit: String, type: String = "commit") -> [String: Any] {
    ["object": ["sha": commit, "type": type]]
}

private func preparationTreeRecord(modeOverrides: [String: String] = [:]) -> [String: Any] {
    let paths = [
        "ElementX.xcodeproj/project.pbxproj",
        "JUNCHAT_CHANGES.md",
        "project.yml"
    ]
    return [
        "sha": preparationTree,
        "truncated": false,
        "tree": paths.map { path in
            [
                "path": path,
                "mode": modeOverrides[path] ?? "100644",
                "type": "blob",
                "sha": String(repeating: "9", count: 40),
                "size": 1
            ]
        }
    ]
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
        "commit": [
            "message": preparation.commitMessage,
            "tree": ["sha": preparationTree]
        ],
        "parents": [["sha": preparation.releaseCommit]],
        "files": changedPaths.map { ["filename": $0, "status": "modified"] }
    ]
}

private func preparationVerificationResponses(releaseCommit: String,
                                              preparationCommit: String,
                                              preparation: JunchatReleasePreparation,
                                              preparedProject: String,
                                              preparedChangelog: String,
                                              preparedXcodeProject: String) -> [GitHubHTTPStub.Response] {
    let releaseTree = String(repeating: "7", count: 40)
    let releaseContents = [
        JunchatReleasePreparation.projectYAMLPath: releaseProjectYAML,
        JunchatReleasePreparation.changelogPath: releaseChangelog,
        JunchatReleasePreparation.xcodeProjectPath: releaseXcodeProject
    ]
    let preparedContents = [
        JunchatReleasePreparation.projectYAMLPath: preparedProject,
        JunchatReleasePreparation.changelogPath: preparedChangelog,
        JunchatReleasePreparation.xcodeProjectPath: preparedXcodeProject
    ]
    var responses: [GitHubHTTPStub.Response] = [
        .json(200, referenceRecord(commit: preparationCommit)),
        .json(200, preparationCommitRecord(commit: preparationCommit,
                                           preparation: preparation)),
        .json(200, gitTreeRecord(sha: preparationTree, contents: preparedContents)),
        .json(200, gitCommitRecord(sha: releaseCommit, tree: releaseTree)),
        .json(200, gitTreeRecord(sha: releaseTree, contents: releaseContents))
    ]
    for path in [
        JunchatReleasePreparation.projectYAMLPath,
        JunchatReleasePreparation.changelogPath,
        JunchatReleasePreparation.xcodeProjectPath
    ] {
        guard let releaseContent = releaseContents[path],
              let preparedContent = preparedContents[path] else {
            preconditionFailure("The verification fixture must include every expected path.")
        }
        responses.append(.json(200, gitBlobRecord(releaseContent)))
        responses.append(.json(200, gitBlobRecord(preparedContent)))
    }
    return responses
}

private final class GitHubHTTPStub: URLSessionProtocol, @unchecked Sendable {
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

        static func data(_ statusCode: Int, _ data: Data) -> Response {
            Response(statusCode: statusCode, data: data)
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

private final class CacheAwareGitHubHTTPStub: URLSessionProtocol, @unchecked Sendable {
    struct Route: Hashable {
        let method: String
        let path: String
        let query: String?

        static func get(_ path: String, query: String? = nil) -> Route {
            Route(method: "GET", path: path, query: query)
        }

        static func post(_ path: String) -> Route {
            Route(method: "POST", path: path, query: nil)
        }
    }

    private let lock = NSLock()
    private var pendingResponses: [Route: [GitHubHTTPStub.Response]]
    private var cachedResponses = [Route: GitHubHTTPStub.Response]()
    private var recordedRequests = [URLRequest]()

    init(responsesByRoute: [Route: [GitHubHTTPStub.Response]]) {
        pendingResponses = responsesByRoute
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            recordedRequests.append(request)
            let url = try XCTUnwrap(request.url)
            let route = Route(method: request.httpMethod ?? "GET",
                              path: url.path,
                              query: url.query.flatMap { $0.isEmpty ? nil : $0 })
            let response: GitHubHTTPStub.Response
            if request.httpMethod != "POST",
               request.cachePolicy == .useProtocolCachePolicy,
               let cachedResponse = cachedResponses[route] {
                response = cachedResponse
            } else {
                guard var responses = pendingResponses[route], !responses.isEmpty else {
                    throw StubError.missingResponse(route)
                }
                response = responses.removeFirst()
                pendingResponses[route] = responses
                if request.httpMethod != "POST" {
                    cachedResponses[route] = response
                }
            }
            guard let httpResponse = HTTPURLResponse(url: url,
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
        case missingResponse(Route)
    }
}

private class CacheableGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = State()

    static var lastRequest: URLRequest? {
        state.lastRequest
    }

    static func reset() {
        state.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.state.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: [
                                                 "Cache-Control": "public, max-age=3600",
                                                 "Content-Type": "application/json"
                                             ]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedRequest: URLRequest?

        var lastRequest: URLRequest? {
            lock.withLock { recordedRequest }
        }

        func record(_ request: URLRequest) {
            lock.withLock { recordedRequest = request }
        }

        func reset() {
            lock.withLock { recordedRequest = nil }
        }
    }
}
