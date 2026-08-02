# JunChat iOS Changes

JunChat fork release notes are recorded here. Upstream history remains in `CHANGES.md`.

## 1.9.5 (2026-08-02)

- Improves encrypted message delivery and prevents duplicate local message echoes when recipient devices are unsigned.
- Corrects app icon badge totals and strengthens read-state and notification recovery after backgrounding or process restarts.
- Restores reliable push registration through the canonical Matrix gateway path while preserving compatibility with existing users.
- Improves voice, video, and group-call joining, incoming-call presentation, media reliability, and last-participant termination.
- Adds explicit card or plain-text presentation for web links, plus link copying and message actions from rendered cards.
- Includes contact-visibility recovery, multi-message forwarding, and device-verification prompt controls.
