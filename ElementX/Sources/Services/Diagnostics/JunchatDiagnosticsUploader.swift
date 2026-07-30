//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum JunchatDiagnosticsUploadError: Error, Equatable {
    case cancelled
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

    private let endpoints: JunchatDiagnosticsEndpoints?
    private let accessTokenProvider: @Sendable () throws -> String
    private let urlSession: URLSession
    private let maximumResponseSize: Int
    private let now: @Sendable () -> Date

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

        let uploadSessionResult = await requestUploadSession(from: endpoints.uploadSessionsURL)
        guard case .success(let uploadSession) = uploadSessionResult else {
            return uploadSessionResult.map { _ in () }
        }
        guard Self.isValidBearerToken(uploadSession.token),
              let expiresAt = ISO8601DateFormatter().date(from: uploadSession.expiresAt),
              expiresAt > now(),
              let uploadURL = endpoints.uploadURL(forServerPath: uploadSession.uploadPath) else {
            return .failure(.invalidResponse)
        }

        return await upload(payload,
                            to: uploadURL,
                            uploadToken: uploadSession.token)
    }

    private func requestUploadSession(from url: URL) async -> Result<UploadSession, JunchatDiagnosticsUploadError> {
        let matrixAccessToken: String
        do {
            matrixAccessToken = try accessTokenProvider()
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

        let responseResult = await responseData(for: request)
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
                        uploadToken: String) async -> Result<Void, JunchatDiagnosticsUploadError> {
        let boundary = "JunchatDiagnostics-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.multipartBody(payload: payload, boundary: boundary)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let responseResult = await responseData(for: request)
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in () }
        }
        guard 200..<300 ~= responseData.response.statusCode else {
            return .failure(error(for: responseData.response.statusCode))
        }
        return .success(())
    }

    private func responseData(for request: URLRequest) async -> Result<ResponseData, JunchatDiagnosticsUploadError> {
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
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

    private func error(for statusCode: Int) -> JunchatDiagnosticsUploadError {
        switch statusCode {
        case 401, 403:
            .unauthorized
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
