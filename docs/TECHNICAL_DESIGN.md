# Technical Design

## Purpose

This document is the source of truth for planned implementation details. `docs/PLAN.md` remains the source of truth for product requirements.

Implementation work should follow this document unless `docs/PLAN.md` changes or an implementation note records a deliberate deviation.

## Expo iOS comparison target

The Expo implementation in `android-app/` has an isolated iOS simulator target, `net.stupidtech.socialexpo`, for comparison with the supported Swift app. Metro selects `.ios` adapters for SwiftUI controls and the Apple WebView/keyboard module, preserving the Android Compose implementations. Shared services, React Query orchestration, SQLite cache and SecureStore sessions remain separate from the Swift app's containers. This target does not yet provide iCloud synchronization or production iOS parity. See `IOS_EXPO_COMPARISON.md` for reproducible simulator builds, observed UI and interaction gaps, and validation coverage.

Standard iOS forms render rows directly inside SwiftUI Form/Section; custom cards use RNHostView with explicit content width. The first untitled section removes the extra hosted-list top margin, while subsequent sections retain native spacing. Search uses a SwiftUI List and the native navigation search bar. Native scroll geometry forwards profile pagination events to the shared React Query screen. Feed typography uses SwiftUI body/subheadline styles, and iOS navigation uses large titles, minimal back labels and SF Symbols.

The custom story composer maps React Native's public system font families to Apple's default, rounded, serif and monospaced designs. A small UIKit module attaches a UIToolbar to the active caption UITextView. It installs/removes the accessory with the editing view's lifecycle and handles the toolbar actions through Expo events. Editing survives iOS software-keyboard dismissal; only explicit Done/background actions end the editing session. Android retains its existing native font families and keyboard behavior.

## Current Scope

The MVP is an iOS SwiftUI app built with xtool. It supports a combined notifications feed for one account per supported network. Previous macOS support was removed.

Out of scope for this technical design:

- Cross-posting and non-Instagram posting.
- Bluesky posting.
- Multiple accounts per network.
- Backend services.
- Full notification item sync across devices.

## Architecture

### Android Expo app

`android-app/` implements all six current networks independently from the Swift UI. React Navigation provides native stack screens; React Query owns asynchronous state. Zod validates credentials, normalized models, and response boundaries. A SQLite database stores account metadata, preferences, normalized notification cache (24-hour retention), and story seen state. Expo SecureStore protects selected credentials with the Android Keystore; Android backup is disabled.

Source-specific TypeScript clients are shared with the Bun command-line probes. Native `expo/fetch` uses explicit selected Cookie headers with `credentials: "omit"` to prevent WebView cookie-jar interference. Cookie rotation handles Expo's folded response headers. Instagram Relay document IDs are discovered at runtime. Bluesky uses PKCE, PAR, ES256 DPoP, nonce negotiation, and coalesced refreshes. X performs one full timeline fetch per foreground/manual refresh and advances its opaque top cursor only after caching succeeds. Android tweet details use the validated `TweetResultByRestId` GraphQL query, unwrap `data.tweetResult.result`, and verify the requested string ID before hydrating a parent reply.

The narrow `src/clientRuntime.ts` contract supplies fetch, credentials and generation guards, random bytes/UUIDs, file bytes and interactive OAuth. `src/expoRuntime.ts` initializes these with the existing Expo adapters before the application renders. Provider modules have no runtime imports of React Native, SQLite, SecureStore, Expo crypto, files or WebBrowser. The command-line implementation in `android-app/scripts/clients/runtime.ts` uses Bun/Node services and an in-memory session. Root `scripts/*-web-client.ts` entry points import the same production provider clients, parsers and session/discovery code. No Python client implementation remains. Interactive Bluesky login stays in the app; the probe accepts an existing OAuth session.

Probe output is redacted, including known credentials echoed in responses/errors. Cookie headers are reduced to selected values. Native simulator credentials are read one network at a time through `simctl`/`plutil`, without a Python dependency. Native Apple date/key representations are converted at the input boundary. Explicit credential exports use atomic mode-0600 files, including after a rotated session's later request fails; probes never write sessions back to the simulator automatically. See `CLIENTS.md` for commands and breaking interface changes.

A local Kotlin Expo module provides selected-domain CookieManager access, AndroidX document-start injection for Spotify session capture, and focused hardware-keyboard navigation in stories. The diagnostic harness remains in `ValidationApp.tsx`; it is not the production entry point. Expo Go cannot load these native modules.

The Expo login screen reads that native cookie store on navigation/load events and every second while focused and foregrounded, including HttpOnly session cookies. Complete selected-cookie sets trigger one React Query connection mutation and return to the account screen after validation. Checks coalesce across navigation and timers; incomplete cookies never trigger validation. A rejected set of required cookie values is not retried until those values change or the user taps Retry connection. Optional cookie/token rotation cannot cause repeated account requests. Leaving the screen stops detection and invalidates pending connection work; failed attempts restore the previous secure credentials, or remove the provisional credentials when no previous session exists, subject to the account generation guard. Existing cookie requirements and provider requests are unchanged.

Refreshes run independently per network and retain successful partial results. Account generations prevent late refreshes from repopulating disconnected accounts. Instagram messages replace the cached unread-thread set on successful inbox refresh; a failed story request preserves the last cached tray. Story media uses Expo Video and Audio. The composer captures its local view into a 1080×1920 JPEG, saves through MediaLibrary, and uses the existing Instagram upload/configure sequence only after an explicit Post action.

Development uses `net.stupidtech.socialvalidation` to preserve the validated session; `APP_VARIANT=production` selects `net.stupidtech.stupidsocial`. There is no iCloud equivalent or server-side synchronization in this port. See `docs/ANDROID.md` for operation and verification; the historical feasibility evidence remains in `docs/ANDROID_VALIDATION.md`.

Android uses a platform adaptive launcher icon with the existing speech-bubble artwork centered on a transparent foreground, a white background, and a matching monochrome layer for themed icons. The mark is 424 pixels wide on the 1024-pixel adaptive canvas; a separate 610-pixel-wide mark on a white 1024-pixel legacy raster covers older launchers. This adds another 30% to the average visible margins compared with the preceding 492/718-pixel marks, or approximately 69% over the original 544/800-pixel marks. Expo prebuild generates all Android densities from the assets configured in `app.config.ts`; the Apple icon remains unchanged.

The Android app uses Expo UI's Jetpack Compose Material components for standard rows, section headings/dividers, switches, buttons, account/search text fields, and filter menus. React Navigation's native stack supplies the Android app bar and back navigation. Material You colors follow system light/dark appearance. React Native ScrollView/FlatList retain refresh, keyboard avoidance, and profile pagination; feed and person rows use Compose text, images, and icons throughout. Passive custom form content uses RNHostView with an explicitly measured height. The Swift app remains the iOS presentation implementation, preserving its existing native Form/Section/List screens without visual changes.

Android form sections use a native Compose Surface with the Material `surfaceContainer` color, 24-dp corners, and 16-dp outer margins. Section headings and footers sit outside the tonal group; spacing replaces the former full-width section dividers. The Surface sits behind normally measured content so native ListItems and React Native media can retain their own layout and touch handling. Transparent ListItem containers reveal that surface, and the outer Android view clips row ripples at the group corners. Connection statuses appear as supporting text beneath their titles. Form typography uses regular 16sp and small 14sp sizes with zero added letter spacing. The shared Android small-text style uses a 20sp line height, matching the secondary labels in Android Settings, and also applies to feed metadata, story-bar labels, profile/detail metadata and search subtitles. Hosted custom row content measures its actual available width after section insets. Material section styling is confined to the Android form adapter; the notification feed's separators and iOS adapter remain unchanged.

Shared presentation rules preserve network order, notification copy, overlapping avatars, inline network badges, previews, and detail section hierarchy. Search retains its bottom field and network filter menu. Profile details retain the centered 80-point avatar and identity/relationship controls, followed by bio, stats, location/joined/website sections and the Instagram three-column post grid. Notification detail retains Network/Activity, source-specific post/thread/message/repository content, then People. Instagram post media keeps horizontal paging and active-page video playback. Settings omits the iCloud comparison note. Native Android padding, typography, touch feedback, switches, and app bars replace the former hand-drawn iOS chrome.

The custom story bar and full-screen viewer still follow `FeedView.swift` and `UnifiedStoryViewer.swift`: 70-point provider-specific circles, a 128-point Android / 112-point iOS vertical pager, matching seen/unseen ordering, segmented progress, metadata overlays, hold/tap/swipe/keyboard navigation, Spotify artwork/library controls, and GitHub repository/user cards. The Instagram composer follows `StoryComposerView.swift` as a custom full-screen modal with no navigation header. It uses the same 44-point floating controls, background color/gradient cycle, aspect-fit photo, centered placeholder, caption styling and bottom Post Story action. Native Android TextInput edits captions directly on the canvas; a keyboard accessory supplies background/font/color controls, with inline Instagram mention suggestions. Captions use normalized center positions, drag-to-trash and scale limits of 0.45–2.5. Android system fonts/icons remain platform-specific; Source Sans Pro supplies the softer alternate sans-serif caption style.

The composer retains its full canvas geometry while Android resizes the window for the keyboard. An offscreen 9:16 composition contains only the photo, background and committed captions, with uniform text scaling matching the Swift export calculation. ViewShot exports that composition at 1080×1920, excluding editing dimming, selection, keyboard and toolbar chrome. Mention metadata is derived only from chosen accounts whose complete handles remain in the caption. Publishing retains the existing explicit confirmation and upload/configure flow.

Feed notification separators use Compose HorizontalDivider with a one-point stroke and host height between FlatList items. A 56-point leading inset aligns with the avatar/text column; a 16-point trailing inset matches the iOS content margin. Subtle neutral gray tints (`#3C3C434A` light / `#54545880` dark) follow appearance, matching the iOS separator treatment. Native notification text uses explicit regular (16sp/20sp line height) and small (14sp/20sp line height) sizes with zero added letter spacing, avoiding Material typography presets that spread out the feed text. A native six-point top inset separates supporting text/thumbnail content from the notification title. Story section labels and usernames share the same small 14sp size, retaining system font scaling; the Android pager has enough height for both 20sp text lines without clipping. The native app bar keeps its platform title size.

The notification feed renders the combined cache without screen-level network/category filters. Its app bar contains Search and Settings only and always uses the Social title. Per-account notification preferences still apply when loading the feed; Search retains its independent network filter.

Android notification cache merging first updates matching provider IDs within their network/account, then deduplicates X follows without target posts by account, event timestamp, and sorted actor IDs. This reconciles rotating timeline IDs and the recommended/standard follow presentation variants while retaining different follow times and actor groups. The newest fetched payload wins; events absent from a refresh retain their original cache expiry. Feed reads apply the same merge immediately to previously saved duplicates, and successful refreshes atomically persist the merged account cache. Other event types retain their provider identities. Cache reads also match the active account ID.

### Shipping app

Use a simple MVVM architecture.

- SwiftUI views own presentation and platform-native UI structure.
- View models expose observable state and user actions.
- Network integrations live behind source-specific clients and adapters.
- Shared feed assembly should stay outside views.
- Prefer small, direct types over broad generic abstractions.

Suggested high-level modules:

- `App`: app entry point, scene setup, dependency construction.
- `Views`: SwiftUI screens and reusable view components.
- `ViewModels`: observable view models for feed, settings, account detail, and refresh state.
- `Models`: normalized app models and persisted SwiftData models.
- `Sources`: network source protocols and source-specific adapters.
- `Storage`: Keychain, UserDefaults, SwiftData, and iCloud KVS helpers.
- `Support`: logging, date handling, errors, and small utilities.

## UI Design

Use built-in SwiftUI and platform primitives wherever possible.

- Feed: a single chronological `List` with network badges.
- Settings: minimal `Form` for account setup/status.
- Account detail: simple detail screen with avatar, name, follower count, and following count.
- Actions: standard pull-to-refresh behavior.
- Avoid custom controls, bespoke styling, and non-native interaction patterns unless the plan changes.

## Data Model

Use a minimal normalized notification display model.

Suggested app model:

```swift
struct NotificationItem: Identifiable, Hashable {
    let id: String
    let network: SocialNetwork
    let accountId: String
    let sourceId: String?
    let type: NotificationType
    let timestamp: Date
    let text: String
    let actors: [NotificationActor]
    let target: NotificationTarget?
}
```

Suggested supporting models:

```swift
enum SocialNetwork: String, Codable {
    case x
    case farcaster
    case bluesky
}

struct NotificationActor: Hashable, Codable {
    let id: String
    let network: SocialNetwork
    let username: String?
    let displayName: String?
    let avatarURL: URL?
}

struct NotificationTarget: Hashable, Codable {
    let id: String
    let text: String?
    let url: URL?
}
```

Keep source-specific response models separate from normalized app models.

## Local Persistence

Use SwiftData for local notification cache.

- Cache notification items locally per device.
- Do not sync notification items through iCloud in the MVP.
- Retain cached notifications for 24 hours.
- Cache only display-safe normalized data needed for the feed and detail views.
- Do not persist raw source payloads unless a future implementation note documents a specific need.

Use UserDefaults for non-secret account metadata.

Examples:

- Configured account identifiers.
- Account display handles/usernames.
- Last successful refresh timestamps.
- Basic account status flags.

Do not store secrets in UserDefaults.

## Credentials

Use iCloud Keychain for credentials.

Credential access behavior:

- Synchronizable across the user's Apple devices.
- Accessible after first device unlock.
- If iCloud Keychain sync is unavailable, save credentials locally and surface local-only sync status.
- Simulator development builds may use non-synchronizable local Keychain storage so account setup and service testing can be exercised without iCloud Keychain entitlements.

X credential handling:

- User pastes a full browser `Cookie` header.
- Parse selected required cookie values from the header.
- Persist only the selected required cookie values, especially `auth_token` and `ct0`.
- Discard the raw cookie header after extraction.

Farcaster credential handling:

- No Farcaster secret is required for MVP notification reads.
- Store only non-secret username/FID metadata outside Keychain.

Bluesky credential handling:

- Use AT Protocol OAuth with PKCE, PAR, and DPoP.
- Store access token, refresh token, DID, handle, DPoP private key, token expiry, and DPoP nonces in Keychain.
- Store non-secret DID/handle/status metadata in UserDefaults.
- The app-side OAuth client uses `https://stupidtech.net/stupid-social/oauth/client-metadata.json` as its public `client_id`; deployment must publish matching client metadata for authorization to complete.

Never log credentials, cookie headers, tokens, or derived auth values.

## Network Source Protocol

Model each notification source behind a common protocol.

Suggested protocol:

```swift
protocol NotificationSource {
    var network: SocialNetwork { get }

    func validateAccount() async throws -> AccountStatus
    func fetchUnreadCount() async throws -> Int?
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
    func fetchProfile(id: String) async throws -> NetworkProfile
}
```

Source implementations may no-op or return `nil` for capabilities that do not exist.

Keep source-specific clients concrete behind adapters:

- `XClient`
- `XNotificationSource`
- `FarcasterClient`
- `FarcasterNotificationSource`
- `BlueskyClient`
- `BlueskyNotificationSource`
- `GitHubActivitySource`

## X Integration

X must use a native Swift client. Do not shell out to `twitter-cli` in the production app path.

Known behavior from `docs/CLI_DOCS.md`:

- Count-only polling should not mark X notifications read.
- A full GraphQL notification timeline fetch does not itself advance X's server-side read cursor.

Implementation rule:

- True background refresh uses count-only behavior if reintroduced.
- Foreground activation and manual refresh use a full X notification fetch.
- After decoding a successful full fetch, `POST /i/api/2/notifications/all/last_seen_cursor.json?cursor=<top-cursor>` using the opaque `Top` cursor from the timeline response.
- Opening the feed shows cached X items first, then foreground activation refresh updates the cache.

Endpoint discovery is a required implementation spike before building the X client.

The spike should document:

- Exact endpoint URLs.
- Required headers.
- Required cookies.
- Query ids or feature flags if applicable.
- Response shapes for count and notifications.
- Side effects observed during fetch.
- Any endpoint behavior that differs from `docs/CLI_DOCS.md`.

Record endpoint discoveries and side effects in `docs/IMPLEMENTATION.md` as work progresses.

## Farcaster Integration

Use Hypersnap at `https://haatz.quilibrium.com`.

Endpoints:

- Resolve username: `GET /v2/farcaster/user/by-username`
- Fetch notifications: `GET /v2/farcaster/notifications`

Notification query:

- Resolve username to FID during setup.
- Fetch notifications by `fid`.
- Support pagination with `cursor` when needed.

Known notification types:

- `cast-mention`
- `cast-reply`
- `reaction`
- `follow`

Hypersnap seen/write endpoints are not part of the MVP because they return `501 Not Implemented`.

## Native Spotify Login

The native iOS login sheet uses an ephemeral WKWebView for Spotify Accounts only. A cookie-store observer completes login as soon as a nonempty, unexpired `sp_dc` cookie valid for the WebPlayer token host is available; `sp_t` and `sp_key` are optional. Main-frame navigation to `open.spotify.com` is canceled before the full player executes. The sheet no longer intercepts browser fetch/XHR headers or waits for browser-generated bearer/client tokens.

Initial credentials carry an expired access-token date so the existing native Spotify client obtains its first bearer through its established token-renewal path before validating friend activity. Network endpoints and renewal behavior remain unchanged. `bun scripts/spotify-web-client.ts --simulator validate-cookie-login` verifies that same flow with only selected cookies and prints a redacted result.

Navigation failures and web-content process termination check for a completed login before displaying a native Retry action. Retry is explicit and retains the ephemeral cookie store within the sheet. Dismissal removes the observer/delegate, stops loading, and invalidates pending cookie callbacks; retry generations reject callbacks from an earlier attempt.

Spotify account identity uses Pathfinder `profileAttributes` with the same Origin, Referer and browser User-Agent as the web client. Fresh client-token responses decode `granted_token`; the resolved username is retained with the session, and token enrichment preserves the client ID. Username lookup remains independent of the buddy-list account-validity check.

## Native Account Identity Repair

Instagram's own-account username, display name and avatar come from the authenticated homepage's `PolarisViewer` module. Verify its numeric identity against the selected session's user ID before accepting it. The stories tray comes from that page's preloaded `xdt_api__v1__feed__reels_tray`, with an empty tray distinguished from a missing or malformed payload. Identity and tray reads request fresh homepage HTML and coalesce overlapping requests; they do not use Direct inbox identity or the rejected standalone tray GraphQL query. Explicit logout, login/challenge redirects and account mismatches require reconnection; generic service and parsing failures preserve saved credentials and known identity/preferences. Story slides still use their individual preloaded story-page payloads.

Full Instagram profile details use the current mobile-web `PolarisProfilePageContentQuery` with a numeric account ID and integrity filters. Username-only lookups resolve the ID from the profile page's `initialRouteInfo.route.rootView.props`, never from the signed-in viewer. Android reuses a known numeric actor ID. Profile posts use `PolarisProfilePostsQuery`, the username, and its `page_info.end_cursor` for pagination. Both clients discover document IDs from current page assets, reuse discovered IDs in memory, and supply Relay provider values from the authenticated homepage's gate/experiment configuration. Missing identity, configuration, query roots or pagination cursors fail explicitly; neither client falls back to the rejected `web_profile_info` or REST user-feed endpoints. Private profiles can legitimately expose counts with an empty posts connection. Query failures are not automatically retried on HTTP 429.

Foreground connection discovery also retries identity lookup for already-connected Instagram accounts missing a username/avatar and Spotify accounts missing a username. Repair preserves Instagram notification and story preferences, and requires no new login when the saved session works.

## Bluesky Integration

Use AT Protocol OAuth through the Bluesky entryway authorization server at `https://bsky.social`.

OAuth requirements:

- Public native client metadata hosted at the exact `client_id` URL.
- Native redirect URI `net.stupidtech:/oauth/bluesky/callback` registered in `Info.plist` and in the client metadata document. The scheme follows atproto's private-use URI rule for discoverable native clients: the `client_id` host reversed.
- PKCE S256 for the authorization code flow.
- Pushed Authorization Requests via `/oauth/par`.
- DPoP proofs for PAR, token, refresh, and authorized PDS requests.

API endpoints:

- Fetch notifications: `GET /xrpc/app.bsky.notification.listNotifications`
- Mark fetched notifications read: `POST /xrpc/app.bsky.notification.updateSeen` with `{"seenAt":"<ISO-8601>"}` against the user's PDS.
- Validate/profile: `GET /xrpc/app.bsky.actor.getProfile`
- Search profiles: `GET /xrpc/app.bsky.actor.searchActors`
- Hydrate post details: `GET /xrpc/app.bsky.feed.getPostThread`

Bluesky notifications use the same cache and immediate-refresh behavior as other sources. A successful notification load calls `app.bsky.notification.updateSeen` before returning the fetched items.

## Decoding Strategy

Use strict `Codable` response models.

- Define source-specific response structs for each endpoint.
- Decode required fields strictly.
- Treat schema mismatches as integration errors.
- Normalize source responses into `NotificationItem` immediately after decoding.

If X endpoint responses prove unstable during the required spike, document the issue before changing this strategy.

GitHub's For You endpoint is HTML rather than JSON. Parse the JSON objects embedded in `data-hydro-view` and `data-hydro-click` attributes instead of presentation text. Normalize all underlying rollup events, then group them by actor for story display.

## Feed Assembly

The feed view model should request data through a feed service rather than talking directly to network clients.

Feed service responsibilities:

- Load cached notifications from SwiftData.
- Trigger source refreshes according to user action or background policy.
- Normalize and merge source results.
- Apply 24-hour retention cleanup.
- Sort by timestamp descending.
- Return the full recent chronological cache after refresh.

Manual refresh behavior:

- Fetch Farcaster notifications.
- Fetch X full notifications.
- Merge results into local SwiftData cache.
- Return merged notifications immediately after updating the cache.

Open/feed-load behavior:

- Load cached notifications.
- Trigger foreground activation refresh when the scene becomes active.

## Foreground Automatic Refresh

Use scene phase changes for automatic refresh when the app enters the foreground. Do not use `BGTaskScheduler` for the MVP refresh path.

Design expectations:

- Trigger an automatic refresh on `scenePhase == .active`.
- X foreground automatic refresh performs a full notification fetch.
- Successful X and Bluesky full fetches advance provider-side read state before the source refresh completes. Instagram's activity `POST /api/v1/news/inbox/` has the equivalent activity-read side effect; Instagram DM threads are intentionally not marked read.
- Farcaster foreground automatic refresh may fetch notifications because it does not alter server-side read state.
- Foreground automatic refresh updates the local cache and visible feed immediately.

## Account Status And Errors

Expose inline account status in settings.

Suggested statuses:

- Not configured.
- Valid.
- Invalid credentials.
- iCloud unavailable.
- Network unavailable.
- Service error.

Credential failures should show inline reconnect/update controls.

Errors should be user-actionable without exposing secrets or raw request data.

## Logging And Diagnostics

Use minimal `OSLog`.

- Never log secrets.
- Prefer privacy annotations and redaction.
- Log high-level events such as refresh start/success/failure and source status.
- Do not log request bodies, response bodies, cookie headers, tokens, or raw payloads.
- Do not write persistent file logs in the MVP.

## Testing Strategy

Require unit tests for core logic.

Unit test targets:

- Cookie header parsing and selected-cookie extraction.
- Hypersnap response decoding.
- X response decoding for `TimelineNotification` / `NotificationsTimeline` GraphQL entries.
- Source-specific normalization into `NotificationItem`.
- 24-hour cache retention behavior.
- Feed merge and sort behavior.

Add integration tests where practical.

- Network integration tests should be opt-in.
- Live tests must not require secrets in source control.
- Live tests must not log credentials or response bodies.
- Prefer sanitized fixtures for repeatable parser and normalization tests.

## Verification

After meaningful implementation changes, verify with the repository's build/test tooling.

Expected verification once the app is scaffolded:

- Swift tests pass.
- xtool build succeeds.
- xtool run behavior is checked when feasible.

## Profile Relationships

Profile detail (reached from Search) exposes Follow/Unfollow for X and Instagram, plus an X post-notifications toggle.

- `NetworkProfile` carries `isFollowing` (one-sided "current account follows this target") and `isNotifiedForPosts`. These are separate from the existing `isMutualFollow` badge.
- A `RelationshipMutating` capability protocol (`setFollowing`, `setPostNotifications`) is registered per network and invoked through `FeedService.setFollowing` / `setPostNotifications`. `ProfileDetailView` updates optimistically and reverts on failure.
- X uses the legacy REST endpoints: `POST /i/api/1.1/friendships/create.json` (follow), `.../destroy.json` (unfollow), and `.../update.json` (bell/bell-off via `device=true|false`). These require no GraphQL query ID.
- Instagram uses the mobile-web Relay mutations with runtime doc-ID discovery: `usePolarisFollowUserFollowMutation`/`usePolarisFollowUserUnfollowMutation` with root fields `xdt_create_friendship`/`xdt_destroy_friendship`.
- The X bell is independent of follow state and its initial state is best-effort (the profile GraphQL does not expose the notify flag today).

## Posting

Instagram story posting is current scope and uses the mobile web API path validated by `scripts/instagram-web-client.ts`. Implementation expectations:

- Keep the story composer UI local and simple.
- Render the composer output to a 1080x1920 WebP before upload when native WebP encoding is available; fall back to JPEG while the app does not bundle a WebP encoder.
- Use the cookie-authenticated mobile web Instagram client for story photo uploads.
- Bootstrap `https://www.instagram.com/` with an iPhone Safari user agent, parse web runtime state (`csrf_token`, `lsd`, `fb_dtsg`, revision/session metadata), and dynamically discover Relay document IDs from Instagram web bundles.
- Upload image bytes to `https://i.instagram.com/rupload_igphoto/fb_uploader_<upload_id>` with web rupload headers and finalize with web `POST https://www.instagram.com/api/v1/media/configure_to_story/` form fields.
- Do not hardcode Instagram Relay document IDs in source; discover them at runtime from the current web bundles.
- Keep posting scoped to Instagram photo stories; do not add cross-posting abstractions until another network is implemented.
- In the combined All Stories context, use a native inline menu from the story `+` affordance to choose the destination. Instagram is currently the only destination. In the Instagram stories context, skip the menu and open the composer directly.

## Instagram Direct Notifications

Unread Instagram DM support uses the same cookie-authenticated mobile web request stack as the rest of the Instagram integration.

- Fetch direct inbox threads with `GET /api/v1/direct_v2/inbox/?visual_message_return_type=unseen&thread_message_limit=10&persistentBadging=true&limit=20`.
- Include mobile web headers (`X-IG-App-ID: 1217981644879628`, `X-ASBD-ID`, CSRF, LSD when present, web session/device IDs, and explicit selected-cookie header).
- Derive unread DM threads locally by comparing `last_permanent_item.timestamp` against `last_seen_at[viewer_id].timestamp`, ignoring latest messages sent by the viewer.
- Normalize unread threads as `.message` `NotificationItem`s in the Instagram feed.
- Messaging settings expose a Direct Messages toggle and a Posts and Reels toggle. When Posts and Reels is disabled, Direct threads whose latest item is `xma_clip` or `xma_media_share` are filtered out while text/story-reply messages can still appear.
- Direct inbox failures are isolated from `news/inbox` notification failures so regular Instagram notifications continue to show if Direct is gated by a server prompt or transient response.
