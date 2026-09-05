//
// Copyright 2026 Element Creations Ltd.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

struct JunchatBadgeServiceTests {
    private func session(userID: String = "@alice:example.org") -> Session {
        Session(accessToken: "test-token", refreshToken: nil, userId: userID, deviceId: "DEVICE",
                homeserverUrl: "https://matrix.example.org/prefix/", oauthData: nil, slidingSyncVersion: .native)
    }

    private func payload(userID: String = "@alice:example.org") -> Data {
        Data("""
        {"badge_total":4,"junchat_badge_state":{"user_id":"\(userID)","generation":"16a85460-6ed5-4cf9-ae72-f53689a2f831","revision":"9007199254740992"}}
        """.utf8)
    }

    @Test
    func authenticatedSnapshotUsesExactPrefixedServerAndIntegerRevision() async throws {
        let session = session()
        let payload = payload()
        let service = JunchatBadgeService(sessionProvider: { session }, send: { request in
            #expect(request.url?.path == "/prefix/_matrix/client/v3/junchat/badge")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval == 10)
            let url = try #require(request.url)
            return try (payload, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        let snapshot = try #require(await service.snapshot())
        #expect(snapshot.total == 4)
        #expect(snapshot.revision == 9_007_199_254_740_992)
    }

    @Test(arguments: [401, 404, 429, 500])
    func unsupportedOrUnavailableServerIsNotAZero(_ status: Int) async {
        let session = session()
        let payload = payload()
        let service = JunchatBadgeService(sessionProvider: { session }, send: { request in
            let url = try #require(request.url)
            return try (payload, #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        })
        #expect(await service.snapshot() == nil)
    }

    @Test
    func mismatchedAccountCannotSupplyBadgeCount() async {
        let session = session()
        let payload = payload(userID: "@bob:example.org")
        let service = JunchatBadgeService(sessionProvider: { session }, send: { request in
            let url = try #require(request.url)
            return try (payload, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        #expect(await service.snapshot() == nil)
    }

    @Test(arguments: [true, false])
    func redirectedResponseAndOversizedResponseAreRejected(_ redirect: Bool) async {
        let session = session()
        let payload = payload()
        let service = JunchatBadgeService(sessionProvider: { session }, send: { request in
            let url = try #require(redirect ? URL(string: "https://other.example.org/") : request.url)
            let data = redirect ? payload : Data(repeating: 0, count: 16385)
            return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        })
        #expect(await service.snapshot() == nil)
    }
}
