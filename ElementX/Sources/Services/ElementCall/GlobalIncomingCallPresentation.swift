//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

struct GlobalIncomingCallCandidate {
    let roomID: String
    let roomTitle: String
    let roomAvatar: RoomAvatar
    let isVoiceCall: Bool
    
    init(roomSummary: RoomSummary) {
        roomID = roomSummary.id
        roomTitle = roomSummary.name
        isVoiceCall = roomSummary.activeCallIntent == .audio
        
        if roomSummary.isSpace {
            roomAvatar = .space(id: roomSummary.id, name: roomSummary.name, avatarURL: roomSummary.avatarURL)
        } else if !roomSummary.heroes.isEmpty {
            roomAvatar = .heroes(roomSummary.heroes)
        } else {
            roomAvatar = .room(id: roomSummary.id, name: roomSummary.name, avatarURL: roomSummary.avatarURL)
        }
    }
}

struct GlobalIncomingCallPresentation {
    private var dismissedCallRoomIDs = Set<String>()
    
    mutating func dismiss(roomID: String) {
        dismissedCallRoomIDs.insert(roomID)
    }
    
    mutating func candidate(from rooms: [RoomSummary], ongoingCallRoomID: String?, pendingIncomingCallRoomID: String?, ownUserID: String) -> GlobalIncomingCallCandidate? {
        resetDismissedCallsThatHaveEnded(in: rooms, ownUserID: ownUserID)
        
        if let pendingIncomingCallRoomID {
            guard !dismissedCallRoomIDs.contains(pendingIncomingCallRoomID) else {
                return nil
            }
            
            if let ongoingCallRoomID, ongoingCallRoomID != pendingIncomingCallRoomID {
                return nil
            }
            
            guard let room = rooms.first(where: { $0.id == pendingIncomingCallRoomID }) else {
                return nil
            }
            
            return GlobalIncomingCallCandidate(roomSummary: room)
        }
        
        guard ongoingCallRoomID == nil,
              let room = rooms.first(where: { room in
                  room.hasOngoingCall &&
                      room.activeRoomCallParticipants.contains { $0 != ownUserID } &&
                      !dismissedCallRoomIDs.contains(room.id)
              }) else {
            return nil
        }
        
        return GlobalIncomingCallCandidate(roomSummary: room)
    }
    
    private mutating func resetDismissedCallsThatHaveEnded(in rooms: [RoomSummary], ownUserID: String) {
        let activeCallRoomIDs = Set(rooms.filter { room in
            room.hasOngoingCall && room.activeRoomCallParticipants.contains { $0 != ownUserID }
        }.map(\.id))
        dismissedCallRoomIDs.formIntersection(activeCallRoomIDs)
    }
}
