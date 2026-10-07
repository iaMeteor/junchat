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
        #expect(requests[0].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil)
        #expect(requests[1].url == uploadsURL)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer short-lived-token")
        #expect(requests[1].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil)
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
    func reusesCallSessionUntilThirtySecondExpiryMargin() async throws {
        let clock = JunchatDiagnosticsTestTime(now)
        let uploader = makeUploader(clock: clock)
        recorder.setResults([
            .response(statusCode: 201, data: uploadSessionJSON(token: "cached-call-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: callReceipt),
            .response(statusCode: 200, data: callReceipt),
            .response(statusCode: 201, data: uploadSessionJSON(token: "refreshed-call-token", expiresAt: now.addingTimeInterval(600))),
            .response(statusCode: 200, data: callReceipt)
        ])
        let payload = try callPayload()
        try await uploader.upload(payload).get()
        clock.advance(269)
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requestCount == 3)
        clock.advance(1)
        try await uploader.upload(payload).get()
        let requests = recorder.snapshot.requests
        #expect(requests.map { $0.url?.lastPathComponent } == ["upload-sessions", "uploads", "uploads", "upload-sessions", "uploads"])
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer cached-call-token")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer cached-call-token")
        #expect(requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-call-token")
    }

    @Test
    func changingMatrixTokenInvalidatesCachedCallAuthorization() async throws {
        let credentials = JunchatDiagnosticsTestCredentials("matrix-alice")
        let uploader = makeUploader { try credentials.read() }
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        credentials.replace(with: "matrix-bob")
        recorder.setResults([
            .response(statusCode: 201, data: uploadSessionJSON(token: "bob-call-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: callReceipt)
        ])
        try await uploader.upload(payload).get()
        let requests = recorder.snapshot.requests
        #expect(requests.count == 4)
        #expect(requests[2].url?.lastPathComponent == "upload-sessions")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer matrix-bob")
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer bob-call-token")
    }

    @Test
    func logoutMakesCachedAuthorizationUnusableAndClearsIt() async throws {
        let credentials = JunchatDiagnosticsTestCredentials("matrix-alice")
        let uploader = makeUploader { try credentials.read() }
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        credentials.replace(with: nil)
        #expect(await failure(from: uploader.upload(payload)) == .sessionUnavailable)
        #expect(recorder.snapshot.requestCount == 2)
        credentials.replace(with: "matrix-alice")
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requests.map { $0.url?.lastPathComponent } == ["upload-sessions", "uploads", "upload-sessions", "uploads"])
    }

    @Test(arguments: [200, 401])
    func cached401RefreshesWithMatrixAuthAtMostOnce(_ refreshedUploadStatus: Int) async throws {
        let uploader = makeUploader()
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        recorder.setResults([
            .response(statusCode: 401, data: Data(repeating: 0x20, count: 5000)),
            .response(statusCode: 201, data: uploadSessionJSON(token: "replacement-call-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: refreshedUploadStatus, data: callReceipt)
        ])
        let result = await uploader.upload(payload)
        #expect(failure(from: result) == (refreshedUploadStatus == 200 ? nil : .unauthorized))
        let requests = recorder.snapshot.requests
        try #require(requests.count == 5)
        #expect(requests.map { $0.url?.lastPathComponent } == ["upload-sessions", "uploads", "uploads", "upload-sessions", "uploads"])
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer matrix-access-token")
        #expect(requests[3].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == "call")
        #expect(requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer replacement-call-token")
    }

    @Test
    func accountChangeDuringSessionIssuanceDoesNotUploadOldBatch() async throws {
        let credentials = JunchatDiagnosticsTestCredentials("matrix-alice")
        let uploader = makeUploader { try credentials.read() }
        recorder.setResults(successfulUploadResults(at: now))
        recorder.setRequestHandler { request in
            if request.url?.lastPathComponent == "upload-sessions" { credentials.replace(with: "matrix-bob") }
        }
        #expect(try await failure(from: uploader.upload(callPayload())) == .sessionUnavailable)
        #expect(recorder.snapshot.requestCount == 1)
    }

    @Test
    func accountChangeDuringCached401CannotRefreshUnderNewAccount() async throws {
        let credentials = JunchatDiagnosticsTestCredentials("matrix-alice")
        let uploader = makeUploader { try credentials.read() }
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        recorder.setResponse(statusCode: 401, data: Data())
        recorder.setRequestHandler { _ in credentials.replace(with: "matrix-bob") }
        #expect(await failure(from: uploader.upload(payload)) == .sessionUnavailable)
        #expect(recorder.snapshot.requestCount == 3)
        #expect(recorder.snapshot.requests.last?.url?.lastPathComponent == "uploads")
    }

    @Test
    func genericUploadsNeverReuseOrReplaceCallSession() async throws {
        let uploader = makeUploader()
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        recorder.setResults([
            .response(statusCode: 201, data: uploadSessionJSON(token: "generic-one", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data()),
            .response(statusCode: 201, data: uploadSessionJSON(token: "generic-two", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data()),
            .response(statusCode: 200, data: callReceipt)
        ])
        try await uploader.upload(Data("generic one".utf8)).get()
        try await uploader.upload(Data("generic two".utf8)).get()
        try await uploader.upload(payload).get()
        let requests = recorder.snapshot.requests
        try #require(requests.count == 7)
        #expect(requests[2].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil)
        #expect(requests[4].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil)
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer generic-one")
        #expect(requests[5].value(forHTTPHeaderField: "Authorization") == "Bearer generic-two")
        #expect(requests[6].value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token")
    }

    @Test
    func cached403DoesNotRefresh() async throws {
        let first = makeUploader()
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await first.upload(payload).get()
        recorder.setResponse(statusCode: 403, data: Data())
        #expect(await failure(from: first.upload(payload)) == .unauthorized)
        #expect(recorder.snapshot.requestCount == 3)
    }

    @Test
    func separateLoginDoesNotReuseCachedCallAuthorization() async throws {
        let first = makeUploader()
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await first.upload(payload).get()
        let second = makeUploader()
        recorder.setResults(successfulUploadResults(at: now))
        try await second.upload(payload).get()
        #expect(recorder.snapshot.requests.map { $0.url?.lastPathComponent } == ["upload-sessions", "uploads"])
    }

    @Test
    func cancelledCallUploadCannotUseCachedAuthorization() async throws {
        let uploader = makeUploader()
        let payload = try callPayload()
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await uploader.upload(payload)
        }
        #expect(await failure(from: task.value) == .cancelled)
        #expect(recorder.snapshot.requestCount == 2)
    }

    @Test
    func requestsCallPurposeOnlyForTheSessionAndPreservesOpaqueUploadTokenAndPayload() async throws {
        let uploader = makeUploader()
        let payload = try callPayload()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "opaque-call-upload-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data(#"{"ok":true,"call_diagnostics":{"accepted":1,"duplicates":0}}"#.utf8))
        ])

        try await uploader.upload(payload).get()

        let snapshot = recorder.snapshot
        #expect(snapshot.requests.count == 2)
        #expect(snapshot.requests[0].url?.path == "/junchat-errors/api/v2/upload-sessions")
        #expect(snapshot.requests[0].httpBody == nil)
        #expect(snapshot.requests[0].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == "call")
        #expect(snapshot.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer matrix-access-token")
        #expect(snapshot.requests[1].url == uploadsURL)
        #expect(snapshot.requests[1].value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil)
        #expect(snapshot.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer opaque-call-upload-token")
        let body = try #require(snapshot.requestBodies[1])
        #expect(body.range(of: payload) != nil)
    }

    @Test(arguments: [
        #"{"ok":true}"#,
        #"{}"#,
        #"{"ok":false,"call_diagnostics":{"accepted":1,"duplicates":0}}"#,
        #"{"ok":1,"call_diagnostics":{"accepted":1,"duplicates":0}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":1}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":0,"duplicates":0}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":2,"duplicates":0}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":-1,"duplicates":2}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":0.5,"duplicates":0.5}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":true,"duplicates":0}}"#,
        #"{"ok":true,"call_diagnostics":{"accepted":9223372036854775807,"duplicates":1}}"#,
        "not JSON"
    ])
    func requiresMatchingTypedIndexingReceiptForCallPayload(_ response: String) async throws {
        let uploader = makeUploader()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "call-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data(response.utf8))
        ])
        let result = try await uploader.upload(callPayload())
        #expect(failure(from: result) == .invalidResponse)
        #expect(recorder.snapshot.requestCount == 2)
    }

    @Test(arguments: [0, 1, 2])
    func acceptsIndexedAndDuplicateCallReceiptCounts(_ accepted: Int) async throws {
        let uploader = makeUploader()
        let receipt = "{\"ok\":true,\"call_diagnostics\":{\"accepted\":\(accepted),\"duplicates\":\(2 - accepted)}}"
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "call-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data(receipt.utf8))
        ])
        try await uploader.upload(callPayload(eventCount: 2)).get()
        #expect(recorder.snapshot.requestCount == 2)
    }

    @Test(arguments: [
        #"{"message":"generic","context":{"schema":"junchat.call-diagnostics.v1"}}"#,
        #"[{"schema":"junchat.call-diagnostics.v1"}]"#,
        #"{"schema":"junchat.call-diagnostics.v2"}"#,
        #"{"schema":"junchat.call-diagnostics.v1 "}"#,
        #"{"schema":true}"#,
        #"{"schema":null}"#,
        #"{"schema":"junchat.call-diagnostics.v1""#,
        "opaque generic payload"
    ])
    func doesNotRequestCallPurposeForGenericOrNonmatchingSchema(_ payload: String) async throws {
        let uploader = makeUploader()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "generic-upload-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 200, data: Data())
        ])

        try await uploader.upload(Data(payload.utf8)).get()

        let requests = recorder.snapshot.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose") == nil })
    }

    @Test
    func callUpload429DoesNotRetryForAnHourAndDoesNotBlockGenericReports() async throws {
        let clock = JunchatDiagnosticsTestTime(now)
        let uploader = makeUploader(clock: clock)
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "call-token", expiresAt: clock.now.addingTimeInterval(300))),
            .response(statusCode: 429, data: Data(), headers: ["Retry-After": "3600"])
        ])
        let payload = try callPayload()
        #expect(await failure(from: uploader.upload(payload)) == .rateLimited)
        #expect(recorder.snapshot.requestCount == 2)

        recorder.setResults(successfulUploadResults(at: clock.now))
        try await uploader.upload(Data(#"{"message":"generic"}"#.utf8)).get()
        #expect(recorder.snapshot.requestCount == 4)
        clock.advance(3599)
        #expect(await failure(from: uploader.upload(payload)) == .rateLimited)
        #expect(recorder.snapshot.requestCount == 4)
        clock.advance(1)
        recorder.setResults(successfulUploadResults(at: clock.now))
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requestCount == 6)
    }

    @Test(arguments: [429, 503])
    func honorsSessionRetryAfterAndBoundsExcessiveDelays(_ statusCode: Int) async throws {
        let clock = JunchatDiagnosticsTestTime(now)
        let uploader = makeUploader(clock: clock)
        recorder.setResponse(statusCode: statusCode, data: Data(), headers: ["Retry-After": "99999999"])
        let payload = try callPayload()
        #expect(await failure(from: uploader.upload(payload)) != nil)
        clock.advance(3599)
        #expect(await failure(from: uploader.upload(payload)) == .rateLimited)
        #expect(recorder.snapshot.requestCount == 1)
        clock.advance(1)
        recorder.setResults(successfulUploadResults(at: clock.now))
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requestCount == 3)
    }

    @Test
    func honorsHTTPDateRetryAfterEvenWhenErrorResponseBodyIsTooLarge() async throws {
        let clock = JunchatDiagnosticsTestTime(now)
        let uploader = makeUploader(clock: clock)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        recorder.setResponse(statusCode: 503, data: Data(repeating: 0x20, count: 5000),
                             headers: ["Retry-After": formatter.string(from: clock.now.addingTimeInterval(120))])
        let payload = try callPayload()
        #expect(await failure(from: uploader.upload(payload)) == .responseTooLarge)
        clock.advance(119)
        #expect(await failure(from: uploader.upload(payload)) == .rateLimited)
        #expect(recorder.snapshot.requestCount == 1)
        clock.advance(1)
        recorder.setResults(successfulUploadResults(at: clock.now))
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requestCount == 3)
    }

    @Test(arguments: ["-1", "not a date", "NaN", "", "0"])
    func invalidRetryAfterCannotPermanentlySuppressReports(_ header: String) async throws {
        let uploader = makeUploader()
        recorder.setResponse(statusCode: 429, data: Data(), headers: ["Retry-After": header])
        let payload = try callPayload()
        #expect(await failure(from: uploader.upload(payload)) == .rateLimited)
        recorder.setResults(successfulUploadResults(at: now))
        try await uploader.upload(payload).get()
        #expect(recorder.snapshot.requestCount == 3)
    }

    @Test(arguments: [0, 65])
    func rejectsInvalidCallBatchCountsBeforeIssuingTokens(_ count: Int) async throws {
        let uploader = makeUploader()
        #expect(try await failure(from: uploader.upload(callPayload(eventCount: count))) == .invalidResponse)
        #expect(recorder.snapshot.requestCount == 0)
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
    func distinguishesMissingV2EndpointsWithoutForwardingResponseContents() async {
        let uploader = makeUploader()
        recorder.setResponse(statusCode: 404, data: Data("private-endpoint-details".utf8))
        let missingSessionEndpoint = await uploader.upload(Data("payload".utf8))
        #expect(failure(from: missingSessionEndpoint) == .endpointNotFound)
        #expect(recorder.snapshot.requestCount == 1)
        #expect(!String(describing: missingSessionEndpoint).contains("private-endpoint-details"))

        recorder.reset()
        recorder.setResults([
            .response(statusCode: 201,
                      data: uploadSessionJSON(token: "short-lived-token", expiresAt: now.addingTimeInterval(300))),
            .response(statusCode: 404, data: Data("private-upload-details".utf8))
        ])
        let missingUploadEndpoint = await uploader.upload(Data("payload".utf8))
        #expect(failure(from: missingUploadEndpoint) == .endpointNotFound)
        #expect(recorder.snapshot.requestCount == 2)
        #expect(!String(describing: missingUploadEndpoint).contains("private-upload-details"))
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
                              clock: JunchatDiagnosticsTestTime? = nil,
                              accessTokenProvider: @escaping @Sendable () throws -> String = { "matrix-access-token" }) -> JunchatDiagnosticsUploader {
        recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JunchatDiagnosticsURLProtocol.self]
        return JunchatDiagnosticsUploader(uploadsURL: uploadsURL,
                                          accessTokenProvider: accessTokenProvider,
                                          urlSession: URLSession(configuration: configuration),
                                          maximumResponseSize: maximumResponseSize) {
            clock?.now ?? now
        }
    }

    private func successfulUploadResults(at date: Date) -> [JunchatDiagnosticsURLProtocolRecorder.Result] {
        [.response(statusCode: 201,
                   data: uploadSessionJSON(token: "opaque-token", expiresAt: date.addingTimeInterval(300))),
         .response(statusCode: 200, data: Data(#"{"ok":true,"call_diagnostics":{"accepted":1,"duplicates":0}}"#.utf8))]
    }

    private var callReceipt: Data {
        Data(#"{"ok":true,"call_diagnostics":{"accepted":1,"duplicates":0}}"#.utf8)
    }

    private func callPayload(eventCount: Int = 1) throws -> Data {
        let events: [[String: Any]] = (0..<eventCount).map { index in
            ["session_id": "ade7a7ad-a151-4b1e-9368-58c0d6a0c862", "sequence": index + 1,
             "occurred_at": "2026-10-07T12:00:00Z", "component": "ios", "stage": "capture",
             "status": "failed", "code": "capture_failed", "source": "microphone"]
        }
        return try JSONSerialization.data(withJSONObject: ["schema": "junchat.call-diagnostics.v1", "platform": "ios",
                                                           "app_version": "2.0.1", "build": "58", "events": events])
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
        case response(statusCode: Int, data: Data, headers: [String: String] = [:])
    }

    struct Snapshot {
        let requests: [URLRequest]
        let requestBodies: [Data?]
        var requestCount: Int {
            requests.count
        }
    }

    struct Response {
        let statusCode: Int
        let data: Data
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var response = Response(statusCode: 200, data: Data())
    private var results = [Result]()
    private var requests = [URLRequest]()
    private var requestBodies = [Data?]()
    private var requestHandler: (@Sendable (URLRequest) -> Void)?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(requests: requests, requestBodies: requestBodies)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        response = Response(statusCode: 200, data: Data())
        results.removeAll()
        requests.removeAll()
        requestBodies.removeAll()
        requestHandler = nil
    }

    func setRequestHandler(_ handler: @escaping @Sendable (URLRequest) -> Void) {
        lock.withLock { requestHandler = handler }
    }

    func setResponse(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        response = Response(statusCode: statusCode, data: data, headers: headers)
    }

    func setResults(_ results: [Result]) {
        lock.lock()
        defer { lock.unlock() }
        self.results = results
    }

    func record(_ request: URLRequest) -> Response {
        lock.lock()
        let handler = requestHandler
        defer {
            lock.unlock()
            handler?(request)
        }
        requests.append(request)
        requestBodies.append(Self.body(from: request))
        if !results.isEmpty {
            switch results.removeFirst() {
            case .response(let statusCode, let data, let headers):
                return Response(statusCode: statusCode, data: data, headers: headers)
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
                                             headerFields: recorded.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: recorded.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class JunchatDiagnosticsTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

private final class JunchatDiagnosticsTestCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ token: String) {
        self.token = token
    }

    func read() throws -> String {
        try lock.withLock {
            guard let token else { throw URLError(.userAuthenticationRequired) }
            return token
        }
    }

    func replace(with token: String?) {
        lock.withLock { self.token = token }
    }
}
