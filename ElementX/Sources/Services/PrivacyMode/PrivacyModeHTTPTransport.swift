//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct PrivacyModeHTTPTransport: PrivacyModeTransportProtocol {
    private struct ResponseData {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct Payload: Codable {
        let enabled: Bool
    }

    private static let accountDataType = "com.heyujk.junchat.privacy_mode"
    private static let unreservedPathCharacters = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))

    private let homeserverURL: String
    private let userID: String
    private let accessToken: String
    private let urlSession: URLSession
    private let maximumResponseSize: Int

    init(homeserverURL: String,
         userID: String,
         accessToken: String,
         urlSession: URLSession = .shared,
         maximumResponseSize: Int = 4096) {
        self.homeserverURL = homeserverURL
        self.userID = userID
        self.accessToken = accessToken
        self.urlSession = urlSession
        self.maximumResponseSize = max(0, maximumResponseSize)
    }

    func load(roomID: String) async -> Result<PrivacyModeRemoteState, PrivacyModeTransportError> {
        guard let url = accountDataURL(roomID: roomID) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let responseResult = await responseDataWithRetry(for: request)
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in .absent }
        }
        let httpResponse = responseData.response
        if httpResponse.statusCode == 404 {
            return .success(.absent)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            return .failure(.httpStatus(httpResponse.statusCode))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: responseData.data) else {
            return .failure(.malformedResponse)
        }
        return .success(.present(enabled: payload.enabled))
    }

    func setEnabled(_ enabled: Bool, roomID: String) async -> Result<Void, PrivacyModeTransportError> {
        guard let url = accountDataURL(roomID: roomID) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Payload(enabled: enabled))

        let responseResult = await responseDataWithRetry(for: request)
        guard case .success(let responseData) = responseResult else {
            return responseResult.map { _ in () }
        }
        let httpResponse = responseData.response
        guard 200..<300 ~= httpResponse.statusCode else {
            return .failure(.httpStatus(httpResponse.statusCode))
        }
        return .success(())
    }

    private func accountDataURL(roomID: String) -> URL? {
        guard var components = URLComponents(string: homeserverURL),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.host != nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = [basePath, "_matrix", "client", "v3", "user", encoded(userID), "rooms", encoded(roomID), "account_data", encoded(Self.accountDataType)]
            .filter { !$0.isEmpty }
        components.percentEncodedPath = "/" + pathComponents.joined(separator: "/")
        return components.url
    }

    private func encoded(_ pathComponent: String) -> String {
        pathComponent.addingPercentEncoding(withAllowedCharacters: Self.unreservedPathCharacters) ?? ""
    }

    private func responseDataWithRetry(for request: URLRequest) async -> Result<ResponseData, PrivacyModeTransportError> {
        let firstResult = await responseData(for: request)
        guard case .failure(.network) = firstResult, !Task.isCancelled else {
            return firstResult
        }
        return await responseData(for: request)
    }

    private func responseData(for request: URLRequest) async -> Result<ResponseData, PrivacyModeTransportError> {
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
        } catch {
            return .failure(.network)
        }
    }
}
