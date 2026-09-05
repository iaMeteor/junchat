//
// Copyright 2026 Element Creations Ltd.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

struct JunchatRoomMembershipReader {
    let sessionProvider: @Sendable () throws -> Session
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request, delegate: RoomMembershipRedirectPolicy())
    }

    func memberships(for roomIDs: Set<String>, expectedUserID: String? = nil) async -> [String: Bool]? {
        guard !roomIDs.isEmpty, roomIDs.count <= 100 else { return nil }
        do {
            let session = try sessionProvider()
            guard expectedUserID == nil || session.userId == expectedUserID else { return nil }
            guard let baseURL = URL(string: session.homeserverUrl), baseURL.scheme == "https",
                  baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
                  baseURL.query == nil, baseURL.fragment == nil else { return nil }
            let url = baseURL.appending(path: "_matrix/client/v3/junchat/room_membership")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["room_ids": roomIDs.sorted()])
            let (data, response) = try await send(request)
            let current = try sessionProvider()
            guard !Task.isCancelled, current.userId == session.userId,
                  current.deviceId == session.deviceId, current.accessToken == session.accessToken,
                  current.homeserverUrl == session.homeserverUrl,
                  let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url,
                  data.count <= 131_072,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["user_id"] as? String == session.userId,
                  let rooms = payload["rooms"] as? [String: [String: Any]], Set(rooms.keys) == roomIDs else { return nil }
            var result = [String: Bool]()
            for (id, room) in rooms {
                guard let membership = room["membership"] as? String else { return nil }
                switch membership {
                case "join", "invite", "knock", "leave", "ban":
                    guard let eventID = room["event_id"] as? String, eventID.hasPrefix("$"), eventID.count > 1 else { return nil }
                    result[id] = membership == "join"
                case "not_member":
                    guard room["event_id"] is NSNull else { return nil }
                    result[id] = false
                default:
                    return nil
                }
            }
            return result
        } catch {
            return nil
        }
    }
}

/// Suppresses only stale joined-room representations; invitations remain visible.
@MainActor
final class JunchatRoomMembershipService {
    private let reader: JunchatRoomMembershipReader
    private let defaults: UserDefaults
    private let key: String
    private let userID: String
    private let isEnabled: Bool
    private let excludedSubject: CurrentValueSubject<Set<String>, Never>
    private var requestIDs = [String: UUID]()
    private var lastRefresh = [String: Date]()
    private var stopped = false

    var excludedRoomIDs: Set<String> {
        excludedSubject.value
    }

    var excludedRoomIDsPublisher: CurrentValuePublisher<Set<String>, Never> {
        excludedSubject.asCurrentValuePublisher()
    }

    init(userID: String, reader: JunchatRoomMembershipReader,
         defaults: UserDefaults = AppSettings.sharedUserDefaults, isEnabled: Bool = true) {
        self.reader = reader
        self.userID = userID
        self.defaults = defaults
        self.isEnabled = isEnabled
        key = "junchat.roomMembership.excluded.v1.\(userID)"
        excludedSubject = .init(Set(defaults.stringArray(forKey: key) ?? []))
    }

    func refresh(_ roomIDs: Set<String>, force: Bool = false) async {
        guard isEnabled, !stopped else { return }
        let now = Date()
        let candidates = roomIDs.filter { force || now.timeIntervalSince(lastRefresh[$0] ?? .distantPast) >= 30 }.sorted()
        for offset in stride(from: 0, to: candidates.count, by: 100) {
            guard !stopped, !Task.isCancelled else { return }
            let ids = Set(candidates[offset..<min(offset + 100, candidates.count)])
            let requestID = UUID()
            for id in ids {
                requestIDs[id] = requestID
                lastRefresh[id] = now
            }
            guard let memberships = await reader.memberships(for: ids, expectedUserID: userID), !stopped, !Task.isCancelled else { continue }
            var excluded = excludedRoomIDs
            for (id, joined) in memberships where requestIDs[id] == requestID {
                if joined {
                    excluded.remove(id)
                } else {
                    excluded.insert(id)
                }
            }
            publish(excluded)
        }
    }

    func didJoin(_ roomID: String) {
        guard !stopped else { return }
        requestIDs[roomID] = UUID()
        lastRefresh.removeValue(forKey: roomID)
        var excluded = excludedRoomIDs
        excluded.remove(roomID)
        publish(excluded)
    }

    func stopAndClear() {
        stopped = true
        requestIDs.removeAll()
        lastRefresh.removeAll()
        defaults.removeObject(forKey: key)
        excludedSubject.send([])
    }

    private func publish(_ ids: Set<String>) {
        guard ids != excludedRoomIDs else { return }
        defaults.set(ids.sorted(), forKey: key)
        excludedSubject.send(ids)
    }
}

private final class RoomMembershipRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
