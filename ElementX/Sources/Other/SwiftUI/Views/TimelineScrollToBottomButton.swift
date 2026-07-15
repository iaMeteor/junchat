//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct TimelineScrollToBottomButtonState: Equatable {
    let isAtBottomAndLive: Bool
    let isInteractionLocked: Bool

    var isVisuallyHidden: Bool {
        isAtBottomAndLive || isInteractionLocked
    }

    var allowsHitTesting: Bool {
        !isVisuallyHidden
    }

    var isAccessibilityHidden: Bool {
        isVisuallyHidden
    }
}

struct TimelineScrollToBottomButton: View {
    let state: TimelineScrollToBottomButtonState
    let callback: () -> Void

    init(isVisible: Bool, isInteractionLocked: Bool = false, callback: @escaping () -> Void) {
        state = .init(isAtBottomAndLive: isVisible, isInteractionLocked: isInteractionLocked)
        self.callback = callback
    }
    
    var body: some View {
        Button { callback() } label: {
            Image(systemName: "chevron.down")
                .font(.compound.bodyLG)
                .fontWeight(.semibold)
                .foregroundColor(.compound.iconSecondary)
                .padding(13)
                .offset(y: 1)
                .background {
                    Circle()
                        .fill(Color.compound.iconOnSolidPrimary)
                        // Intentionally using system primary colour to get white/black.
                        .shadow(color: .primary.opacity(0.33), radius: 2.0)
                }
                .padding()
        }
        .opacity(state.isVisuallyHidden ? 0.0 : 1.0)
        .allowsHitTesting(state.allowsHitTesting)
        .accessibilityHidden(state.isAccessibilityHidden)
        .animation(.elementDefault, value: state.isVisuallyHidden)
    }
}
