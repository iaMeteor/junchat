# Privacy Message Indicator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a very small green timer indicator on messages sent while JunChat privacy mode is active.

**Architecture:** Keep the privacy indicator as local UI state in `TimelineViewState`, derived from messages the current client scheduled for automatic redaction. Do not change Matrix event payloads or server behavior. Render the indicator in the common bubble styler so text bubbles and future bubbled message types can share it.

**Tech Stack:** Swift, SwiftUI, Swift Testing, Element X timeline view models.

---

### Task 1: Track Privacy-Controlled Timeline Items

**Files:**
- Modify: `ElementX/Sources/Screens/Timeline/TimelineModels.swift`
- Modify: `ElementX/Sources/Screens/Timeline/TimelineViewModel.swift`
- Test: `UnitTests/Sources/TimelineViewModelTests.swift`

**Step 1: Write the failing test**

Add a test that enables privacy mode, sends a message, and expects the sent message's unique ID to appear in `viewModel.state.privacyControlledTimelineItemIDs`.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme UnitTests -testPlan UnitTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath /Users/julius/Library/Developer/Xcode/DerivedData/ElementX-privacy-indicator -only-testing:UnitTests/TimelineViewModelTests/privacyModeMessageIsMarkedAsPrivacyControlled`

Expected: FAIL because the state property does not exist yet.

**Step 3: Write minimal implementation**

Add `privacyControlledTimelineItemIDs` to `TimelineViewState`, track pending privacy message bodies in `TimelineViewModel`, refresh the ID set when timeline items are rebuilt, and remove pending markers after the redaction attempt.

**Step 4: Run test to verify it passes**

Run the same targeted test and expect PASS.

### Task 2: Render The Small Green Timer Dot

**Files:**
- Modify: `ElementX/Sources/Screens/Timeline/View/Style/TimelineItemBubbledStylerView.swift`

**Step 1: Add bubble overlay**

Render a very small green circular badge with a timer icon when `context.viewState.privacyControlledTimelineItemIDs` contains the item ID.

**Step 2: Verify build**

Run targeted tests and build the app for simulator or device.
