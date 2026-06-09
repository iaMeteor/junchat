//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDKMocks
import Testing

struct GlobalIncomingCallPresentationTests {
    @Test
    func selectsFirstActiveCallWhenIdle() {
        var presentation = GlobalIncomingCallPresentation()
        
        let candidate = presentation.candidate(from: [
            room(id: "quiet", hasOngoingCall: false),
            room(id: "ringing", name: "测试用户 2", hasOngoingCall: true, activeCallIntent: .audio, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: nil, pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn")
        
        #expect(candidate?.roomID == "ringing")
        #expect(candidate?.roomTitle == "测试用户 2")
        #expect(candidate?.isVoiceCall == true)
    }
    
    @Test
    func hidesCandidateWhileAlreadyInACall() {
        var presentation = GlobalIncomingCallPresentation()
        
        let candidate = presentation.candidate(from: [
            room(id: "ringing", hasOngoingCall: true, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: "another-room", pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn")
        
        #expect(candidate == nil)
    }
    
    @Test
    func keepsIncomingCandidateWhenSameRoomBecomesOngoingBeforeAccepting() {
        var presentation = GlobalIncomingCallPresentation()
        
        let candidate = presentation.candidate(from: [
            room(id: "ringing", name: "测试用户 2", hasOngoingCall: true, activeCallIntent: .audio, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: "ringing", pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn")
        
        #expect(candidate?.roomID == "ringing")
        #expect(candidate?.roomTitle == "测试用户 2")
    }
    
    @Test
    func keepsDeclinedCallHiddenUntilTheCallEnds() {
        var presentation = GlobalIncomingCallPresentation()
        let activeRooms = [room(id: "ringing", hasOngoingCall: true, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])]
        
        presentation.dismiss(roomID: "ringing")
        #expect(presentation.candidate(from: activeRooms, ongoingCallRoomID: nil, pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn") == nil)
        
        #expect(presentation.candidate(from: [
            room(id: "ringing", hasOngoingCall: false)
        ], ongoingCallRoomID: nil, pendingIncomingCallRoomID: nil, ownUserID: "@me:junchat.yyzs120.cn") == nil)
        
        let nextCandidate = presentation.candidate(from: activeRooms, ongoingCallRoomID: nil, pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn")
        #expect(nextCandidate?.roomID == "ringing")
    }

    @Test
    func selectsPendingIncomingCallBeforeRoomSummaryParticipantsSync() {
        var presentation = GlobalIncomingCallPresentation()
        
        let candidate = presentation.candidate(from: [
            room(id: "ringing", name: "测试用户 2", hasOngoingCall: false, activeCallIntent: .audio, activeRoomCallParticipants: [])
        ], ongoingCallRoomID: nil, pendingIncomingCallRoomID: "ringing", ownUserID: "@me:junchat.yyzs120.cn")
        
        #expect(candidate?.roomID == "ringing")
        #expect(candidate?.roomTitle == "测试用户 2")
    }

    @Test
    func selectsForegroundSyncedCallWhenPushHasNotArrived() {
        var presentation = GlobalIncomingCallPresentation()

        let candidate = presentation.candidate(from: [
            room(id: "quiet", hasOngoingCall: false),
            room(id: "ringing", name: "测试用户 2", hasOngoingCall: true, activeCallIntent: .audio, activeRoomCallParticipants: ["@caller:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: nil, pendingIncomingCallRoomID: nil, ownUserID: "@me:junchat.yyzs120.cn")

        #expect(candidate?.roomID == "ringing")
        #expect(candidate?.roomTitle == "测试用户 2")
        #expect(candidate?.isVoiceCall == true)
    }

    @Test
    func ignoresOwnOutgoingCallWhenTheSameRoomIsOngoingWithoutPendingIncomingCall() {
        var presentation = GlobalIncomingCallPresentation()

        let candidate = presentation.candidate(from: [
            room(id: "outgoing", name: "测试用户 2", hasOngoingCall: true, activeCallIntent: .audio, activeRoomCallParticipants: ["@me:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: "outgoing", pendingIncomingCallRoomID: nil, ownUserID: "@me:junchat.yyzs120.cn")

        #expect(candidate == nil)
    }

    @Test
    func ignoresOwnStaleCallWhenIdle() {
        var presentation = GlobalIncomingCallPresentation()

        let candidate = presentation.candidate(from: [
            room(id: "stale", name: "测试用户 2", hasOngoingCall: true, activeCallIntent: .audio, activeRoomCallParticipants: ["@me:junchat.yyzs120.cn"])
        ], ongoingCallRoomID: nil, pendingIncomingCallRoomID: nil, ownUserID: "@me:junchat.yyzs120.cn")

        #expect(candidate == nil)
    }
    
    private func room(id: String,
                      name: String? = nil,
                      hasOngoingCall: Bool,
                      activeCallIntent: CallIntent? = nil,
                      activeRoomCallParticipants: [String] = []) -> RoomSummary {
        RoomSummary(room: RoomSDKMock(),
                    id: id,
                    joinRequestType: nil,
                    name: name ?? id,
                    isDirect: true,
                    isSpace: false,
                    avatarURL: nil,
                    heroes: [],
                    activeMembersCount: 0,
                    lastMessage: nil,
                    lastMessageDate: nil,
                    lastMessageState: nil,
                    unreadMessagesCount: 0,
                    unreadMentionsCount: 0,
                    unreadNotificationsCount: 0,
                    notificationMode: .allMessages,
                    canonicalAlias: nil,
                    alternativeAliases: [],
                    hasOngoingCall: hasOngoingCall,
                    activeCallIntent: activeCallIntent,
                    activeRoomCallParticipants: activeRoomCallParticipants,
                    isMarkedUnread: false,
                    isFavourite: false,
                    isTombstoned: false)
    }
}
