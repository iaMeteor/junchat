//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@Suite(.serialized)
struct JunchatDiagnosticsUploaderTests {
    private let uploadsURL = URL(string: "https://junchat.example.org/junchat-errors/api/v2/uploads")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var recorder: JunchatDiagnosticsURLProtocolRecorder {
        JunchatDiagnosticsURLProtocol.recorder
    }

    @Test
    func derivesUploadSessionURLWithoutDroppingThePublicPrefix() throws {
        let endpoints = try #require(JunchatDiagnosticsEndpoints(uploadsURL: uploadsURL))

        #expect(endpoints.uploadSessionsURL.absoluteString == "https://junchat.example.org/junchat-errors/api/v2/upload-sessions")
        #expect(endpoints.uploadURL(forServerPath: "/api/v2/uploads") == uploadsURL)
        #expect(endpoints.uploadURL(forServerPath: "https://attacker.example/api/v2/uploads") == nil)
        #expect(endpoints.uploadURL(forServerPath: "/api/v2/uploads?token=secret") == nil)
        #expect(try JunchatDiagnosticsEndpoints(uploadsURL: #require(URL(string: "http://junchat.example.org/api/v2/uploads"))) == nil)
        #expect(try JunchatDiagnosticsEndpoints(uploadsURL: #require(URL(string: "https://junchat.example.org/api/events"))) == nil)
    }

    @Test
    func exchangesTheCurrentMatrixTokenThenUploadsMultipartWithTheShortLivedToken() async throws {
        let uploader = makeUploader()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "short-lived-token",
                                              expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data(#"{"ok":true}"#.utf8))
        ])

        try await uploader.upload(Data(#"{"message":"diagnostic"}"#.utf8)).get()

        let snapshot = recorder.snapshot
        let requests = snapshot.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://junchat.example.org/junchat-errors/api/v2/upload-sessions")
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer matrix-access-token")
        #expect(requests[1].url == uploadsURL)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer short-lived-token")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.contains("matrix-access-token") == false)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try #require(snapshot.requestBodies[1])
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(bodyString.contains(#"name="file"; filename="junchat-error.json""#))
        #expect(bodyString.contains("Content-Type: application/json"))
        #expect(bodyString.contains(#"{"message":"diagnostic"}"#))
        #expect(!bodyString.contains("matrix-access-token"))
        #expect(!bodyString.contains("short-lived-token"))
    }

    @Test
    func readsAFreshMatrixAccessTokenForEveryUpload() async throws {
        let tokens = JunchatDiagnosticsTokenSequence(["first-matrix-token", "second-matrix-token"])
        let uploader = makeUploader { try tokens.next() }
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "first-upload-token",
                                              expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data()),
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "second-upload-token",
                                              expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data())
        ])

        try await uploader.upload(Data("first".utf8)).get()
        try await uploader.upload(Data("second".utf8)).get()

        let requests = recorder.snapshot.requests
        #expect(requests.count == 4)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer first-matrix-token")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer second-matrix-token")
    }

    @Test
    func mapsAuthenticationAndRateLimitResponsesWithoutLeakingCredentials() async {
        let matrixToken = "private-matrix-token"
        let uploader = makeUploader { matrixToken }
        recorder.setResponse(statusCode: 401, data: Data(#"{"error":"matrix_auth_invalid"}"#.utf8))

        let unauthorized = await uploader.upload(Data("payload".utf8))

        #expect(failure(from: unauthorized) == .unauthorized)
        #expect(recorder.snapshot.requestCount == 1)
        #expect(!String(describing: unauthorized).contains(matrixToken))

        recorder.reset()
        recorder.setResponse(statusCode: 429, data: Data(#"{"error":"rate_limited"}"#.utf8))

        let rateLimited = await uploader.upload(Data("payload".utf8))

        #expect(failure(from: rateLimited) == .rateLimited)
        #expect(recorder.snapshot.requestCount == 1)
        #expect(!String(describing: rateLimited).contains(matrixToken))
    }

    @Test
    func mapsUploadAuthenticationAndRateLimitResponses() async {
        let uploader = makeUploader()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "expired-upload-token",
                                              expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 401, data: Data())
        ])
        let unauthorized = await uploader.upload(Data("payload".utf8))
        #expect(failure(from: unauthorized) == .unauthorized)

        recorder.reset()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "limited-upload-token",
                                              expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 429, data: Data())
        ])
        let rateLimited = await uploader.upload(Data("payload".utf8))
        #expect(failure(from: rateLimited) == .rateLimited)
    }

    @Test
    func rejectsMalformedExpiredAndUntrustedUploadSessionsBeforeUploading() async {
        let uploader = makeUploader()
        let invalidResponses = [
            Data(#"{"token":"short-lived-token"}"#.utf8),
            uploadSessionJSON(token: "short-lived-token",
                              expiresAt: now.addingTimeInterval(-1)),
            uploadSessionJSON(token: "short-lived-token",
                              expiresAt: now.addingTimeInterval(300),
                              uploadPath: "https://attacker.example/api/v2/uploads"),
            uploadSessionJSON(token: "invalid token",
                              expiresAt: now.addingTimeInterval(300))
        ]

        for response in invalidResponses {
            recorder.reset()
            recorder.setResponse(statusCode: 201, data: response)

            let result = await uploader.upload(Data("payload".utf8))
            #expect(failure(from: result) == .invalidResponse)
            #expect(recorder.snapshot.requestCount == 1)
        }
    }

    @Test
    func rejectsUnavailableCredentialsAndOversizedSessionResponses() async {
        let unavailableUploader = makeUploader { throw URLError(.userAuthenticationRequired) }
        let unavailable = await unavailableUploader.upload(Data("payload".utf8))
        #expect(failure(from: unavailable) == .sessionUnavailable)
        #expect(recorder.snapshot.requestCount == 0)

        let boundedUploader = makeUploader(maximumResponseSize: 32)
        recorder.setResponse(statusCode: 201, data: Data(repeating: 0x20, count: 33))
        let oversized = await boundedUploader.upload(Data("payload".utf8))
        #expect(failure(from: oversized) == .responseTooLarge)
    }

    private func makeUploader(maximumResponseSize: Int = 4096,
                              accessTokenProvider: @escaping @Sendable () throws -> String = { "matrix-access-token" }) -> JunchatDiagnosticsUploader {
        recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JunchatDiagnosticsURLProtocol.self]
        return JunchatDiagnosticsUploader(uploadsURL: uploadsURL,
                                          accessTokenProvider: accessTokenProvider,
                                          urlSession: URLSession(configuration: configuration),
                                          maximumResponseSize: maximumResponseSize) {
            now
        }
    }

    private func uploadSessionJSON(token: String,
                                   expiresAt: Date,
                                   uploadPath: String = "/api/v2/uploads") -> Data {
        let formatter = ISO8601DateFormatter()
        do {
            return try JSONSerialization.data(withJSONObject: [
                "token": token,
                "expires_at": formatter.string(from: expiresAt),
                "upload_path": uploadPath
            ])
        } catch {
            Issue.record("Failed encoding upload session fixture.")
            return Data()
        }
    }

    private func failure(from result: Result<Void, JunchatDiagnosticsUploadError>) -> JunchatDiagnosticsUploadError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

private final class JunchatDiagnosticsTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !tokens.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return tokens.removeFirst()
    }
}

private final class JunchatDiagnosticsURLProtocolRecorder: @unchecked Sendable {
    enum Result {
        case response(statusCode: Int, data: Data)
    }

    struct Snapshot {
        let requests: [URLRequest]
        let requestBodies: [Data?]
        var requestCount: Int {
            requests.count
        }
    }

    private let lock = NSLock()
    private var response = (statusCode: 200, data: Data())
    private var results = [Result]()
    private var requests = [URLRequest]()
    private var requestBodies = [Data?]()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(requests: requests, requestBodies: requestBodies)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        response = (200, Data())
        results.removeAll()
        requests.removeAll()
        requestBodies.removeAll()
    }

    func setResponse(statusCode: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        response = (statusCode, data)
    }

    func setResults(_ results: [Result]) {
        lock.lock()
        defer { lock.unlock() }
        self.results = results
    }

    func record(_ request: URLRequest) -> (statusCode: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        requestBodies.append(Self.body(from: request))
        if !results.isEmpty {
            switch results.removeFirst() {
            case .response(let statusCode, let data):
                return (statusCode, data)
            }
        }
        return response
    }

    private static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class JunchatDiagnosticsURLProtocol: URLProtocol {
    static let recorder = JunchatDiagnosticsURLProtocolRecorder()

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorded = Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: recorded.statusCode,
                                             httpVersion: nil,
                                             headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: recorded.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
