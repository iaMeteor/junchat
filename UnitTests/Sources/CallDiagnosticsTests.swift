//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct CallDiagnosticsTests {
    @Test
    func urlSummaryOmitsCredentialsHostPathAndQueryValues() throws {
        let url = try #require(URL(string: "https://alice:password@calls.example.org/room/secret?token=access-token#device-id"))

        let summary = CallDiagnostics.urlSummary(url)

        #expect(summary == "scheme=https hostPresent=true pathComponents=2 queryPresent=true fragmentPresent=true")
        #expect(!summary.contains("alice"))
        #expect(!summary.contains("password"))
        #expect(!summary.contains("calls.example.org"))
        #expect(!summary.contains("secret"))
        #expect(!summary.contains("access-token"))
        #expect(!summary.contains("device-id"))
    }

    @Test
    func jsonSummaryOmitsPayloadValues() {
        let json = #"{"action":"send_event","room_id":"!secret:example.org","password":"hunter2","token":"access-token"}"#

        let summary = CallDiagnostics.jsonSummary(json)

        #expect(summary.contains("shape=object"))
        #expect(!summary.contains("send_event"))
        #expect(!summary.contains("!secret:example.org"))
        #expect(!summary.contains("hunter2"))
        #expect(!summary.contains("access-token"))
    }

    @Test
    func textSummaryOmitsForwardedWebLogContents() {
        let summary = CallDiagnostics.textSummary("room=!secret:example.org token=access-token\npassword=hunter2")

        #expect(summary.contains("lines=2"))
        #expect(!summary.contains("!secret:example.org"))
        #expect(!summary.contains("access-token"))
        #expect(!summary.contains("hunter2"))
    }

    @Test
    func dictionarySummaryOmitsKeysAndValues() {
        let summary = CallDiagnostics.dictionarySummary([
            "room_id": "!secret:example.org",
            "token": "access-token"
        ])

        #expect(summary == "keys=2")
        #expect(!summary.contains("room_id"))
        #expect(!summary.contains("!secret:example.org"))
        #expect(!summary.contains("access-token"))
    }

    @Test
    func errorSummaryOmitsDomainAndLocalizedDescription() {
        let error = NSError(domain: "access-token.example.org",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "password=hunter2"])

        let summary = CallDiagnostics.errorSummary(error)

        #expect(summary.contains("code=401"))
        #expect(!summary.contains("access-token"))
        #expect(!summary.contains("hunter2"))
    }

    @Test
    func valueSummaryOmitsJavaScriptResultContents() {
        let summary = CallDiagnostics.valueSummary("room=!secret:example.org token=access-token")

        #expect(summary.contains("shape=string"))
        #expect(!summary.contains("!secret:example.org"))
        #expect(!summary.contains("access-token"))
    }
}
