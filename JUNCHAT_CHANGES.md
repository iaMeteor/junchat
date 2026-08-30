# JunChat iOS Changes

JunChat fork release notes are recorded here. Upstream history remains in `CHANGES.md`.

## 1.9.8 (2026-08-30)

- Refreshes conversation previews after messages are removed or expire.
- Prevents stale notification registrations from producing duplicate pushes.
- Makes incoming voice calls start on the earpiece unless speaker is selected for that call.

## 1.9.6 (2026-08-27)

- Restores call controls after they auto-hide on iOS and improves voice and video call audio stability.

## 1.9.5 (2026-08-02)

- Improves encrypted message delivery and prevents duplicate local message echoes when recipient devices are unsigned.
- Corrects app icon badge totals and strengthens read-state and notification recovery after backgrounding or process restarts.
- Restores reliable push registration through the canonical Matrix gateway path while preserving compatibility with existing users.
- Improves voice, video, and group-call joining, incoming-call presentation, media reliability, and last-participant termination.
- Adds explicit card or plain-text presentation for web links, plus link copying and message actions from rendered cards.
- Includes contact-visibility recovery, multi-message forwarding, and device-verification prompt controls.
