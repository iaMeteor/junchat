# Junchat Privacy Mode Design

## Goal

Add an internal privacy workflow for iOS:
- A per-room timer button enables 3-minute self-destruction for newly sent messages.
- Entering the emergency PIN `7878` unlocks the app normally but enables protection mode across all conversations.
- The start-chat flow exposes group chat creation from the existing `+` entry.

## Behaviour

### Per-Room Privacy Mode

Each room shows a timer button next to the call button. The button is grey when privacy mode is off and green when it is on. When enabled, the room shows a short banner explaining that newly sent messages will be destroyed after 3 minutes.

Messages sent while privacy mode is enabled are sent normally, then scheduled for redaction after 3 minutes. Redacted messages render with the product wording `信息已销毁`.

### Emergency PIN

Entering `7878` on the existing app-lock screen behaves like a successful unlock, but also turns on a global emergency privacy flag. It should not increment failed PIN attempts and should not force logout.

When the user later unlocks with the real PIN, the emergency privacy flag is cleared and the app returns to normal mode.

### Group Chat Creation

The existing start-chat screen gets a prominent `创建群聊` row. It reuses the existing private encrypted room creation flow and the existing invite-users screen. Invite suggestions should be company-local contacts where possible.

## Implementation Notes

- Store privacy state in `AppSettings`:
  - `junchatPrivacyModeRoomIDs: Set<String>`
  - `junchatEmergencyPrivacyModeEnabled: Bool`
- `RoomScreenViewModel` computes effective privacy mode as emergency mode OR current room ID in the per-room set.
- `TimelineViewModel` checks effective privacy mode when sending new messages and schedules redaction.
- Emergency mode hides the live timeline locally to avoid showing existing decrypted content after `7878`.
- The first implementation is client-side. Server-side guaranteed deletion while offline would require a homeserver worker and is outside this iOS patch.
