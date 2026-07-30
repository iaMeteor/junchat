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
    @Test(arguments: CallRoomScenario.all)
    func callIntentAndLobbyUseOneRoomInfoAuthority(_ scenario: CallRoomScenario) async {
        for hasActiveCall in [false, true] {
            for voiceOnly in [false, true] {
                let room = RoomSDKMock()
                room.roomInfoReturnValue = makeRoomInfo(scenario: scenario)
                room.hasActiveRoomCallReturnValue = hasActiveCall
                room.isDirectReturnValue = !scenario.isDirect

                let configuration = await ElementCallWidgetDriver.callConfiguration(room: room,
                                                                                    voiceOnly: voiceOnly)

                #expect(configuration.intent == scenario.expectedIntent(hasActiveCall: hasActiveCall,
                                                                        voiceOnly: voiceOnly))
                #expect(configuration.voiceOnly == voiceOnly)
                #expect(configuration.skipLobby == scenario.expectedSkipLobby)
                #expect(room.roomInfoCallsCount == 1)
                #expect(room.hasActiveRoomCallCallsCount == 1)
                #expect(room.isDirectCallsCount == 0)
            }
        }
    }

    @Test(arguments: CallRoomScenario.all)
    @MainActor
    func everyRoomOffersAVoiceAndAVideoStartAction(_ scenario: CallRoomScenario) async {
        let startCallOptions = RoomCallControlsToolbar.startCallOptions
        #expect(startCallOptions.map(\.isVoiceCall) == [true, false])

        for option in startCallOptions {
            let room = RoomSDKMock()
            room.roomInfoReturnValue = makeRoomInfo(scenario: scenario)
            room.hasActiveRoomCallReturnValue = false

            let configuration = await ElementCallWidgetDriver.callConfiguration(room: room,
                                                                                voiceOnly: option.isVoiceCall)

            #expect(configuration.intent == scenario.expectedIntent(hasActiveCall: false,
                                                                    voiceOnly: option.isVoiceCall))
            #expect(configuration.voiceOnly == option.isVoiceCall)
            #expect(configuration.skipLobby == scenario.expectedSkipLobby)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func failedRoomInfoUsesConservativeGroupConfiguration(hasActiveCall: Bool, voiceOnly: Bool) async {
        let room = RoomSDKMock()
        room.roomInfoClosure = { throw RoomInfoTestError.unavailable }
        room.hasActiveRoomCallReturnValue = hasActiveCall
        room.isDirectReturnValue = true

        let configuration = await ElementCallWidgetDriver.callConfiguration(room: room,
                                                                            voiceOnly: voiceOnly)

        #expect(configuration.intent == (hasActiveCall ? .joinExisting : .startCall))
        #expect(configuration.voiceOnly == voiceOnly)
        #expect(configuration.skipLobby == nil)
        #expect(room.roomInfoCallsCount == 1)
        #expect(room.hasActiveRoomCallCallsCount == 1)
        #expect(room.isDirectCallsCount == 0)
    }
}

private enum RoomInfoTestError: Error {
    case unavailable
}

struct CallRoomScenario: CustomTestStringConvertible {
    static let all = [
        CallRoomScenario(name: "true DM", isDirect: true, isSpace: false, activeMembersCount: 2),
        CallRoomScenario(name: "two-member non-DM", isDirect: false, isSpace: false, activeMembersCount: 2),
        CallRoomScenario(name: "larger non-DM", isDirect: false, isSpace: false, activeMembersCount: 5),
        CallRoomScenario(name: "direct-marked larger room", isDirect: true, isSpace: false, activeMembersCount: 3),
        CallRoomScenario(name: "space", isDirect: false, isSpace: true, activeMembersCount: 5),
        CallRoomScenario(name: "direct-marked space", isDirect: true, isSpace: true, activeMembersCount: 2)
    ]

    let name: String
    let isDirect: Bool
    let isSpace: Bool
    let activeMembersCount: UInt64

    var testDescription: String {
        name
    }

    private var usesDirectCallIntent: Bool {
        isDirect && !isSpace
    }

    func expectedIntent(hasActiveCall: Bool, voiceOnly: Bool) -> Intent {
        switch (hasActiveCall, usesDirectCallIntent) {
        case (true, true): voiceOnly ? .joinExistingDmVoice : .joinExistingDm
        case (true, false): .joinExisting
        case (false, true): voiceOnly ? .startCallDmVoice : .startCallDm
        case (false, false): .startCall
        }
    }

    var expectedSkipLobby: Bool? {
        !isSpace && !usesDirectCallIntent ? true : nil
    }
}

private func makeRoomInfo(scenario: CallRoomScenario) -> RoomInfo {
    RoomInfo(id: "!room:example.org",
             encryptionState: .encrypted,
             creators: nil,
             displayName: nil,
             rawName: nil,
             topic: nil,
             avatarUrl: nil,
             isDirect: scenario.isDirect,
             isPublic: nil,
             isSpace: scenario.isSpace,
             successorRoom: nil,
             isFavourite: false,
             isLowPriority: false,
             canonicalAlias: nil,
             alternativeAliases: [],
             membership: .joined,
             inviter: nil,
             heroes: [],
             activeMembersCount: scenario.activeMembersCount,
             invitedMembersCount: 0,
             joinedMembersCount: scenario.activeMembersCount,
             activeServiceMembersCount: 0,
             serviceMembers: [],
             highlightCount: 0,
             notificationCount: 0,
             cachedUserDefinedNotificationMode: nil,
             hasRoomCall: false,
             activeRoomCallParticipants: [],
             activeRoomCallConsensusIntent: .none,
             isMarkedUnread: false,
             numUnreadMessages: 0,
             numUnreadNotifications: 0,
             numUnreadMentions: 0,
             pinnedEventIds: [],
             joinRule: nil,
             historyVisibility: .shared,
             powerLevels: nil,
             roomVersion: nil,
             privilegedCreatorsRole: false)
}
