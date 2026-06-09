//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

enum JunchatMapProvider: Equatable {
    case stable
    case tencent

    static func from(sdkKey: String?, forceStableMap: Bool = false) -> Self {
        guard forceStableMap == false else {
            return .stable
        }

        guard let sdkKey, sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .stable
        }

        return .tencent
    }
}
