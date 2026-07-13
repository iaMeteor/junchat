//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@Suite(.serialized)
struct JunchatContactsServiceTests {
    private var recorder: JunchatContactsURLProtocolRecorder {
        JunchatContactsURLProtocol.recorder
    }

    @Test
    func productionClientInitializerUsesSDKSession() async throws {
        recorder.reset()
        let client = ClientSDKMock()
        client.sessionReturnValue = makeSession(token: "client-token")
        let service = JunchatContactsService(client: client, urlSession: makeURLSession())
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([("@alice:example.org", "Alice")]))

        let contacts = try await service.contacts().get()

        #expect(contacts.map(\.userID) == ["@alice:example.org"])
        #expect(client.sessionCallsCount == 1)
    }

    @Test
    func resolvesPrefixedHomeserverAndPaginatesWithFreshAuthentication() async throws {
        let sessions = SessionSequence([
            makeSession(token: "first-token", homeserverURL: "https://matrix.example.org/prefix/"),
            makeSession(token: "second-token", homeserverURL: "https://matrix.example.org/prefix/")
        ])
        let service = makeService(sessionProvider: { try sessions.next() }, pageSize: 2)
        recorder.setResults([
            .response(statusCode: 200, data: contactsJSON([("@alice:example.org", "Alice")], nextBatch: "next /+?")),
            .response(statusCode: 200, data: contactsJSON([("@bob:example.org", "Bob")]))
        ])

        let contacts = try await service.contacts().get()

        #expect(contacts.map(\.userID) == ["@alice:example.org", "@bob:example.org"])
        let requests = recorder.snapshot.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/prefix/_matrix/client/v3/junchat/contacts")
        #expect(try URLComponents(url: #require(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems == [
            .init(name: "limit", value: "2")
        ])
        #expect(try URLComponents(url: #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems == [
            .init(name: "limit", value: "2"),
            .init(name: "from", value: "next /+?")
        ])
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer second-token")
    }

    @Test
    func followsNextBatchForEmptyAndShortPages() async throws {
        let service = makeService(pageSize: 2)
        recorder.setResults([
            .response(statusCode: 200, data: contactsJSON([], nextBatch: "after-empty")),
            .response(statusCode: 200, data: contactsJSON([("@alice:example.org", "Alice")], nextBatch: "after-short")),
            .response(statusCode: 200, data: contactsJSON([("@bob:example.org", "Bob")]))
        ])

        let contacts = try await service.contacts().get()

        #expect(contacts.map(\.userID) == ["@alice:example.org", "@bob:example.org"])
        #expect(recorder.snapshot.requestCount == 3)
    }

    @Test
    func rejectsMaximumPageCount() async {
        let limits = JunchatContactsServiceLimits(pageSize: 1, maximumPageCount: 2)
        let service = makeService(limits: limits)
        recorder.setResults([
            .response(statusCode: 200, data: contactsJSON([], nextBatch: "second")),
            .response(statusCode: 200, data: contactsJSON([], nextBatch: "third"))
        ])

        await expectFailure(service.contacts(), .invalidPagination)
        #expect(recorder.snapshot.requestCount == 2)
    }

    @Test
    func rejectsAccountChangesBeforeSendingTheNextCursor() async {
        let sessions = SessionSequence([
            makeSession(token: "first-token"),
            makeSession(token: "second-token",
                        userID: "@other:elsewhere.org",
                        homeserverURL: "https://elsewhere.org")
        ])
        let service = makeService(sessionProvider: { try sessions.next() }, pageSize: 1)
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([("@alice:example.org", "Alice")], nextBatch: "private-cursor"))

        await expectFailure(service.contacts(), .invalidResponse)
        #expect(recorder.snapshot.requestCount == 1)
    }

    @Test
    func acceptsBoundedLegacyCompleteListWithoutNextBatch() async throws {
        let service = makeService(pageSize: 2)
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([
                                 ("@alice:example.org", "Alice"),
                                 ("@bob:example.org", "Bob"),
                                 ("@charlie:example.org", "Charlie")
                             ]))

        let contacts = try await service.contacts().get()

        #expect(contacts.count == 3)
        #expect(recorder.snapshot.requestCount == 1)
    }

    @Test
    func rejectsOversizedPaginatedPageAndCursorLoops() async {
        let service = makeService(pageSize: 1)
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([
                                 ("@alice:example.org", "Alice"),
                                 ("@bob:example.org", "Bob")
                             ], nextBatch: "next"))
        await expectFailure(service.contacts(), .malformedResponse)

        recorder.reset()
        recorder.setResults([
            .response(statusCode: 200, data: contactsJSON([("@alice:example.org", "Alice")], nextBatch: "loop")),
            .response(statusCode: 200, data: contactsJSON([("@bob:example.org", "Bob")], nextBatch: "loop"))
        ])
        await expectFailure(service.contacts(), .invalidPagination)

        recorder.reset()
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([], nextBatch: String(repeating: "c", count: 4097)))
        await expectFailure(service.contacts(), .invalidPagination)
    }

    @Test
    func enforcesAggregateResponseAndContactFieldLimits() async {
        let limits = JunchatContactsServiceLimits(pageSize: 1,
                                                  maximumPageCount: 3,
                                                  maximumPageResponseSize: 512,
                                                  maximumLegacyResponseSize: 512,
                                                  maximumAggregateResponseSize: 140,
                                                  maximumRawContactCount: 5,
                                                  maximumUniqueContactCount: 5,
                                                  maximumCursorSize: 128,
                                                  maximumUserIDSize: 64,
                                                  maximumDisplayNameSize: 16,
                                                  maximumAvatarURLSize: 128)
        let service = makeService(limits: limits)
        recorder.setResults([
            .response(statusCode: 200, data: contactsJSON([("@alice:example.org", "Alice")], nextBatch: "second")),
            .response(statusCode: 200, data: contactsJSON([("@bob:example.org", "Bob")]))
        ])
        await expectFailure(service.contacts(), .responseTooLarge)

        recorder.reset()
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([("@alice:example.org", String(repeating: "A", count: 17))]))
        await expectFailure(service.contacts(), .malformedResponse)
    }

    @Test
    func enforcesRawAndUniqueContactCounts() async {
        let rawLimitedService = makeService(limits: .init(maximumRawContactCount: 2,
                                                          maximumUniqueContactCount: 3))
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([
                                 ("@alice:example.org", "Alice"),
                                 ("@alice:example.org", "Duplicate"),
                                 ("@alice:example.org", "Duplicate Again")
                             ]))
        await expectFailure(rawLimitedService.contacts(), .responseTooLarge)

        let uniqueLimitedService = makeService(limits: .init(maximumRawContactCount: 3,
                                                             maximumUniqueContactCount: 2))
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([
                                 ("@alice:example.org", "Alice"),
                                 ("@bob:example.org", "Bob"),
                                 ("@charlie:example.org", "Charlie")
                             ]))
        await expectFailure(uniqueLimitedService.contacts(), .responseTooLarge)
    }

    @Test
    func rejectsDeclaredAndStreamedBodiesOverLimit() async {
        let maximumBodySize = 128
        let limits = JunchatContactsServiceLimits(maximumPageResponseSize: maximumBodySize,
                                                  maximumLegacyResponseSize: maximumBodySize,
                                                  maximumAggregateResponseSize: 1024)
        let service = makeService(limits: limits)
        recorder.setResponse(statusCode: 200,
                             data: contactsJSON([]),
                             headerFields: ["Content-Length": String(maximumBodySize + 1)])
        await expectFailure(service.contacts(), .responseTooLarge)

        var streamedBody = contactsJSON([])
        streamedBody.append(Data(repeating: 0x20, count: maximumBodySize))
        recorder.setResponse(statusCode: 200, data: streamedBody)
        await expectFailure(service.contacts(), .responseTooLarge)
        #expect(recorder.snapshot.requestCount == 2)
    }

    @Test
    func rejectsMalformedJSON() async {
        let service = makeService()
        recorder.setResponse(statusCode: 200, data: Data(#"{"contacts":["#.utf8))

        await expectFailure(service.contacts(), .malformedResponse)
    }

    @Test
    func rejectsInvalidHomeserverURLBeforeRequest() async {
        let service = makeService {
            makeSession(token: "secret-token", homeserverURL: "not a URL")
        }

        await expectFailure(service.contacts(), .invalidURL)
        #expect(recorder.snapshot.requestCount == 0)
    }

    @Test
    func mapsSessionProviderFailures() async {
        let service = makeService { throw URLError(.userAuthenticationRequired) }

        await expectFailure(service.contacts(), .network)
        #expect(recorder.snapshot.requestCount == 0)
    }

    @Test
    func rejectsNonHTTPResponses() async {
        let service = makeService()
        recorder.setResults([.nonHTTPResponse(data: contactsJSON([]))])

        await expectFailure(service.contacts(), .invalidResponse)
    }

    @Test
    func filtersInvalidContactsAndDeduplicatesUserIDs() async throws {
        let service = makeService()
        recorder.setResponse(statusCode: 200,
                             data: Data(#"""
                             {
                                 "contacts": [
                                     {"user_id":"not-a-matrix-id","display_name":"Invalid"},
                                     {"user_id":"@alice:example.org","display_name":"Alice"},
                                     {"user_id":"@alice:example.org","display_name":"Duplicate"},
                                     {"user_id":"@bob:example.org","display_name":"Bob","avatar_url":"not a url"}
                                 ]
                             }
                             """#.utf8))

        let contacts = try await service.contacts().get()

        #expect(contacts.map(\.userID) == ["@alice:example.org", "@bob:example.org"])
        #expect(contacts.last?.avatarURL == nil)
    }

    @Test
    func retriesUnauthorizedRequestOnlyWhenTokenChanged() async throws {
        let sessions = SessionSequence([
            makeSession(token: "expired-token"),
            makeSession(token: "fresh-token")
        ])
        let service = makeService { try sessions.next() }
        recorder.setResults([
            .response(statusCode: 401, data: Data(repeating: 0x20, count: 4096)),
            .response(statusCode: 200, data: contactsJSON([("@alice:example.org", "Alice")]))
        ])

        #expect(try await service.contacts().get().count == 1)
        #expect(recorder.snapshot.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer expired-token", "Bearer fresh-token"
        ])

        recorder.reset()
        let unchangedService = makeService()
        recorder.setResponse(statusCode: 401, data: Data(repeating: 0x20, count: 4096))
        await expectFailure(unchangedService.contacts(), .unauthorized)
        #expect(recorder.snapshot.requestCount == 1)
    }

    @Test
    func cancellationStopsAnInFlightContactsRequest() async throws {
        let service = makeService()
        recorder.setResults([.pending])

        let task = Task { await service.contacts() }
        try await waitForRequestCount(1)
        task.cancel()

        await expectFailure(task.value, .cancelled)
        #expect(recorder.snapshot.stopLoadingCount == 1)
    }

    @Test
    func visibilityUsesExactStatusSemanticsWithoutReadingSuccessfulPutBody() async throws {
        let service = makeService()
        recorder.setResponse(statusCode: 404, data: Data(repeating: 0x20, count: 4096))
        #expect(await service.isHiddenFromDirectory() == .success(false))

        recorder.setResponse(statusCode: 200, data: Data(#"{"hidden":true}"#.utf8))
        #expect(await service.isHiddenFromDirectory() == .success(true))

        recorder.setResponse(statusCode: 204, data: Data(repeating: 0x20, count: 128 * 1024))
        await expectSuccess(service.setHiddenFromDirectory(false))
        let request = try #require(recorder.snapshot.lastRequest)
        #expect(request.httpMethod == "PUT")
        #expect(recorder.snapshot.lastRequestBody == Data(#"{"hidden":false}"#.utf8))
    }

    @Test
    func mapsVisibilityAuthenticationRateLimitAndServerFailuresByStatus() async {
        let service = makeService()
        recorder.setResponse(statusCode: 401, data: Data(repeating: 0x20, count: 4096))
        #expect(await service.isHiddenFromDirectory() == .failure(.unauthorized))

        recorder.setResponse(statusCode: 429, data: Data(repeating: 0x20, count: 4096))
        #expect(await service.isHiddenFromDirectory() == .failure(.rateLimited))

        recorder.setResponse(statusCode: 503, data: Data(repeating: 0x20, count: 4096))
        await expectFailure(service.setHiddenFromDirectory(true), .httpStatus(503))
    }

    @Test
    func mapsErrorsThroughClientProxyContract() {
        guard case .invalidServerName = ClientProxy.clientProxyError(for: .invalidURL) else {
            Issue.record("Expected invalidURL to map to invalidServerName.")
            return
        }
        guard case .forbiddenAccess = ClientProxy.clientProxyError(for: .unauthorized) else {
            Issue.record("Expected unauthorized to map to forbiddenAccess.")
            return
        }

        for serviceError in [JunchatContactsServiceError.cancelled, .network] {
            guard case .sdkError(let underlyingError) = ClientProxy.clientProxyError(for: serviceError),
                  let mappedError = underlyingError as? JunchatContactsServiceError else {
                Issue.record("Expected \(serviceError) to map to sdkError.")
                continue
            }
            #expect(mappedError == serviceError)
        }

        let invalidResponseErrors: [JunchatContactsServiceError] = [
            .httpStatus(500),
            .invalidPagination,
            .invalidResponse,
            .malformedResponse,
            .rateLimited,
            .responseTooLarge
        ]
        for serviceError in invalidResponseErrors {
            guard case .invalidResponse = ClientProxy.clientProxyError(for: serviceError) else {
                Issue.record("Expected \(serviceError) to map to invalidResponse.")
                continue
            }
        }
    }

    private func makeService(sessionProvider: (@Sendable () throws -> Session)? = nil,
                             pageSize: Int = 100,
                             limits: JunchatContactsServiceLimits? = nil) -> JunchatContactsService {
        recorder.reset()
        let resolvedLimits = limits ?? .init(pageSize: pageSize)
        let resolvedSessionProvider = sessionProvider ?? { makeSession(token: "secret-token") }
        return JunchatContactsService(sessionProvider: resolvedSessionProvider,
                                      urlSession: makeURLSession(),
                                      limits: resolvedLimits)
    }

    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JunchatContactsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitForRequestCount(_ expectedCount: Int) async throws {
        for _ in 0..<100 where recorder.snapshot.requestCount < expectedCount {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.snapshot.requestCount == expectedCount)
    }
}

private func makeSession(token: String,
                         userID: String = "@me:example.org",
                         homeserverURL: String = "https://matrix.example.org") -> Session {
    Session(accessToken: token,
            refreshToken: nil,
            userId: userID,
            deviceId: "DEVICE",
            homeserverUrl: homeserverURL,
            oauthData: nil,
            slidingSyncVersion: .native)
}

private func contactsJSON(_ contacts: [(String, String)], nextBatch: String? = nil) -> Data {
    var payload: [String: Any] = [
        "contacts": contacts.map { ["user_id": $0.0, "display_name": $0.1] }
    ]
    payload["next_batch"] = nextBatch
    do {
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    } catch {
        Issue.record("Failed building contacts fixture: \(error)")
        return Data()
    }
}

private func expectFailure<Success>(_ result: Result<Success, JunchatContactsServiceError>,
                                    _ expectedError: JunchatContactsServiceError) {
    guard case .failure(let error) = result else {
        Issue.record("Expected failure \(expectedError), got success.")
        return
    }
    #expect(error == expectedError)
}

private func expectSuccess(_ result: Result<Void, JunchatContactsServiceError>) {
    guard case .success = result else {
        Issue.record("Expected success, got \(result).")
        return
    }
}

private final class SessionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [Session]

    init(_ sessions: [Session]) {
        self.sessions = sessions
    }

    func next() throws -> Session {
        lock.lock()
        defer { lock.unlock() }
        guard !sessions.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        if sessions.count == 1 {
            return sessions[0]
        }
        return sessions.removeFirst()
    }
}

private final class JunchatContactsURLProtocolRecorder: @unchecked Sendable {
    enum Result {
        case pending
        case response(statusCode: Int, data: Data, headerFields: [String: String]? = nil)
        case nonHTTPResponse(data: Data)
    }

    struct Snapshot {
        let requests: [URLRequest]
        let requestBodies: [Data?]
        let stopLoadingCount: Int

        var requestCount: Int {
            requests.count
        }

        var lastRequest: URLRequest? {
            requests.last
        }

        var lastRequestBody: Data? {
            requestBodies.last ?? nil
        }
    }

    private struct StubResponse {
        let statusCode: Int
        let data: Data
        let headerFields: [String: String]?
    }

    private let lock = NSLock()
    private var response = StubResponse(statusCode: 200, data: Data(), headerFields: nil)
    private var results = [Result]()
    private var requests = [URLRequest]()
    private var requestBodies = [Data?]()
    private var stopLoadingCount = 0

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(requests: requests,
                        requestBodies: requestBodies,
                        stopLoadingCount: stopLoadingCount)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        response = StubResponse(statusCode: 200, data: Data(), headerFields: nil)
        results.removeAll()
        requests.removeAll()
        requestBodies.removeAll()
        stopLoadingCount = 0
    }

    func setResponse(statusCode: Int, data: Data, headerFields: [String: String]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        response = StubResponse(statusCode: statusCode, data: data, headerFields: headerFields)
        results.removeAll()
    }

    func setResults(_ results: [Result]) {
        lock.lock()
        defer { lock.unlock() }
        self.results = results
    }

    func record(_ request: URLRequest) -> Result {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        requestBodies.append(Self.bodyData(for: request))
        guard !results.isEmpty else {
            return .response(statusCode: response.statusCode,
                             data: response.data,
                             headerFields: response.headerFields)
        }
        return results.removeFirst()
    }

    func recordStopLoading() {
        lock.lock()
        defer { lock.unlock() }
        stopLoadingCount += 1
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class JunchatContactsURLProtocol: URLProtocol {
    static let recorder = JunchatContactsURLProtocolRecorder()

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.recorder.record(request) {
        case .pending:
            return
        case .response(let statusCode, let data, let headerFields):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url,
                                                 statusCode: statusCode,
                                                 httpVersion: nil,
                                                 headerFields: headerFields) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .nonHTTPResponse(let data):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = URLResponse(url: url,
                                       mimeType: "application/json",
                                       expectedContentLength: data.count,
                                       textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.recorder.recordStopLoading()
    }
}
