# Junchat Privacy Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement iOS privacy timer, emergency PIN protection mode, and group-chat entry.

**Architecture:** Persist privacy state in `AppSettings`, surface it through room/timeline view models, and reuse existing Matrix redaction and room creation APIs. The first pass is client-side and active-app reliable; a server worker can be added later for offline guaranteed destruction.

**Tech Stack:** Swift, SwiftUI, Combine, MatrixRustSDK, Swift Testing.

---

### Task 1: Emergency PIN

**Files:**
- Modify: `ElementX/Sources/Screens/AppLock/AppLockScreen/AppLockScreenModels.swift`
- Modify: `ElementX/Sources/Screens/AppLock/AppLockScreen/AppLockScreenViewModel.swift`
- Modify: `ElementX/Sources/FlowCoordinators/AppLockFlowCoordinator.swift`
- Test: `UnitTests/Sources/AppLock/AppLockScreenViewModelTests.swift`

**Steps:**
1. Add `.emergencyPrivacyModeUnlocked` action.
2. Write a failing test that `7878` emits that action and does not increment failed attempts.
3. Make the view model emit it before normal PIN validation.
4. In the coordinator, set `appSettings.junchatEmergencyPrivacyModeEnabled = true` and unlock.
5. Clear the flag when the normal PIN unlocks.

### Task 2: Room Privacy Toggle

**Files:**
- Modify: `ElementX/Sources/Application/Settings/AppSettings.swift`
- Modify: `ElementX/Sources/Screens/RoomScreen/RoomScreenModels.swift`
- Modify: `ElementX/Sources/Screens/RoomScreen/RoomScreenViewModel.swift`
- Modify: `ElementX/Sources/Screens/RoomScreen/View/RoomScreen.swift`
- Test: `UnitTests/Sources/RoomScreenViewModelTests.swift`

**Steps:**
1. Add persisted privacy room IDs and emergency flag to app settings.
2. Add room state/action for privacy mode.
3. Write a failing test for toggling the room ID on/off.
4. Subscribe room state to settings and implement the toggle.
5. Add the timer toolbar button and privacy banner.

### Task 3: Self-Destructing Messages

**Files:**
- Modify: `ElementX/Sources/Screens/Timeline/TimelineModels.swift`
- Modify: `ElementX/Sources/Screens/Timeline/TimelineViewModel.swift`
- Modify: `ElementX/Sources/Screens/Timeline/View/TimelineView.swift`
- Modify: `ElementX/Sources/Services/Timeline/TimelineController/MockTimelineController.swift`
- Modify: `ElementX/Sources/Services/Timeline/TimelineItems/RoomTimelineItemFactory.swift`
- Test: `UnitTests/Sources/TimelineViewModelTests.swift`

**Steps:**
1. Add timeline emergency privacy state and a short injectable destruction delay for tests.
2. Write a failing test that sending while privacy mode is enabled eventually calls `redact`.
3. Schedule a delayed lookup of the outgoing message by body and redacts its event/transaction ID.
4. Hide existing timeline content when emergency privacy mode is enabled.
5. Change redacted display wording to `信息已销毁`.

### Task 4: Group Chat Entry

**Files:**
- Modify: `ElementX/Sources/Screens/StartChatScreen/StartChatScreenModels.swift`
- Modify: `ElementX/Sources/Screens/StartChatScreen/View/StartChatScreen.swift`
- Modify: `ElementX/Sources/Screens/InviteUsersScreen/InviteUsersScreenViewModel.swift`
- Test: `UnitTests/Sources/StartChatViewModelTests.swift`

**Steps:**
1. Add state proving the group-chat entry is visible.
2. Add a failing test for the visible entry.
3. Add `创建群聊` row that sends `.createRoom`.
4. Prefer company contacts as invite suggestions when loading invite users.

### Task 5: Verification

Run focused tests:

```bash
xcodebuild test -scheme UnitTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:UnitTests/AppLockScreenViewModelTests -only-testing:UnitTests/RoomScreenViewModelTests -only-testing:UnitTests/TimelineViewModelTests -only-testing:UnitTests/StartChatScreenViewModelTests
```

Run the Junchat config validator:

```bash
Tools/Scripts/validate_junchat_ios_config.sh
```
