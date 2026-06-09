# iOS Call Ringtone Selection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users choose a local bundled CallKit ringtone for JunChat calls, with bright and soft options plus the current classic sound.

**Architecture:** Store the selected ringtone in `AppSettings`, expose it in the existing settings screen, and have `ElementCallService` build its `CXProviderConfiguration` from that setting. Ringtones are bundled CAF files under `ElementX/Resources/Sounds` so iOS can use them as CallKit sounds.

**Tech Stack:** SwiftUI settings UI, `UserPreference`/`AppSettings`, CallKit `CXProviderConfiguration`, AVFoundation for preview playback, CAF audio resources.

---

### Task 1: Add Settings Model Tests

**Files:**
- Modify: `UnitTests/Sources/AppSettingsTests.swift`
- Modify: `UnitTests/Sources/SettingsScreenViewModelTests.swift`

**Steps:**
1. Add failing tests for default ringtone, persisted ringtone, settings view state, and update action.
2. Run only those tests and verify the build fails because the ringtone model/settings do not exist.
3. Add minimal `JunchatCallRingtone` and `AppSettings` persistence.
4. Re-run tests until green.

### Task 2: Wire CallKit

**Files:**
- Modify: `ElementX/Sources/Services/ElementCall/ElementCallService.swift`
- Modify: `UnitTests/Sources/AppSettingsTests.swift`

**Steps:**
1. Add a failing test that the CallKit configuration uses the selected ringtone filename.
2. Extract provider configuration creation to a testable helper.
3. Pass `AppSettings` into `ElementCallService` from `AppCoordinator`.
4. Re-run tests.

### Task 3: Add UI And Preview Playback

**Files:**
- Modify: `ElementX/Sources/Screens/Settings/SettingsScreen/SettingsScreenModels.swift`
- Modify: `ElementX/Sources/Screens/Settings/SettingsScreen/SettingsScreenViewModel.swift`
- Modify: `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift`

**Steps:**
1. Add selected ringtone state and update action.
2. Render local ringtone rows in the existing JunChat settings section.
3. Add a play button that previews the bundled CAF with `AVAudioPlayer`.
4. Re-run settings tests.

### Task 4: Generate Bundled CAF Files

**Files:**
- Create: `ElementX/Resources/Sounds/junchat-call-bright-chime.caf`
- Create: `ElementX/Resources/Sounds/junchat-call-bright-rise.caf`
- Create: `ElementX/Resources/Sounds/junchat-call-soft-bell.caf`
- Create: `ElementX/Resources/Sounds/junchat-call-soft-pulse.caf`

**Steps:**
1. Generate short looping-friendly tones and convert to CAF/IMA4.
2. Regenerate the Xcode project if needed so resources are included.
3. Run targeted unit tests and a simulator build.
