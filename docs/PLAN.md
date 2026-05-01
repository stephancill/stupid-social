# No Feed Social Plan

## Product Goal

Build a universal macOS and iOS app with xtool that shows a combined social notifications feed without requiring users to open algorithmic feeds. The app starts with X and Farcaster notifications, then expands to posting and additional networks such as Bluesky and Instagram.

## MVP Scope

- Universal SwiftUI app for macOS and iOS using xtool.
- Combined notifications feed for X and Farcaster.
- One account per supported network.
- Manual account setup through a minimal settings form.
- Credentials sync across Apple devices through iCloud Keychain.
- Notification item cache is local-only in the MVP.
- Read state syncs across devices through iCloud read timestamp watermarks.
- Background polling targets roughly 15 minutes where Apple permits it.
- Manual refresh is supported.

## Out Of Scope For MVP

- Posting and cross-posting.
- Bluesky support.
- Multiple accounts per network.
- Syncing full notification items across devices.
- Backend service for polling, normalization, or push notifications.
- App lock, Face ID lock, hidden previews, or custom privacy overlay.
- Cross-network identity merging.

## Platforms

- macOS and iOS from the same SwiftUI codebase.
- Preserve platform-native behavior where possible.
- Use xtool for project build and run workflows.

## Account Setup

### X

- User manually pastes a full browser `Cookie` header.
- App extracts the required cookie values, especially `auth_token` and `ct0`.
- App discards the raw cookie header after extraction.
- App stores only selected required cookie values in iCloud Keychain.
- X integration should be implemented as a native Swift client.
- The patched `twitter-cli` behavior and `docs/CLI_DOCS.md` are references for endpoint behavior, auth assumptions, and side effects.
- Do not shell out to `twitter-cli` for the production app path.

### Farcaster

- User enters a Farcaster username.
- App resolves the username to an FID using Hypersnap `GET /v2/farcaster/user/by-username`.
- App fetches notifications using Hypersnap's read API at `https://haatz.quilibrium.com`.
- No Farcaster token is required for the MVP notification flow.

## Credential Storage

- Store credentials in iCloud Keychain so they sync across the user's Apple devices.
- If iCloud sync is unavailable, fall back to local-only credential/read-state storage and show an actionable sync status.
- Do not log raw credentials, cookie headers, tokens, or derived auth values.
- Show inline reconnect/update controls when credentials are invalid or expired.
- Security posture for MVP is pragmatic: correct Keychain usage, no secret logging, and clear account status.

## Notification Sources

### X

- Use X unread notification count for background polling.
- Background polling must avoid fetching the full X notifications timeline because that can mark notifications read server-side.
- Full X notification fetch should happen only through explicit manual refresh.
- Manual refresh should make only one X full-notifications request.
- Opening the feed should show cached X items plus the latest count until the user manually refreshes.
- Full fetch does not advance app-local read state unless the user explicitly marks notifications as read.

Reference behavior from `docs/CLI_DOCS.md`:

- `notifications-count` reads unread count and should not mark notifications as read.
- `notifications` fetches structured notification objects but may behave like opening the X notifications tab and clear unread state for fetched entries.

### Farcaster

- Use Hypersnap base URL `https://haatz.quilibrium.com`.
- Resolve usernames with `GET /v2/farcaster/user/by-username`.
- Fetch notifications with `GET /v2/farcaster/notifications`.
- Manual refresh should make only this single Farcaster notifications request; do not enrich each notification with extra cast/feed requests during refresh.
- Query by resolved `fid`.
- Supported notification types include:
  - `cast-mention`
  - `cast-reply`
  - `reaction`
  - `follow`
- Hypersnap returns aggregated notification entries.
- Hypersnap seen/write endpoints are not available for this use case because `POST /v2/farcaster/notifications/seen` and `POST /v2/farcaster/notifications/mark_seen` return `501 Not Implemented`.
- Farcaster read state is therefore entirely app-local, synced through iCloud read watermarks.

## Combined Feed

- Default layout is a single combined chronological list.
- Each item shows a network badge.
- The feed shows unread items plus recent cached items.
- Recent notification cache retention is 24 hours.
- Notification items are normalized into one app model for display.
- The normalized notification schema should be a minimal display model.
- Notification item cache remains local per device in the MVP.
- No cross-network identity merging in the MVP.

## Read State

Read state is explicit only.

- Opening the app does not mark notifications as read.
- Refreshing the feed compares incoming notification IDs against the local cache and marks only newly discovered cached items as new locally.
- Opening a notification detail does not mark notifications as read.
- Manual refresh and explicit user actions update app-local read state.

MVP read action:

- Manual refresh marks newly discovered notification IDs as new after a successful refresh; previously cached items are treated as known.

Future explicit read actions:

- Per-notification `Mark read`.
- Per-network or per-account `Mark all as read`.

## iCloud Read Watermarks

The app syncs read state across devices using per-account read timestamp watermarks stored in iCloud when available. If iCloud is unavailable, the app falls back to local-only read watermarks.

Suggested watermark fields:

- `network`: `x` or `farcaster`
- `accountId`: stable network account identifier, such as X user id/handle or Farcaster FID
- `lastReadAt`: timestamp watermark
- `updatedAt`: timestamp for conflict resolution and diagnostics

iCloud sync mechanism:

- Use `NSUbiquitousKeyValueStore` for read watermark sync.
- Keep watermark records small and keyed by network/account.
- Fall back to local `UserDefaults` watermark storage if iCloud KVS is unavailable.

Read evaluation:

- A notification is app-read when `notification.timestamp <= lastReadAt`.
- A notification is app-unread when `notification.timestamp > lastReadAt`.

`Mark all as read` behavior:

- Determine the newest currently loaded notification timestamp for the relevant account/network scope.
- Set that account/network watermark to that timestamp.
- Sync the updated watermark through iCloud.

Notes:

- The watermark syncs even though notification items do not sync in the MVP.
- Farcaster uses this instead of write endpoints.
- X can also use this for app-local cross-device read consistency, independently of X's server-side read state.

## Profile Details

From a notification, the user should be able to view an account detail screen.

The account detail should show:

- Name
- Profile picture
- Follower count
- Following count

The MVP should not attempt to merge or link X and Farcaster actors.

## Automatic And Refresh Behavior

- Manual refresh is always available.
- The app refreshes automatically when entering the foreground.
- X foreground automatic refresh should poll count only and must not full-fetch X notifications.
- Farcaster foreground automatic refresh may fetch notifications because Hypersnap read state is app-local and the API does not mark items read.
- Foreground automatic refresh should cache newly discovered items as pending and surface them through a user-controlled new-items badge before inserting them into the visible feed.

## Future Posting Scope

Posting is not part of the first notification-only MVP, but the architecture should not block it.

Future posting requirements:

- Text posts.
- Media attachments.
- Posting to selected supported channels.
- Account/profile preview in the composer.
- Eventually support X, Farcaster, Bluesky, and Instagram.

For notification-related profile preview, the app should support viewing actor account details from notification items.

## Normalized Notification Schema

Use a minimal display model first. Suggested fields:

- `id`: stable app-level notification id
- `network`: `x` or `farcaster`
- `accountId`: stable account identifier for the viewer account
- `sourceId`: source notification or event id when available
- `type`: normalized notification type
- `timestamp`: source event timestamp used for sorting and read watermark evaluation
- `text`: display text or summary
- `actors`: people/accounts responsible for the notification
- `target`: referenced post, cast, profile, or other object needed for display/navigation
- `isUnread`: derived from the synced read watermark, not persisted as source truth

Do not persist raw source payloads for the MVP unless needed during development diagnostics, and never log or store secrets with notification data.
