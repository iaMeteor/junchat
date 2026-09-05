//
// Copyright 2026 Element Creations Ltd.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

@MainActor
struct JunchatRoomMembershipServiceTests {
    private let session = Session(accessToken: "test-token", refreshToken: nil, userId: "@alice:example.org", deviceId: "DEVICE",
                                  homeserverUrl: "https://matrix.example.org/prefix/", oauthData: nil, slidingSyncVersion: .native)
    private let roomID = "!room:example.org"

    private func payload(membership: String = "not_member", userID: String = "@alice:example.org") -> Data {
        let eventID = membership == "not_member" ? "null" : "\"$membership-event\""
        return Data("""
        {"user_id":"\(userID)","rooms":{"\(roomID)":{"membership":"\(membership)","event_id":\(eventID)}}}
        """.utf8)
    }

    @Test(arguments: ["join", "invite", "knock", "leave", "ban", "not_member"])
    func exactBoundedRequestAndMembershipStates(_ membership: String) async {
        let session = session
        let roomID = roomID
        let data = payload(membership: membership)
        let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/prefix/_matrix/client/v3/junchat/room_membership")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.timeoutInterval == 10)
            let body = try #require(request.httpBody)
            #expect(try JSONSerialization.jsonObject(with: body) as? [String: [String]] == ["room_ids": [roomID]])
            let url = try #require(request.url)
            return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        #expect(await reader.memberships(for: [roomID]) == [roomID: membership == "join"])
        #expect(await reader.memberships(for: []) == nil)
    }

    @Test(arguments: [401, 403, 404, 429, 500])
    func errorsNeverAuthorizeSuppression(_ status: Int) async {
        let session = session
        let data = payload()
        let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { request in
            let url = try #require(request.url)
            return try (data, #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        })
        #expect(await reader.memberships(for: [roomID]) == nil)
    }

    @Test
    func incompleteUnknownAndWrongAccountResponsesAreRejected() async {
        let session = session
        for data in [payload(userID: "@bob:example.org"), payload(membership: "unknown"),
                     Data("{\"user_id\":\"@alice:example.org\",\"rooms\":{}}".utf8)] {
            let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { request in
                let url = try #require(request.url)
                return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
            #expect(await reader.memberships(for: [roomID]) == nil)
        }
    }

    @Test
    func suppressionPersistsUntilAuthenticatedRejoinAndLogout() async throws {
        let suite = "JunchatRoomMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = session
        let data = payload()
        let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { request in
            let url = try #require(request.url)
            return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let service = JunchatRoomMembershipService(userID: session.userId, reader: reader, defaults: defaults)
        await service.refresh([roomID])
        #expect(service.excludedRoomIDs == [roomID])
        let restored = JunchatRoomMembershipService(userID: session.userId, reader: reader, defaults: defaults)
        #expect(restored.excludedRoomIDs == [roomID])
        let other = JunchatRoomMembershipService(userID: "@bob:example.org", reader: reader, defaults: defaults)
        #expect(other.excludedRoomIDs.isEmpty)
        await other.refresh([roomID])
        #expect(other.excludedRoomIDs.isEmpty)
        restored.didJoin(roomID)
        #expect(restored.excludedRoomIDs.isEmpty)
        await restored.refresh([roomID], force: true)
        restored.stopAndClear()
        #expect(JunchatRoomMembershipService(userID: session.userId, reader: reader, defaults: defaults).excludedRoomIDs.isEmpty)
    }

    @Test
    func disabledRolloutMakesNoRequestsButRetainsConfirmedSuppression() async throws {
        let suite = "JunchatRoomMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([roomID], forKey: "junchat.roomMembership.excluded.v1.\(session.userId)")
        let reader = JunchatRoomMembershipReader {
            Issue.record("Disabled reconciliation must not read the SDK session")
            throw URLError(.userAuthenticationRequired)
        }
        let service = JunchatRoomMembershipService(userID: session.userId, reader: reader, defaults: defaults, isEnabled: false)
        await service.refresh([roomID], force: true)
        #expect(service.excludedRoomIDs == [roomID])
    }

    @Test(arguments: [true, false])
    func redirectedAndOversizedResponsesAreRejected(_ redirect: Bool) async {
        let session = session
        let data = payload()
        let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { request in
            let url = try #require(redirect ? URL(string: "https://other.example.org/") : request.url)
            return try (redirect ? data : Data(repeating: 0, count: 131_073),
                        #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        #expect(await reader.memberships(for: [roomID]) == nil)
    }

    @Test
    func replacedCredentialsCannotRemoveRooms() async {
        var replacement = session
        replacement.accessToken = "replacement-token"
        let sessions = MembershipSessionSequence([session, replacement])
        let data = payload()
        let reader = JunchatRoomMembershipReader(sessionProvider: { try sessions.next() }, send: { request in
            let url = try #require(request.url)
            return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        #expect(await reader.memberships(for: [roomID]) == nil)
    }

    @Test(arguments: [true, false])
    func lateRemovalDoesNotUndoRejoinOrLogout(_ rejoin: Bool) async throws {
        let suite = "JunchatRoomMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = session
        let gate = MembershipResponseGate()
        let reader = JunchatRoomMembershipReader(sessionProvider: { session }, send: { try await gate.send($0) })
        let service = JunchatRoomMembershipService(userID: session.userId, reader: reader, defaults: defaults)
        let task = Task { await service.refresh([roomID]) }
        await gate.waitUntilRequested()
        if rejoin {
            service.didJoin(roomID)
        } else {
            service.stopAndClear()
        }
        try await gate.respond(payload())
        await task.value
        #expect(service.excludedRoomIDs.isEmpty)
    }
}

private final class MembershipSessionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [Session]

    init(_ sessions: [Session]) {
        self.sessions = sessions
    }

    func next() throws -> Session {
        lock.lock()
        defer { lock.unlock() }
        guard !sessions.isEmpty else { throw URLError(.userAuthenticationRequired) }
        return sessions.removeFirst()
    }
}

private actor MembershipResponseGate {
    private var request: URLRequest?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func respond(_ data: Data) throws {
        let url = try #require(request?.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        continuation?.resume(returning: (data, response))
        continuation = nil
    }
}
