# Junchat iOS White Label Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert the Element X iOS fork into the first usable Junchat iOS build with the internal homeserver, Junchat identifiers, and distinct message/call sounds.

**Architecture:** Keep Element X's existing project-generation and runtime settings patterns. Change global project identity in `app.yml`, runtime defaults in `AppSettings.swift`, entitlements in target YAML, and CallKit/notification sound configuration at their existing integration points.

**Tech Stack:** Swift, SwiftUI, XcodeGen, MatrixRustSDK, Apple Push Notifications, CallKit, UserNotifications.

---

### Task 1: Add Configuration Verification

**Files:**
- Create: `Tools/Scripts/validate_junchat_ios_config.sh`

**Steps:**
- Add a shell script that validates the expected Bundle ID, Team ID, App Group, associated domains, server defaults, push gateway, disabled registration UI, and sound names.
- Run it before implementation and confirm it fails against the upstream Element configuration.
- Run it after implementation and confirm it passes.

### Task 2: Change App Identity

**Files:**
- Modify: `app.yml`
- Modify: `ElementX/SupportingFiles/target.yml`
- Modify: `NSE/SupportingFiles/target.yml`
- Verify: `ShareExtension/SupportingFiles/target.yml`

**Steps:**
- Set display name to `君聊`, production name to `Junchat`, base bundle identifier to `com.heyujk.junchat`, App Group to `group.com.heyujk.junchat`, and Development Team to `W834S4TA7S`.
- Update the background refresh identifier to match the new bundle ID.
- Remove Element Classic migration app groups/keychain entitlements from the active Junchat target.
- Replace Element associated domains with `junchat.yyzs120.cn` and `matrix.to`.
- Keep the existing Share Extension, which derives `com.heyujk.junchat.shareextension` from the base bundle identifier.

### Task 3: Change Runtime Defaults

**Files:**
- Modify: `ElementX/Sources/Application/Settings/AppSettings.swift`

**Steps:**
- Set the only default account provider to `junchat.yyzs120.cn`.
- Disallow custom account providers for the internal app.
- Point web/logo/legal/help URLs to `https://junchat.yyzs120.cn`.
- Set the push gateway base URL to `https://sygnal-junchat.yyzs120.cn`.
- Hide the create account button.
- Rename bug report application ID to `junchat-ios`.

### Task 4: Distinguish Notification Sounds

**Files:**
- Create: `ElementX/Resources/Sounds/junchat-message.caf`
- Create: `ElementX/Resources/Sounds/junchat-call.caf`
- Modify: `ElementX/Sources/Application/Settings/AppSettings.swift`
- Modify: `ElementX/Sources/Services/ElementCall/ElementCallService.swift`

**Steps:**
- Reuse the existing short message sound as the Junchat message notification sound for the first build.
- Add a distinct short CAF ringtone for incoming calls.
- Set `notificationSoundName` to `junchat-message.caf`.
- Set `CXProviderConfiguration.ringtoneSound` to `junchat-call.caf`.

### Task 5: Regenerate and Verify

**Files:**
- Modify generated Xcode project files through `xcodegen`

**Steps:**
- Run `xcodegen`.
- Run `Tools/Scripts/validate_junchat_ios_config.sh`.
- Run an Xcode build or targeted project-generation/build verification.
- Confirm Apple has Bundle IDs for `com.heyujk.junchat`, `com.heyujk.junchat.nse`, and `com.heyujk.junchat.shareextension`, with App Groups enabled.
- Report APNs/Sygnal gaps separately from code changes.
