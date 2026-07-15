//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

enum MessageForwardingScreenViewModelAction {
    case dismiss
    case queued(roomID: String)
}

struct MessageForwardingScreenViewState: BindableState {
    var rooms: [MessageForwardingRoom] = []
    var selectedRoomID: String?
    var forwardingProgress: MessageForwardingProgress?
    var isLedgerReconciliationRequired = false
    var bindings = MessageForwardingScreenViewStateBindings()

    var isDestinationLocked: Bool {
        if isLedgerReconciliationRequired {
            return true
        }
        guard let forwardingProgress else { return false }
        return forwardingProgress.queuedCount + forwardingProgress.unknownCount > 0
    }

    var canSend: Bool {
        guard selectedRoomID != nil, forwardingProgress?.isBusy != true else {
            return false
        }

        guard let forwardingProgress else {
            return true
        }

        return forwardingProgress.queuedCount < forwardingProgress.totalCount
    }
}

struct MessageForwardingProgress: Equatable {
    let totalCount: Int
    let queuedCount: Int
    let failedCount: Int
    let unknownCount: Int
    let isQueueing: Bool
    let isCancelling: Bool

    init(totalCount: Int,
         queuedCount: Int,
         failedCount: Int,
         unknownCount: Int = 0,
         isQueueing: Bool,
         isCancelling: Bool = false) {
        self.totalCount = totalCount
        self.queuedCount = queuedCount
        self.failedCount = failedCount
        self.unknownCount = unknownCount
        self.isQueueing = isQueueing
        self.isCancelling = isCancelling
    }

    var isBusy: Bool {
        isQueueing || isCancelling
    }

    var statusTitle: String {
        if isCancelling {
            UntranslatedL10n.screenMessageForwardingCancelling
        } else if isQueueing {
            UntranslatedL10n.screenMessageForwardingAddingToSendQueue
        } else if unknownCount > 0 {
            UntranslatedL10n.screenMessageForwardingOutcomeUnknown
        } else if failedCount > 0 {
            UntranslatedL10n.screenMessageForwardingQueueFailed
        } else {
            UntranslatedL10n.screenMessageForwardingAddedToSendQueue
        }
    }

    var sendButtonTitle: String {
        if isCancelling {
            UntranslatedL10n.screenMessageForwardingCancelling
        } else if isQueueing {
            UntranslatedL10n.screenMessageForwardingAdding
        } else if unknownCount > 0 {
            UntranslatedL10n.screenMessageForwardingReview
        } else if failedCount > 0 {
            L10n.actionRetry
        } else {
            L10n.actionSend
        }
    }

    var showsFailure: Bool {
        !isBusy && failedCount > 0
    }
}

struct MessageForwardingScreenViewStateBindings {
    var searchQuery = ""
    var isUnknownOutcomeResolutionPresented = false
}

enum MessageForwardingScreenViewAction {
    case cancel
    case cancelUnknownOutcomeResolution
    case continueWithoutResending
    case send
    case sendUnknownAgain
    case selectRoom(roomID: String)
    case reachedTop
    case reachedBottom
}

struct MessageForwardingRoom: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let avatar: RoomAvatar
}

struct MessageForwardingItem: Hashable {
    /// The source item's timeline ID. Only necessary for a rough Hashable conformance.
    let id: TimelineItemIdentifier
    /// The source item's room ID.
    let roomID: String
    /// The item's content to be forwarded.
    let content: RoomMessageEventContentWithoutRelation

    static func == (lhs: MessageForwardingItem, rhs: MessageForwardingItem) -> Bool {
        lhs.id == rhs.id && lhs.roomID == rhs.roomID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(roomID)
    }
}

struct MessageForwardingBatch: Hashable {
    static let maximumItemCount = 150

    let items: [MessageForwardingItem]

    init(firstItem: MessageForwardingItem) {
        items = [firstItem]
    }

    init?(firstItem: MessageForwardingItem, remainingItems: [MessageForwardingItem]) {
        guard remainingItems.count < Self.maximumItemCount else { return nil }
        items = [firstItem] + remainingItems
    }
}
