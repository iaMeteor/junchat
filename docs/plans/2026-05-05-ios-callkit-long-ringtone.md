# Junchat iOS CallKit Long Ringtone Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make incoming iOS calls ring with a phone-like duration until CallKit stops the call on answer, reject, remote hangup, or timeout.

**Architecture:** Keep incoming calls on the existing CallKit path and replace the short `junchat-call.caf` with a longer custom ringtone under Apple's notification sound duration limit. Add a local validation check so the call sound cannot regress to a short alert sound.

**Tech Stack:** iOS CallKit, APNs notification service extension, CoreAudio CAF, `afinfo`, `afconvert`, shell validation.

---

### Task 1: Add Ringtone Duration Validation

**Files:**
- Modify: `Tools/Scripts/validate_junchat_ios_config.sh`

**Step 1: Write the failing validation**

Add a check that reads `ElementX/Resources/Sounds/junchat-call.caf` with `afinfo` and fails unless the estimated duration is between 25 and 29.9 seconds.

**Step 2: Run validation to verify it fails**

Run: `./Tools/Scripts/validate_junchat_ios_config.sh`

Expected: FAIL because the current ringtone is about 1.8 seconds.

### Task 2: Replace the CallKit Ringtone Asset

**Files:**
- Modify: `ElementX/Resources/Sounds/junchat-call.caf`

**Step 1: Generate the ringtone**

Create a 28-second loopable WAV with a calm phone-ring cadence, then convert it to CAF IMA4 using `afconvert`.

**Step 2: Verify the validation passes**

Run: `./Tools/Scripts/validate_junchat_ios_config.sh`

Expected: PASS.

### Task 3: Build and Install

**Files:**
- Verify built app bundle under DerivedData.

**Step 1: Build for the connected iPhone**

Run: `xcodebuild -project ElementX.xcodeproj -scheme ElementX -configuration Debug -destination 'platform=iOS,id=00008150-001264C60163401C' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`

Expected: `** BUILD SUCCEEDED **`.

**Step 2: Install and launch**

Run: `xcrun devicectl device install app --device 00008150-001264C60163401C .../Junchat.app`, then launch `com.heyujk.junchat`.

Expected: app installs and launches.
