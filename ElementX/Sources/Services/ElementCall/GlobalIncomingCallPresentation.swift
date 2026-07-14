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
    let incomingCallIdentity: ElementCallIncomingCallIdentity?
    
    init(roomSummary: RoomSummary, incomingCallIdentity: ElementCallIncomingCallIdentity? = nil) {
        roomID = roomSummary.id
        roomTitle = roomSummary.name
        isVoiceCall = incomingCallIdentity?.isVoiceCall ?? (roomSummary.activeCallIntent == .audio)
        self.incomingCallIdentity = incomingCallIdentity
        
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
    private var dismissedIncomingCallIdentities = Set<ElementCallIncomingCallIdentity>()
    
    mutating func dismiss(_ candidate: GlobalIncomingCallCandidate) {
        if let incomingCallIdentity = candidate.incomingCallIdentity {
            dismissedIncomingCallIdentities.insert(incomingCallIdentity)
        } else {
            dismissedCallRoomIDs.insert(candidate.roomID)
        }
    }
    
    mutating func candidate(from rooms: [RoomSummary],
                            ongoingCallRoomID: String?,
                            pendingIncomingCallIdentity: ElementCallIncomingCallIdentity?,
                            ownUserID: String) -> GlobalIncomingCallCandidate? {
        resetDismissedCallsThatHaveEnded(in: rooms, ownUserID: ownUserID)
        if let pendingIncomingCallIdentity {
            dismissedIncomingCallIdentities.formIntersection([pendingIncomingCallIdentity])
        } else {
            dismissedIncomingCallIdentities.removeAll()
        }
        
        if let pendingIncomingCallIdentity {
            let pendingIncomingCallRoomID = pendingIncomingCallIdentity.roomID
            guard !dismissedIncomingCallIdentities.contains(pendingIncomingCallIdentity) else {
                return nil
            }
            
            if let ongoingCallRoomID, ongoingCallRoomID != pendingIncomingCallRoomID {
                return nil
            }
            
            guard let room = rooms.first(where: { $0.id == pendingIncomingCallRoomID }) else {
                return nil
            }
            
            return GlobalIncomingCallCandidate(roomSummary: room, incomingCallIdentity: pendingIncomingCallIdentity)
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
