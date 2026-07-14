//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct RoomTests {
    @Test
    func callIntent() async {
        let room = RoomSDKMock()
        room.hasActiveRoomCallReturnValue = false
        room.isDirectReturnValue = false
        
        var callIntent = await room.joinCallIntent()
        #expect(callIntent == .startCall)
      
        room.isDirectReturnValue = true
        callIntent = await room.joinCallIntent()
        #expect(callIntent == .startCallDm)
        
        callIntent = await room.joinCallIntent(voiceOnly: true)
        #expect(callIntent == .startCallDmVoice)
        
        room.hasActiveRoomCallReturnValue = true
        callIntent = await room.joinCallIntent()
        #expect(callIntent == .joinExistingDm)
        
        callIntent = await room.joinCallIntent(voiceOnly: true)
        #expect(callIntent == .joinExistingDmVoice)
        
        room.isDirectReturnValue = false
        callIntent = await room.joinCallIntent()
        #expect(callIntent == .joinExisting)
    }

    @Test
    func groupVoiceCallLobbyOverrideUsesOneRoomInfoSnapshotClassification() {
        let trueDM = ElementCallWidgetDriver.CallRoomClassification(isDirect: true, isSpace: false, activeMembersCount: 2)
        let directLargerRoom = ElementCallWidgetDriver.CallRoomClassification(isDirect: true, isSpace: false, activeMembersCount: 3)
        let twoMemberGroup = ElementCallWidgetDriver.CallRoomClassification(isDirect: false, isSpace: false, activeMembersCount: 2)
        let largerGroup = ElementCallWidgetDriver.CallRoomClassification(isDirect: false, isSpace: false, activeMembersCount: 5)
        let space = ElementCallWidgetDriver.CallRoomClassification(isDirect: false, isSpace: true, activeMembersCount: 5)

        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: true, roomClassification: trueDM) == nil)
        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: true, roomClassification: directLargerRoom) == true)
        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: true, roomClassification: twoMemberGroup) == true)
        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: true, roomClassification: largerGroup) == true)
        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: true, roomClassification: space) == nil)
        #expect(ElementCallWidgetDriver.skipLobbyOverride(voiceOnly: false, roomClassification: largerGroup) == nil)
    }
}
