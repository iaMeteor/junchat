//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct TimelineMessageSelectionState: Equatable {
    var selectedIDs = Set<TimelineItemIdentifier.EventOrTransactionID>()
    var redactionIDs = Set<TimelineItemIdentifier.EventOrTransactionID>()
    var forwardingIDs = Set<TimelineItemIdentifier.EventOrTransactionID>()

    init(selectedIDs: Set<TimelineItemIdentifier.EventOrTransactionID> = [],
         redactionIDs: Set<TimelineItemIdentifier.EventOrTransactionID>? = nil,
         forwardingIDs: Set<TimelineItemIdentifier.EventOrTransactionID>? = nil) {
        self.selectedIDs = selectedIDs
        self.redactionIDs = redactionIDs ?? selectedIDs
        self.forwardingIDs = forwardingIDs ?? selectedIDs
    }

    var isActive: Bool {
        !selectedIDs.isEmpty
    }

    var selectedCount: Int {
        selectedIDs.count
    }

    func isSelected(_ id: TimelineItemIdentifier.EventOrTransactionID) -> Bool {
        selectedIDs.contains(id)
    }

    func canToggleSelection(_ id: TimelineItemIdentifier.EventOrTransactionID) -> Bool {
        isSelected(id) || selectedCount < MessageForwardingBatch.maximumItemCount
    }

    var canRedactSelectedMessages: Bool {
        isActive && selectedIDs.isSubset(of: redactionIDs)
    }

    var canForwardSelectedMessages: Bool {
        isActive && selectedCount <= MessageForwardingBatch.maximumItemCount && selectedIDs.isSubset(of: forwardingIDs)
    }

    mutating func insert(_ capabilities: TimelineMessageSelectionCapabilities) {
        guard canToggleSelection(capabilities.id) else { return }

        selectedIDs.insert(capabilities.id)
        if capabilities.canRedact {
            redactionIDs.insert(capabilities.id)
        }
        if capabilities.canForward {
            forwardingIDs.insert(capabilities.id)
        }
    }

    mutating func remove(_ id: TimelineItemIdentifier.EventOrTransactionID) {
        selectedIDs.remove(id)
        redactionIDs.remove(id)
        forwardingIDs.remove(id)
    }

    mutating func replace(_ id: TimelineItemIdentifier.EventOrTransactionID,
                          with capabilities: TimelineMessageSelectionCapabilities) {
        guard selectedIDs.contains(id) else { return }

        remove(id)
        insert(capabilities)
    }
}

struct TimelineMessageSelectionCapabilities: Equatable {
    let id: TimelineItemIdentifier.EventOrTransactionID
    let canRedact: Bool
    let canForward: Bool
}

enum TimelineMessageSelectionEligibility {
    static func capabilities(for item: EventBasedTimelineItemProtocol,
                             canCurrentUserRedactSelf: Bool,
                             canCurrentUserRedactOthers: Bool) -> TimelineMessageSelectionCapabilities? {
        guard !item.isRedacted, !(item is StateRoomTimelineItem), !(item is EncryptedRoomTimelineItem),
              let eventOrTransactionID = item.id.eventOrTransactionID else {
            return nil
        }

        let canRedact = TimelineMessageRedactionEligibility.selectableRedactionID(for: item,
                                                                                  canCurrentUserRedactSelf: canCurrentUserRedactSelf,
                                                                                  canCurrentUserRedactOthers: canCurrentUserRedactOthers) != nil
        let canForward = item.isForwardable

        guard canRedact || canForward else {
            return nil
        }

        return .init(id: eventOrTransactionID, canRedact: canRedact, canForward: canForward)
    }
}

enum TimelineMessageRedactionEligibility {
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
