//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct TimelineBulkRedactionSelectionState: Equatable {
    var selectedIDs = Set<TimelineItemIdentifier.EventOrTransactionID>()
    
    var isActive: Bool {
        !selectedIDs.isEmpty
    }
    
    var selectedCount: Int {
        selectedIDs.count
    }
    
    func isSelected(_ id: TimelineItemIdentifier.EventOrTransactionID) -> Bool {
        selectedIDs.contains(id)
    }
}

enum TimelineBulkRedactionEligibility {
    static func selectableRedactionID(for item: EventBasedTimelineItemProtocol,
                                      canCurrentUserRedactSelf: Bool,
                                      canCurrentUserRedactOthers: Bool) -> TimelineItemIdentifier.EventOrTransactionID? {
        guard !item.isRedacted, !(item is StateRoomTimelineItem), !(item is EncryptedRoomTimelineItem),
              let eventOrTransactionID = item.id.eventOrTransactionID else {
            return nil
        }
        
        let hasPermission = item.isOutgoing ? canCurrentUserRedactSelf : canCurrentUserRedactOthers
        return hasPermission ? eventOrTransactionID : nil
    }
}
