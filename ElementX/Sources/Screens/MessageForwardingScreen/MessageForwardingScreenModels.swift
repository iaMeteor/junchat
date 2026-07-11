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
    case sent(roomID: String)
}

struct MessageForwardingScreenViewState: BindableState {
    var rooms: [MessageForwardingRoom] = []
    var selectedRoomID: String?
    var bindings = MessageForwardingScreenViewStateBindings()
}

struct MessageForwardingScreenViewStateBindings {
    var searchQuery = ""
}

enum MessageForwardingScreenViewAction {
    case cancel
    case send
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
    /// Additional items forwarded in the same operation.
    private let additionalItems: [MessageForwardingItem]

    init(id: TimelineItemIdentifier,
         roomID: String,
         content: RoomMessageEventContentWithoutRelation,
         additionalItems: [MessageForwardingItem] = []) {
        self.id = id
        self.roomID = roomID
        self.content = content
        self.additionalItems = additionalItems
    }

    var forwardingItems: [MessageForwardingItem] {
        let singleItem = MessageForwardingItem(id: id, roomID: roomID, content: content)
        return [singleItem] + additionalItems.flatMap(\.forwardingItems)
    }

    func addingForwardingItems(_ items: [MessageForwardingItem]) -> MessageForwardingItem {
        MessageForwardingItem(id: id, roomID: roomID, content: content, additionalItems: additionalItems + items)
    }

    static func == (lhs: MessageForwardingItem, rhs: MessageForwardingItem) -> Bool {
        lhs.id == rhs.id && lhs.roomID == rhs.roomID && lhs.additionalItems == rhs.additionalItems
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(roomID)
        hasher.combine(additionalItems)
    }
}
