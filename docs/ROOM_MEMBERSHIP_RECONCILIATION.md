# Server-confirmed room membership

The additive POST `/_matrix/client/v3/junchat/room_membership` endpoint returns
only the authenticated account's membership in 1..100 requested rooms. The
reader validates origin, complete response keys, membership/event IDs and the
same user, device and access token after the request. Failures and unsupported
servers are not evidence that a room was deleted.

Confirmed non-joined states suppress stale joined-room summaries and cached
navigation. Actual invitations/knocks remain visible. Raw SDK list slots are
retained so subsequent indexed updates still target the correct room. An open
room is dismissed on confirmation, including confirmation during async opening.
Restrictions persist per account; an authenticated rejoin clears them.

## Activation and rollback

`ClientProxy.roomMembershipReconciliationEnabled` defaults to `false`; no
production construction enables it. The reader/store/navigation integration is
implemented and tested, but is not deployed or a device-accepted repair yet.
Existing persisted restrictions are retained even when new queries are disabled.

Deploy the backward-compatible server endpoint first, then verify empty/purged
rooms, invite/rejoin, offline/reconnect and per-account isolation. Verify incoming
calls too: room lookup is shared with call setup and the enabled query has a
10-second timeout. Do not enable this on a release solely because unit tests pass.
Disabling the construction flag stops new queries without deleting data.

This is access reconciliation, not remote erasure. No automatic leave/forget,
media deletion, key deletion or server mutation occurs. Existing old versions
cannot acquire this new client behavior without an update; unmanaged offline
copies and screenshots cannot be erased by a membership response.

## Verification

Focused service and navigation tests cover unsupported/error responses, identity
changes, stale in-flight responses after rejoin/logout, persisted restrictions,
redirect/body bounds, opening races and keeping invitations/SDK indices intact.
Integration full UnitTests gate: 1695 passed, one skipped (1738 passing runs with
dynamic parameters), iPhone 17 Pro simulator / iOS 26.5. Scoped strict SwiftLint
and formatting checks pass. Physical offline/call/push acceptance remains open.
