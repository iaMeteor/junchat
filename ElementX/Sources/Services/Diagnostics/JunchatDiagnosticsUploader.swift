//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

enum JunchatDiagnosticsUploadError: Error, Equatable {
    case cancelled
    case endpointNotFound
    case invalidEndpoint
    case invalidResponse
    case network
    case rateLimited
    case responseTooLarge
    case sessionUnavailable
    case unauthorized
}

protocol JunchatDiagnosticsUploading: Sendable {
    func upload(_ payload: Data) async -> Result<Void, JunchatDiagnosticsUploadError>
}

protocol JunchatDiagnosticsProviding {
    var junchatDiagnosticsUploader: JunchatDiagnosticsUploading { get }
}

struct JunchatDiagnosticsEndpoints: Equatable {
    private static let uploadsPath = "/api/v2/uploads"
    private static let uploadSessionsPath = "/api/v2/upload-sessions"

    let uploadsURL: URL
    let uploadSessionsURL: URL

    init?(uploadsURL: URL) {
        guard var components = URLComponents(url: uploadsURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.hasSuffix(Self.uploadsPath) else {
            return nil
        }

        let publicPrefix = components.percentEncodedPath.dropLast(Self.uploadsPath.count)
        guard publicPrefix.isEmpty || (publicPrefix.first == "/" && publicPrefix.last != "/") else {
            return nil
        }

        self.uploadsURL = uploadsURL
        components.percentEncodedPath = publicPrefix + Self.uploadSessionsPath
        guard let uploadSessionsURL = components.url else {
            return nil
        }
        self.uploadSessionsURL = uploadSessionsURL
    }

    func uploadURL(forServerPath path: String) -> URL? {
        guard let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == Self.uploadsPath else {
            return nil
        }
        return uploadsURL
    }
}

struct JunchatDiagnosticsUploader: JunchatDiagnosticsUploading {
    private enum Purpose: Hashable { case generic, call }

    private actor RetryAfterGate {
        private var deadlines: [Purpose: Date] = [:]

        func isCoolingDown(_ purpose: Purpose, now: Date) -> Bool {
            guard let deadline = deadlines[purpose] else { return false }
            if deadline > now { return true }
            deadlines.removeValue(forKey: purpose)
            return false
        }

        func postpone(_ purpose: Purpose, until deadline: Date) {
            deadlines[purpose] = max(deadlines[purpose] ?? deadline, deadline)
        }
    }

    private struct ResponseData {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct UploadSession: Decodable {
        let token: String
        let expiresAt: String
        let uploadPath: String

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
            case uploadPath = "upload_path"
        }
    }

    private struct ValidatedUploadSession {
        let token: String
        let expiresAt: Date
        let uploadURL: URL
    }

    private actor CallSessionCache {
        private var entry: (session: ValidatedUploadSession, binding: Data)?

        func session(for binding: Data, now: Date) -> ValidatedUploadSession? {
            guard let entry else { return nil }
            guard entry.binding == binding, entry.session.expiresAt > now.addingTimeInterval(30) else {
                self.entry = nil
                return nil
            }
            return entry.session
        }

        func store(_ session: ValidatedUploadSession, binding: Data) {
            entry = (session, binding)
        }

        func invalidate(binding: Data? = nil, token: String? = nil) {
            guard binding == nil || entry?.binding == binding,
                  token == nil || entry?.session.token == token else { return }
            entry = nil
        }
    }

    private struct CallUploadReceipt: Decodable {
        struct Counts: Decodable {
            let accepted: Int
            let duplicates: Int
        }

        let ok: Bool
        let callDiagnostics: Counts

        enum CodingKeys: String, CodingKey {
            case ok
            case callDiagnostics = "call_diagnostics"
        }

        func acknowledges(_ count: Int) -> Bool {
            ok && (0...count).contains(callDiagnostics.accepted) &&
                (0...count).contains(callDiagnostics.duplicates) &&
                callDiagnostics.accepted + callDiagnostics.duplicates == count
        }
    }

    private let endpoints: JunchatDiagnosticsEndpoints?
    private let accessTokenProvider: @Sendable () throws -> String
    private let urlSession: URLSession
    private let maximumResponseSize: Int
    private let now: @Sendable () -> Date
    private let retryAfterGate = RetryAfterGate()
    private let callSessionCache = CallSessionCache()

    init(uploadsURL: URL,
         accessTokenProvider: @escaping @Sendable () throws -> String,
         urlSession: URLSession = .shared,
         maximumResponseSize: Int = 4096,
         now: @escaping @Sendable () -> Date = { Date() }) {
        endpoints = JunchatDiagnosticsEndpoints(uploadsURL: uploadsURL)
        self.accessTokenProvider = accessTokenProvider
        self.urlSession = urlSession
        self.maximumResponseSize = max(0, maximumResponseSize)
        self.now = now
    }

    func upload(_ payload: Data) async -> Result<Void, JunchatDiagnosticsUploadError> {
        guard let endpoints else {
            return .failure(.invalidEndpoint)
        }

        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let purpose: Purpose = object?["schema"] as? String == "junchat.call-diagnostics.v1" ? .call : .generic
        let expectedEventCount = purpose == .call ? (object?["events"] as? [Any])?.count : nil
        guard purpose == .generic || (1...64).contains(expectedEventCount ?? 0) else {
            return .failure(.invalidResponse)
        }
        if let expectedEventCount {
            return await uploadCall(payload, eventCount: expectedEventCount, endpoints: endpoints)
        }
        let uploadSessionResult = await requestUploadSession(from: endpoints.uploadSessionsURL, purpose: purpose)
        guard case .success(let uploadSession) = uploadSessionResult else {
            return uploadSessionResult.map { _ in () }
        }
        guard let session = validated(uploadSession, endpoints: endpoints) else {
            return .failure(.invalidResponse)
        }

        let result = await upload(payload,
                                  to: session.uploadURL,
                                  uploadToken: session.token,
                                  purpose: purpose,
                                  expectedEventCount: nil)
        return result.result
    }

    private func uploadCall(_ payload: Data, eventCount: Int, endpoints: JunchatDiagnosticsEndpoints) async -> Result<Void, JunchatDiagnosticsUploadError> {
        guard !Task.isCancelled else {
            await callSessionCache.invalidate()
            return .failure(.cancelled)
        }
        guard let matrixToken = currentMatrixToken() else {
            await callSessionCache.invalidate()
            return .failure(.sessionUnavailable)
        }
        let binding = Self.binding(for: matrixToken)
        let cached = await callSessionCache.session(for: binding, now: now())
        let sessionResult: Result<ValidatedUploadSession, JunchatDiagnosticsUploadError>
        if let cached {
            sessionResult = .success(cached)
        } else {
            sessionResult = await freshCallSession(endpoints: endpoints, matrixToken: matrixToken, binding: binding)
        }
        guard case .success(let session) = sessionResult else { return sessionResult.map { _ in () } }
        let first = await sendCall(payload, eventCount: eventCount, session: session, binding: binding)
        guard first.statusCode == 401, cached != nil else { return first.result }

        // A cached bearer may be revoked before its expiry. Refresh exactly once
        // with the original Matrix identity, never under a newly switched account.
        let refreshed = await freshCallSession(endpoints: endpoints, matrixToken: matrixToken, binding: binding)
        guard case .success(let session) = refreshed else { return refreshed.map { _ in () } }
        let second = await sendCall(payload, eventCount: eventCount, session: session, binding: binding)
        return second.result
    }

    private func freshCallSession(endpoints: JunchatDiagnosticsEndpoints,
                                  matrixToken: String,
                                  binding: Data) async -> Result<ValidatedUploadSession, JunchatDiagnosticsUploadError> {
        let result = await requestUploadSession(from: endpoints.uploadSessionsURL, purpose: .call, providedMatrixToken: matrixToken)
        guard case .success(let rawSession) = result else {
            return result.flatMap { _ in .failure(.invalidResponse) }
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard currentBinding() == binding else {
            await callSessionCache.invalidate(binding: binding)
            return .failure(.sessionUnavailable)
        }
        guard let session = validated(rawSession, endpoints: endpoints) else { return .failure(.invalidResponse) }
        await callSessionCache.store(session, binding: binding)
        return .success(session)
    }

    private func sendCall(_ payload: Data,
                          eventCount: Int,
                          session: ValidatedUploadSession,
                          binding: Data) async -> (result: Result<Void, JunchatDiagnosticsUploadError>, statusCode: Int?) {
        let response = await upload(payload, to: session.uploadURL, uploadToken: session.token, purpose: .call,
                                    expectedEventCount: eventCount, expectedBinding: binding)
        if case .failure(let error) = response.result, [.unauthorized, .sessionUnavailable, .cancelled].contains(error) {
            await callSessionCache.invalidate(binding: binding, token: session.token)
        }
        return response
    }

    private func validated(_ session: UploadSession, endpoints: JunchatDiagnosticsEndpoints) -> ValidatedUploadSession? {
        guard Self.isValidBearerToken(session.token),
              let expiresAt = ISO8601DateFormatter().date(from: session.expiresAt), expiresAt > now(),
              let uploadURL = endpoints.uploadURL(forServerPath: session.uploadPath) else { return nil }
        return ValidatedUploadSession(token: session.token, expiresAt: expiresAt, uploadURL: uploadURL)
    }

    private func currentMatrixToken() -> String? {
        guard let token = try? accessTokenProvider(), Self.isValidBearerToken(token) else { return nil }
        return token
    }

    private static func binding(for token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func currentBinding() -> Data? {
        currentMatrixToken().map(Self.binding)
    }

    private func requestUploadSession(from url: URL,
                                      purpose: Purpose,
                                      providedMatrixToken: String? = nil) async -> Result<UploadSession, JunchatDiagnosticsUploadError> {
        let matrixAccessToken: String
        do {
            matrixAccessToken = try providedMatrixToken ?? accessTokenProvider()
        } catch {
            return .failure(.sessionUnavailable)
        }
        guard Self.isValidBearerToken(matrixAccessToken) else {
            return .failure(.sessionUnavailable)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(matrixAccessToken)", forHTTPHeaderField: "Authorization")
        if purpose == .call {
            request.setValue("call", forHTTPHeaderField: "X-JunChat-Diagnostics-Purpose")
        }

        let responseResult = await responseData(for: request, purpose: purpose,
                                                expectedBinding: purpose == .call ? Self.binding(for: matrixAccessToken) : nil)
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in
                UploadSession(token: "", expiresAt: "", uploadPath: "")
            }
        }
        guard responseData.response.statusCode == 201 else {
            return .failure(error(for: responseData.response.statusCode))
        }
        guard let session = try? JSONDecoder().decode(UploadSession.self, from: responseData.data) else {
            return .failure(.invalidResponse)
        }
        return .success(session)
    }

    private func upload(_ payload: Data,
                        to url: URL,
                        uploadToken: String,
                        purpose: Purpose,
                        expectedEventCount: Int?,
                        expectedBinding: Data? = nil) async -> (result: Result<Void, JunchatDiagnosticsUploadError>, statusCode: Int?) {
        let boundary = "JunchatDiagnostics-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.multipartBody(payload: payload, boundary: boundary)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let responseResult = await responseData(for: request, purpose: purpose, expectedBinding: expectedBinding)
        guard case .success(let responseData) = responseResult else {
            return (responseResult.map { _ in () }, nil)
        }
        guard 200..<300 ~= responseData.response.statusCode else {
            return (.failure(error(for: responseData.response.statusCode)), responseData.response.statusCode)
        }
        if let expectedEventCount {
            guard let receipt = try? JSONDecoder().decode(CallUploadReceipt.self, from: responseData.data),
                  receipt.acknowledges(expectedEventCount) else {
                return (.failure(.invalidResponse), responseData.response.statusCode)
            }
        }
        return (.success(()), responseData.response.statusCode)
    }

    private func preflightError(purpose: Purpose, expectedBinding: Data?) async -> JunchatDiagnosticsUploadError? {
        guard !Task.isCancelled else { return .cancelled }
        guard await !(retryAfterGate.isCoolingDown(purpose, now: now())) else { return .rateLimited }
        guard !Task.isCancelled else { return .cancelled }
        if let expectedBinding, currentBinding() != expectedBinding {
            await callSessionCache.invalidate(binding: expectedBinding)
            return .sessionUnavailable
        }
        return nil
    }

    private func responseData(for request: URLRequest, purpose: Purpose, expectedBinding: Data? = nil) async -> Result<ResponseData, JunchatDiagnosticsUploadError> {
        if let error = await preflightError(purpose: purpose, expectedBinding: expectedBinding) { return .failure(error) }
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            if let deadline = Self.retryDeadline(for: httpResponse, now: now()) {
                await retryAfterGate.postpone(purpose, until: deadline)
            }
            if purpose == .call, httpResponse.statusCode == 401 {
                // Only the rejection status is needed to discard a cached token.
                // Never consume an arbitrary authentication error body.
                return .success(.init(data: Data(), response: httpResponse))
            }
            guard httpResponse.expectedContentLength <= Int64(maximumResponseSize) || httpResponse.expectedContentLength < 0 else {
                return .failure(.responseTooLarge)
            }

            var data = Data()
            data.reserveCapacity(min(maximumResponseSize, max(0, Int(httpResponse.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumResponseSize else {
                    return .failure(.responseTooLarge)
                }
                data.append(byte)
            }
            return .success(.init(data: data, response: httpResponse))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }

    private static func retryDeadline(for response: HTTPURLResponse, now: Date) -> Date? {
        guard [429, 503].contains(response.statusCode),
              let header = response.value(forHTTPHeaderField: "Retry-After"), header.utf8.count <= 128 else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds: TimeInterval?
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
            seconds = TimeInterval(value)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.isLenient = false
            seconds = formatter.date(from: value)?.timeIntervalSince(now)
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        // Keep the server's one-hour capacity denial without unbounded suppression.
        return now.addingTimeInterval(min(seconds, 3600))
    }

    private func error(for statusCode: Int) -> JunchatDiagnosticsUploadError {
        switch statusCode {
        case 401, 403:
            .unauthorized
        case 404:
            .endpointNotFound
        case 429:
            .rateLimited
        default:
            .invalidResponse
        }
    }

    private static func multipartBody(payload: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"junchat-error.json\"\r\n".utf8))
        body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func isValidBearerToken(_ token: String) -> Bool {
        !token.isEmpty &&
            token.utf8.count <= 16 * 1024 &&
            token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            token.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
