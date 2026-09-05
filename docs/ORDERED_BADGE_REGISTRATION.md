# Ordered badge registration

New installations keep ordered badges disabled. This code is not a rollout.
Enable only after Synapse snapshots and the Sygnal ordered APNs relay have
passed coordinated deployment and physical-device acceptance.

The notification manager first fetches an authenticated snapshot before adding
both `junchat-badge=messages-v1` and `junchat-badge-order=state-v1` to its pusher.
If bootstrap fails before a pin exists, the current legacy endpoint remains
usable. A later successful foreground, lifecycle or room-list reconciliation
refresh upgrades the pusher using the device token received in that session.
Failed registration is retried on a later reconciliation without clearing the
pin. Successful registration is not repeated on every badge refresh.

Pusher requests are serialized within a session. A newer device token makes
the old request ineligible to update local settings or remove superseded
pushers. Session replacement cancels registration bookkeeping and forgets the
in-memory token; it cannot reuse a previous account's saved key. Checks after
asynchronous operations reject late completions, including same-user relogin.
Cancellation cannot retract a request that already reached the server.

A persisted authenticated pin is sticky: disabling the rollout flag does not
stop authenticated refresh, ordered pusher registration, or background snapshot
handling for that account. Otherwise legacy updates could overwrite the ordered
badge, or the pin could remain frozen indefinitely. Logout clears the ledger.
A server rollback must retain the snapshot endpoint/relay or use a separately
tested pin migration; no rollback migration is implemented here.

Focused tests are in `NotificationManagerTests`. Required physical checks:
failed initial bootstrap and recovery; delayed zero after four messages; token
rotation; logout/relogin; foreground and background refresh; and old/new clients
together. Background delivery remains subject to iOS scheduling. These tests
do not prove real APNs delivery or remove already delivered legacy pushes.
