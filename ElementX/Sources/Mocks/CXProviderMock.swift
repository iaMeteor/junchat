//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CallKit

extension CXProviderMock {
    struct Configuration { }
    
    convenience init(_ configuration: Configuration) {
        self.init()
        self.configuration = CXProviderConfiguration()
        self.configuration.ringtoneSound = JunchatCallRingtone.classic.soundName
        reportNewIncomingCallWithUpdateCompletionClosure = { _, _, completion in
            completion(nil)
        }
    }
}
