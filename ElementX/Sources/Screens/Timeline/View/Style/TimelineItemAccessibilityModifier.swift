//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

enum TimelineItemAccessibilityPolicy {
    static func showsMessageActions(isMessageSelectionActive: Bool) -> Bool {
        !isMessageSelectionActive
    }
}

private struct TimelineItemAccessibilityModifier: ViewModifier {
    let timelineItem: RoomTimelineItemProtocol
    let showsMessageActions: Bool
    let action: () -> Void
    
    func body(content: Content) -> some View {
        switch timelineItem {
        case is PollRoomTimelineItem:
            content
                .accessibilityActions {
                    if showsMessageActions {
                        Button(L10n.commonMessageActions) {
                            action()
                        }
                    }
                }
        case let timelineItem as EventBasedTimelineItemProtocol:
            content
                .accessibilityRepresentation {
                    VStack(spacing: 8) {
                        Text(timelineItem.sender.displayName ?? timelineItem.sender.id)
                        content
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityActions {
                    if showsMessageActions {
                        Button(L10n.commonMessageActions) {
                            action()
                        }
                    }
                }
        default:
            content
                .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    func timelineItemAccessibility(_ timelineItem: RoomTimelineItemProtocol,
                                   showsMessageActions: Bool,
                                   action: @escaping () -> Void) -> some View {
        modifier(TimelineItemAccessibilityModifier(timelineItem: timelineItem,
                                                   showsMessageActions: showsMessageActions,
                                                   action: action))
    }
}
