//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct JunchatServerEnvironment: Equatable {
    private enum InfoKey: String {
        case matrixAccountProvider = "JunchatMatrixAccountProvider"
        case oidcRedirectURL = "JunchatOIDCRedirectURL"
        case pushGatewayBaseURL = "JunchatPushGatewayBaseURL"
        case diagnosticsEndpoint = "JunchatDiagnosticsEndpoint"
        case rageshakeEnabled = "JunchatRageshakeEnabled"
        case backgroundAppRefreshTaskIdentifier = "JunchatBackgroundAppRefreshTaskIdentifier"
    }

    static let production = JunchatServerEnvironment(matrixAccountProvider: "junchat.yyzs120.cn",
                                                     oidcRedirectURL: URL(string: "https://junchat.yyzs120.cn/oidc/login")!,
                                                     pushGatewayBaseURL: URL(string: "https://sygnal-junchat.yyzs120.cn")!,
                                                     diagnosticsEndpoint: URL(string: "https://junchat.yyzs120.cn/junchat-errors/api/events")!,
                                                     rageshakeEnabled: true,
                                                     backgroundAppRefreshTaskIdentifier: "com.heyujk.junchat.background.refresh")

    static var current: JunchatServerEnvironment {
        #if JUNCHAT_CANARY
        guard let environment = JunchatServerEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            preconditionFailure("Incomplete Junchat Canary server configuration.")
        }
        return environment
        #else
        return JunchatServerEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:]) ?? .production
        #endif
    }

    let matrixAccountProvider: String
    let oidcRedirectURL: URL
    let pushGatewayBaseURL: URL
    let diagnosticsEndpoint: URL
    let rageshakeEnabled: Bool
    let backgroundAppRefreshTaskIdentifier: String

    init?(infoDictionary: [String: Any]) {
        guard let matrixAccountProvider = infoDictionary[InfoKey.matrixAccountProvider.rawValue] as? String,
              !matrixAccountProvider.isEmpty,
              let oidcRedirectURL = Self.httpsURL(in: infoDictionary, for: .oidcRedirectURL),
              let pushGatewayBaseURL = Self.httpsURL(in: infoDictionary, for: .pushGatewayBaseURL),
              let diagnosticsEndpoint = Self.httpsURL(in: infoDictionary, for: .diagnosticsEndpoint),
              let rageshakeEnabled = Self.bool(in: infoDictionary, for: .rageshakeEnabled),
              let backgroundAppRefreshTaskIdentifier = infoDictionary[InfoKey.backgroundAppRefreshTaskIdentifier.rawValue] as? String,
              !backgroundAppRefreshTaskIdentifier.isEmpty else {
            return nil
        }

        self.init(matrixAccountProvider: matrixAccountProvider,
                  oidcRedirectURL: oidcRedirectURL,
                  pushGatewayBaseURL: pushGatewayBaseURL,
                  diagnosticsEndpoint: diagnosticsEndpoint,
                  rageshakeEnabled: rageshakeEnabled,
                  backgroundAppRefreshTaskIdentifier: backgroundAppRefreshTaskIdentifier)
    }

    private init(matrixAccountProvider: String,
                 oidcRedirectURL: URL,
                 pushGatewayBaseURL: URL,
                 diagnosticsEndpoint: URL,
                 rageshakeEnabled: Bool,
                 backgroundAppRefreshTaskIdentifier: String) {
        self.matrixAccountProvider = matrixAccountProvider
        self.oidcRedirectURL = oidcRedirectURL
        self.pushGatewayBaseURL = pushGatewayBaseURL
        self.diagnosticsEndpoint = diagnosticsEndpoint
        self.rageshakeEnabled = rageshakeEnabled
        self.backgroundAppRefreshTaskIdentifier = backgroundAppRefreshTaskIdentifier
    }

    private static func httpsURL(in infoDictionary: [String: Any], for key: InfoKey) -> URL? {
        guard let value = infoDictionary[key.rawValue] as? String,
              let url = URL(string: value),
              url.scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }

    private static func bool(in infoDictionary: [String: Any], for key: InfoKey) -> Bool? {
        if let value = infoDictionary[key.rawValue] as? Bool {
            return value
        }
        guard let value = infoDictionary[key.rawValue] as? String else {
            return nil
        }
        switch value.lowercased() {
        case "yes", "true", "1":
            return true
        case "no", "false", "0":
            return false
        default:
            return nil
        }
    }
}
