//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct UserAgentBuilderTests {
    @Test
    func isNotUnknow() {
        #expect(UserAgentBuilder.makeASCIIUserAgent() != "unknown")
    }
    
    @Test
    func containsClientName() {
        let userAgent = UserAgentBuilder.makeASCIIUserAgent()
        #expect(userAgent.hasPrefix("\(InfoPlistReader.app.productionAppName)/") == true,
                "\(userAgent) does not contain the production app name")
    }
    
    @Test
    func containsClientVersion() {
        let userAgent = UserAgentBuilder.makeASCIIUserAgent()
        #expect(userAgent.contains(InfoPlistReader.main.bundleShortVersionString) == true, "\(userAgent) does not contain client version")
    }
    
    @Test
    func isValidHTTPHeaderValue() {
        let userAgent = UserAgentBuilder.makeASCIIUserAgent()
        #expect(userAgent.allSatisfy { character in
            character.unicodeScalars.allSatisfy { scalar in
                scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7e)
            }
        }, "\(userAgent) contains a character that cannot be used in an HTTP header")
    }
}
