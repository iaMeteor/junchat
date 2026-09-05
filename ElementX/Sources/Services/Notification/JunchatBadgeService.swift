//
// Copyright 2026 Element Creations Ltd.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

struct JunchatBadgeService {
    let sessionProvider: @Sendable () throws -> Session
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request, delegate: JunchatBadgeRedirectPolicy())
    }

    func snapshot() async -> NotificationBadgeServerSnapshot? {
        do {
            let session = try sessionProvider()
            guard let baseURL = URL(string: session.homeserverUrl),
                  baseURL.scheme == "https", baseURL.host != nil,
                  baseURL.user == nil, baseURL.password == nil else { return nil }
            let url = baseURL.appending(path: "_matrix/client/v3/junchat/badge")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await send(request)
            let currentSession = try sessionProvider()
            guard !Task.isCancelled,
                  currentSession.userId == session.userId,
                  currentSession.deviceId == session.deviceId,
                  currentSession.homeserverUrl == session.homeserverUrl,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200, response.url == url,
                  data.count <= 16384,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let snapshot = NotificationBadgeServerSnapshot(payload: payload),
                  snapshot.userID == session.userId else { return nil }
            return snapshot
        } catch {
            // A timeout, old server, or malformed response is not a zero count.
            return nil
        }
    }
}

private final class JunchatBadgeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
