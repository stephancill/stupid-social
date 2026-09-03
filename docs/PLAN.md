# No Feed Social Plan

## Product Goal

Build an iOS app with xtool that shows a combined social network notifications feed without requiring users to open algorithmic feeds. The app started as a universal macOS and iOS app but is now iOS-only. The app started with X and Farcaster notifications and now includes Instagram stories, Spotify listening stories, Instagram story posting, and Bluesky notifications.

## MVP Scope

- Universal iOS app using xtool (previous macOS support was removed).
- Combined notifications feed for X and Farcaster.
- One account per supported network.
- Manual account setup through a minimal settings form.
- Credentials sync across Apple devices through iCloud Keychain.
- Notification item cache is local-only in the MVP.
- Background polling targets roughly 15 minutes where Apple permits it.
- Manual refresh is supported.
- Instagram story posting is supported from the in-app story composer.
- Unread Instagram direct message threads are shown in the main notification feed when Instagram is connected.
- Instagram messaging settings allow users to suppress DM notifications whose latest item is a shared post or reel.
- Bluesky notifications are supported through the AT Protocol OAuth flow.
- GitHub's authenticated For You activity is shown in the stories bar, grouped into one story reel per actor.
- GitHub "starred your repository" events are notifications about the viewer's own repos, so they appear in the main notifications feed instead of the stories bar.
- Spotify and GitHub story seen state syncs across the user's devices through iCloud Key-Value storage (new capability, see `App.entitlements`). Full notification items remain local-only.

## Out Of Scope For MVP

- Cross-posting.
- Multiple accounts per network.
- Syncing full notification items across devices.
- Backend service for polling, normalization, or push notifications.
- App lock, Face ID lock, hidden previews, or custom privacy overlay.
- Cross-network identity merging.

## Platform

- iOS only. The previous macOS target was removed.
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

### Bluesky

- User signs in through AT Protocol OAuth using a native app redirect URI.
- The app uses PKCE, PAR, and DPoP as required by the atproto OAuth profile.
- Access and refresh tokens are stored in Keychain with the same local-only fallback behavior as other credentials.

### GitHub

- User signs in through an embedded GitHub web login.
- Store only the selected `user_session` and `__Host-user_session_same_site` cookies in Keychain.
- Fetch the authenticated HTML `GET /conduit/for_you_feed` endpoint and parse its machine-readable Hydro metadata.
- Show GitHub activity in the stories bar, grouped by actor.
- "Starred your repository" events (target repo owner equals the viewer username) route to the main notifications feed, not the stories bar. GitHub aggregates several people who starred the same owned repo into one card with `NAME</a> starred` rows; every such actor row surfaces as its own notification.
- The OAuth `client_id` is `https://stupidtech.net/stupid-social/oauth/client-metadata.json`; login requires that exact public client metadata document to be hosted before authorization can complete.

## Credential Storage

- Store credentials in iCloud Keychain so they sync across the user's Apple devices.
- If iCloud sync is unavailable, fall back to local-only credential storage and show an actionable sync status.
- Do not log raw credentials, cookie headers, tokens, or derived auth values.
- Show inline reconnect/update controls when credentials are invalid or expired.
- Security posture for MVP is pragmatic: correct Keychain usage, no secret logging, and clear account status.

## Notification Sources

### X

- Use X unread notification count only for future background polling paths that run while the app is not foregrounded.
- Foreground activation and manual refresh should full-fetch X notifications so the feed stays current when the app is opened.
- Each foreground/manual refresh should make only one X full-notifications request.
- Opening the feed first shows cached X items, then foreground activation refresh updates the cache when credentials are available.

Reference behavior from `docs/CLI_DOCS.md`:

- `notifications-count` reads unread count and should not mark notifications as read.
- `notifications` fetches structured notification objects but does not itself clear X's unread badge.
- After a successful foreground/manual full fetch, advance X's server-side last-seen cursor to the fetched timeline's opaque top cursor.

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
- The app does not track separate Farcaster read state.

### Bluesky

- Fetch notifications with `GET /xrpc/app.bsky.notification.listNotifications` using DPoP-bound OAuth access tokens.
- Supported notification reasons include mentions, replies, likes, reposts, quotes, and follows.
- After a successful notification fetch, mark Bluesky notifications seen through the standard `app.bsky.notification.updateSeen` API.

## Combined Feed

- Default layout is a single combined chronological list.
- A horizontal stories bar appears above the list for story-like activity.
- The stories bar currently shows Spotify listening activity; Instagram stories are planned for the bar later.
- The story viewer supports hardware-keyboard navigation (external/iPad keyboards and the Mac-compatibility path): Left/Right for prev/next slide, Shift+Left/Shift+Right for prev/next user, and Space to pause the slide timer.
- Instagram story likes remain in the main notifications feed.
- Unread Instagram DMs remain in the main notifications feed.
- Spotify listening activity is not shown in the main notifications list.
- GitHub For You activity is not shown in the main notifications list, except "starred your repository" events, which route to the notifications feed.
- GitHub story tiles group stars, follows, created repositories, and repository forks by actor, with each activity represented as a slide.
- Spotify listening story tiles show the album/track artwork as the thumbnail with the listener's avatar overlaid in the bottom-right corner.
- Tapping a Spotify listening story opens the Listening detail screen.
- Each item shows a network badge.
- The feed shows newly discovered notification items plus known recent cached items.
- Successful refreshes insert fetched notifications directly into the visible chronological feed.
- Recent notification cache retention is 24 hours.
- Notification items are normalized into one app model for display.
- The normalized notification schema should be a minimal display model.
- Notification item cache remains local per device in the MVP.
- No cross-network identity merging in the MVP.

## Profile Details

From a notification or search result, the user should be able to view an account detail screen.

The account detail should show:

- Name
- Profile picture
- Follower count
- Following count
- Follow/Unfollow button for networks that support it (X and Instagram in current scope).
- For X, a post-notifications (bell) toggle. Turning it on/off is independent of follow state.

The MVP should not attempt to merge or link X and Farcaster actors.

## Automatic And Refresh Behavior

- Manual refresh is always available.
- The app refreshes automatically when entering the foreground.
- X foreground automatic refresh should full-fetch X notifications, then explicitly advance the server-side last-seen cursor.
- Successful foreground/manual loads mark fetched X, Instagram activity, and Bluesky notifications read on their providers. Instagram DMs remain unread until the user opens the conversation.
- Farcaster foreground automatic refresh may fetch notifications because Hypersnap does not alter server-side notification state.
- Foreground automatic refresh should update the visible feed immediately after caching fetched items.

## Future Posting Scope

Posting is now in current scope for Instagram stories. Other posting surfaces remain future scope.

Current posting requirements:

- Render a local story composition into a 1080x1920 image.
- Post image stories to the connected Instagram account.
- Show the user's own Instagram story entry first in the stories bar with their profile picture and a `+` affordance that opens the composer.
- In the combined All Stories bar, the `+` affordance first asks for the story destination; Instagram is the only current destination. In the Instagram-only stories bar, Instagram is implied and the `+` opens the composer directly.

Future posting requirements:

- Text posts.
- Media attachments.
- Posting to selected supported channels beyond Instagram stories.
- Account/profile preview in the composer.
- Eventually support X, Farcaster, and Bluesky posting.

For notification-related profile preview, the app should support viewing actor account details from notification items.

## Normalized Notification Schema

Use a minimal display model first. Suggested fields:

- `id`: stable app-level notification id
- `network`: supported social network, such as `x`, `farcaster`, or `bluesky`
- `accountId`: stable account identifier for the viewer account
- `sourceId`: source notification or event id when available
- `type`: normalized notification type
- `timestamp`: source event timestamp used for sorting
- `text`: display text or summary
- `actors`: people/accounts responsible for the notification
- `target`: referenced post, cast, profile, or other object needed for display/navigation

Do not persist raw source payloads for the MVP unless needed during development diagnostics, and never log or store secrets with notification data.
