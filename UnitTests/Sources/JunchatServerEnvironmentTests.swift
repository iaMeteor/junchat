//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct JunchatServerEnvironmentTests {
    @Test
    func productionValuesRemainCompatible() {
        let environment = JunchatServerEnvironment.production

        #expect(environment.matrixAccountProvider == "junchat.yyzs120.cn")
        #expect(environment.oidcRedirectURL == URL(string: "https://junchat.yyzs120.cn/oidc/login"))
        #expect(environment.pushGatewayBaseURL == URL(string: "https://sygnal-junchat.yyzs120.cn/junchat-sygnal-v2"))
        #expect(environment.diagnosticsEndpoint == URL(string: "https://junchat.yyzs120.cn/junchat-errors/api/v2/uploads"))
        #expect(environment.rageshakeEnabled)
        #expect(environment.backgroundAppRefreshTaskIdentifier == "com.heyujk.junchat.background.refresh")
    }

    @Test
    func parsesCompleteCanaryConfiguration() throws {
        let dictionary: [String: Any] = [
            "JunchatMatrixAccountProvider": "canary.junchat.yyzs120.cn",
            "JunchatOIDCRedirectURL": "https://canary.junchat.yyzs120.cn/oidc/login",
            "JunchatPushGatewayBaseURL": "https://canary.junchat.yyzs120.cn/push",
            "JunchatDiagnosticsEndpoint": "https://canary.junchat.yyzs120.cn/diagnostics/api/events",
            "JunchatRageshakeEnabled": "NO",
            "JunchatBackgroundAppRefreshTaskIdentifier": "com.heyujk.junchat.canary.background.refresh"
        ]

        let environment = try #require(JunchatServerEnvironment(infoDictionary: dictionary))

        #expect(environment.matrixAccountProvider == "canary.junchat.yyzs120.cn")
        #expect(environment.oidcRedirectURL == URL(string: "https://canary.junchat.yyzs120.cn/oidc/login"))
        #expect(environment.pushGatewayBaseURL == URL(string: "https://canary.junchat.yyzs120.cn/push"))
        #expect(environment.diagnosticsEndpoint == URL(string: "https://canary.junchat.yyzs120.cn/diagnostics/api/events"))
        #expect(!environment.rageshakeEnabled)
        #expect(environment.backgroundAppRefreshTaskIdentifier == "com.heyujk.junchat.canary.background.refresh")
    }

    @Test
    func rejectsIncompleteCanaryConfiguration() {
        let dictionary: [String: Any] = [
            "JunchatMatrixAccountProvider": "canary.junchat.yyzs120.cn",
            "JunchatRageshakeEnabled": false
        ]

        #expect(JunchatServerEnvironment(infoDictionary: dictionary) == nil)
    }
}
