//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class JunchatMapProviderTests: XCTestCase {
    func testUsesStableMapWhenSDKKeyIsEmpty() {
        XCTAssertEqual(JunchatMapProvider.from(sdkKey: ""), .stable)
    }

    func testUsesStableMapWhenStableMapIsForced() {
        XCTAssertEqual(JunchatMapProvider.from(sdkKey: "valid-key", forceStableMap: true), .stable)
    }

    func testUsesTencentMapWhenSDKKeyIsPresentAndStableMapIsNotForced() {
        XCTAssertEqual(JunchatMapProvider.from(sdkKey: "valid-key", forceStableMap: false), .tencent)
    }
}
