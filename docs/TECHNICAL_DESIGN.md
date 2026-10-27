# Technical Design

## Purpose

This document is the source of truth for planned implementation details. `docs/PLAN.md` remains the source of truth for product requirements.

Implementation work should follow this document unless `docs/PLAN.md` changes or an implementation note records a deliberate deviation.

## Current Scope

The MVP is an iOS SwiftUI app built with xtool. It supports a combined notifications feed for one account per supported network. Previous macOS support was removed.

Out of scope for this technical design:

- Cross-posting and non-Instagram posting.
- Bluesky posting.
- Multiple accounts per network.
- Backend services, except the stateless Apron push relay (`workers/push-relay`).
- Full notification item sync across devices.

## Architecture

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

Initial credentials carry an expired access-token date so the existing native Spotify client obtains its first bearer through its established token-renewal path before validating friend activity. Network endpoints and renewal behavior remain unchanged. `scripts/spotify-web-client.py validate-cookie-login` verifies that same flow with only selected cookies and prints a redacted result.

Navigation failures and web-content process termination check for a completed login before displaying a native Retry action. Retry is explicit and retains the ephemeral cookie store within the sheet. Dismissal removes the observer/delegate, stops loading, and invalidates pending cookie callbacks; retry generations reject callbacks from an earlier attempt.

Spotify account identity uses Pathfinder `profileAttributes` with the same Origin, Referer and browser User-Agent as the web client. Fresh client-token responses decode `granted_token`; the resolved username is retained with the session, and token enrichment preserves the client ID. Username lookup remains independent of the buddy-list account-validity check.

## Native Account Identity Repair

Instagram's own-account username, display name and avatar come from the authenticated homepage's `PolarisViewer` module. Verify its numeric identity against the selected session's user ID before accepting it. The stories tray comes from that page's preloaded `xdt_api__v1__feed__reels_tray`, with an empty tray distinguished from a missing or malformed payload. Identity and tray reads request fresh homepage HTML and coalesce overlapping requests; they do not use Direct inbox identity or the rejected standalone tray GraphQL query. Explicit logout, login/challenge redirects and account mismatches require reconnection; generic service and parsing failures preserve saved credentials and known identity/preferences. Story slides still use their individual preloaded story-page payloads.

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

Instagram story posting is current scope and uses the mobile web API path validated by `scripts/instagram-web-client.py`.Implementation expectations:

- Keep the story composer UI local and simple.
- Render the composer output to a 1080x1920 WebP before upload when native WebP encoding is available; fall back to JPEG while the app does not bundle a WebP encoder.
- Use the cookie-authenticated mobile web Instagram client for story photo uploads.
- Bootstrap `https://www.instagram.com/` with an iPhone Safari user agent, parse web runtime state (`csrf_token`, `lsd`, `fb_dtsg`, revision/session metadata), and dynamically discover Relay document IDs from Instagram web bundles.
- Upload image bytes to `https://i.instagram.com/rupload_igphoto/fb_uploader_<upload_id>` with web rupload headers and finalize with web `POST https://www.instagram.com/api/v1/media/configure_to_story/` form fields. Close Friends posts add `audience=besties` to the configure form.
- Do not hardcode Instagram Relay document IDs in source; discover them at runtime from the current web bundles.
- Keep posting scoped to Instagram photo stories; do not add cross-posting abstractions until another network is implemented.
- In the combined All Stories context, use a native inline menu from the story `+` affordance to choose the destination. Instagram is currently the only destination. In the Instagram stories context, skip the menu and open the composer directly.

## Instagram Direct Notifications

Unread Instagram DM support uses the same cookie-authenticated mobile web request stack as the rest of the Instagram integration.

- Fetch direct inbox threads with the web inbox GraphQL query `PolarisDirectInboxMobileQuery` (see `docs/IMPLEMENTATION.md`); `direct_v2` REST no longer serves accounts on the new web inbox.
- Include mobile web headers (`X-IG-App-ID: 1217981644879628`, `X-ASBD-ID`, CSRF, LSD when present, web session/device IDs, and explicit selected-cookie header).
- Derive unread DM threads locally by comparing the newest message's `timestamp_ms` against the viewer's `slide_read_receipts` watermark, ignoring latest messages sent by the viewer.
- Normalize unread threads as `.message` `NotificationItem`s in the Instagram feed.
- Messaging settings expose a Direct Messages toggle and a Posts and Reels toggle. When Posts and Reels is disabled, Direct threads whose latest message is `MESSAGE_INLINE_SHARE` are filtered out while text/story-reply messages can still appear.
- Direct inbox failures are isolated from `news/inbox` notification failures so regular Instagram notifications continue to show if Direct is gated by a server prompt or transient response.

## Apron Push

Apron push (protocol §4.9) reaches the device through a Web Push endpoint that forwards to APNs.

- **Relay (`workers/push-relay`, `push.stupidtech.net`):** a Cloudflare Worker with no storage. `POST /register {token, environment, vapidKey}` returns `https://push.stupidtech.net/apron/<id>`, where `id` is the APNs device token, the environment (`sandbox`/`production`) and the server's VAPID public key, sealed with AES-256-GCM under `RELAY_SECRET`. `POST /apron/<id>` is a Web Push endpoint (RFC 8030): it requires `Content-Encoding: aes128gcm` and a valid `vapid` `Authorization` (RFC 8292) whose `aud` is the relay origin and whose key is the one sealed in the id, so only the registered server can push to it. It forwards the ciphertext unchanged as `webpush` (base64url) in an APNs alert with `mutable-content: 1` and a generic "Apron / New message" fallback. `TTL` becomes `apns-expiration`, and `Urgency` `low`/`very-low` becomes priority 5 (otherwise 10). APNs `410`/`BadDeviceToken`/`DeviceTokenNotForTopic` answer `410`, so the Apron server drops the registration (§4.9.1). Secrets: `RELAY_SECRET` (32 random bytes, base64url) and `APNS_PRIVATE_KEY` (the `.p8`). Vars: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`.
- **Registration (`ApronPushService`):** on every signed-in connection to a server whose `server.push` has `webpush`, if push is on for that server on this device, notifications are authorized and an APNs token exists, the app creates or reuses the registration for (server, user), fetches a relay endpoint when the device token or VAPID key changed, and sends `push_register {kind: "webpush", url, push_id, keys, wake: ["mentions", "replies", "private"]}`. A replaced endpoint is unregistered. Removing a server, or turning its notifications off, sends `push_unregister` on the open connection and forgets the keys.
- **Keys and shared state (`NoFeedSocialPush`):** a small module shared by the app and the Notification Service Extension. `ApronPushStore` keeps registrations (push id, server, user, P-256 private key, auth secret, endpoint, room titles, rooms named for members) in `apron-push.json` in the App Group `group.tech.stupid.StupidSocial`, with `completeUntilFirstUserAuthentication` protection so the extension can read it while the phone is locked. These keys only decrypt pushes for this device, so they are device-local and not in the iCloud Keychain.
- **Extension (`NoFeedSocialNotificationService`):** decrypts `webpush` (RFC 8291) by trying each registration's keys and drops the result unless its `push_id` is known. `ApronPushNotification` lays it out: title = the sender (`from.name`, else a known name, else `user_id`) in DMs, and "<sender> in <room title>" in other rooms; subtitle = the server host; body = `ApronPushText.plain` (Markdown links, images, emphasis, code and quote/heading markers removed; `@user_id` of known users as `@Name`), or "New message" when the server left the text out. Thread identifier `apron|<server URL>|<room_id>`, category `apron.message`, `userInfo.apron = {server, room, message, direct}`. It then donates an incoming `INSendMessageIntent` (sender `INPerson` with the avatar downloaded from the registration's `avatarURLs`, 5 s timeout; every message is one-to-one from a person named like the title, since a group conversation would be titled with the room alone; `conversationIdentifier` = thread) and returns `content.updating(from:)`, so the sender's avatar replaces the app icon (Communication Notifications). If donation fails or time runs out, the plain content is delivered. Without the `usernotifications.filtering` entitlement it can't suppress a push, so an unreadable one keeps the generic alert. The registration carries, per (server, user), room titles, DM rooms, user names and linked (`https`) avatar URLs, refreshed on every connection and room change.
- **Communication Notifications:** the app (not the extension) has `com.apple.developer.usernotifications.communication` and `com.apple.developer.siri`, and `INSendMessageIntent` in `NSUserActivityTypes`, as in stupid-wallet-2. The App Store Connect API can't enable Communication Notifications, so it was turned on in the developer portal; Siri is `SIRIKIT` in `stupid-app.yml`.
- **Taps and replies (`AppDelegate`, `NotificationRouter`):** a tap sets `NotificationRouter.pendingChat`; `ContentView` switches the home pager to Chats (`HomePager` now applies programmatic page changes) and `ChatsView` opens the room, first closing any other open chat (a showing `navigationDestination(item:)` doesn't replace itself). The `apron.reply` text action posts with `ApronService.send` from the background, as a reply to the notified message in rooms and a plain message in DMs, using the UI's `ApronService` when it exists and a standalone one otherwise (a background launch has no scene). Success clears the room's notifications; failure posts a "Reply not sent" notification. A connection opened in the background is closed afterwards so the server keeps pushing.
- **Room levels (`ApronRoomNotifications`):** None is `status {room_id, mute: true}`. Rooms default to mentions and replies, and private rooms to every message (the `private` scope). Other levels need per-room wake scopes, a proposed extension: servers advertise `server.push.room_wake: true` and accept `status {room_id, wake: [scopes] | null}`, which replaces the registration's scopes for that room (`["joined", "mentions", "replies"]` for all messages, `["mentions", "replies"]` for mentions only) and `null` clears; servers resend room wakes at sign-in like mutes. Until then those levels aren't offered. `ApronConnection` records `status` mutes and room wakes from every frame, including the ones sent right after sign-in (§4.5.4).

## Telegram

Telegram has no HTTP API for user accounts, so the app is its own MTProto 2.0 client, written in Swift with no dependencies (stupid-app couldn't build binary targets such as TDLib then; since 0.0.22 it links static-library XCFrameworks). `scripts/telegram-client.py` is the dependency-free probe it is validated against.

- **Schema (`Resources/TelegramSchema.tl`):** the official TL schema (core.telegram.org/schema, layer in the first line) as plain TL, built by `scripts/telegram-schema.py`. `TLSchema` parses it at first use, and `TLWriter`/`TLReader` (`TelegramTL.swift`) encode and decode any constructor or method from it into `TLValue`/`TLObject` trees, including flags, `true` flags, boxed and bare vectors, and `gzip_packed`. Calls are written as `TLObject("messages.getHistory", [...])`; nothing is hand-modelled except the few fields the app reads. Updating the layer is regenerating the file.
- **Crypto (`TelegramCrypto.swift`):** AES-256-IGE over CommonCrypto ECB, SHA-1/256 from CryptoKit, PBKDF2-SHA512 from CommonCrypto, a small `BigUInt` with Montgomery exponentiation for 2048-bit DH, RSA and SRP, Pollard–Brent factorization of `pq`, RSA_PAD, and SRP for 2FA. The RSA key (fingerprint checked against `resPQ`) and the DH prime (checked on every exchange) are constants.
- **Transport and session (`TelegramMTProto.swift`):** TCP to the DC's IPv4 address on port 443 with the intermediate transport (`0xeeeeeeee`, length-prefixed packets). `MTProtoSession` (an actor) creates the auth key when the DC has none (req_pq_multi → req_DH_params → set_client_DH_params), then runs one encrypted session: msg ids from the server-corrected clock, seq numbers, results matched to calls by `req_msg_id`, containers, acks, `bad_server_salt` and clock fixes (resending the call), `new_session_created`, a `ping_delay_disconnect` every 45 s, and updates passed to an observer. A 4-byte `-404` transport error means the DC dropped the key. A write that fails (iOS drops sockets while the app is suspended: `NWError` POSIX 57, "Socket is not connected") or a failed ping closes the session, so its calls fail as `connectionLost` and the client reconnects and retries.
- **Client (`TelegramClient`, an actor):** opens a session on the account's home DC and wraps its first call as `invokeWithLayer(initConnection(help.getConfig))`; when signed in it calls `updates.getState` so Telegram pushes updates on the session. `*_MIGRATE_X` (303) moves the home DC and retries, a lost connection reconnects and retries, and 401 `AUTH_KEY_UNREGISTERED`/`SESSION_REVOKED` signs out locally. Sign-in is `auth.sendCode` → `auth.signIn` → on `SESSION_PASSWORD_NEEDED`, `account.getPassword` + `auth.checkPassword` with SRP.
- **Storage:** home DC, per-DC auth key, salt and clock offset, and the signed-in account in the Keychain item `telegram`, never synchronizable (each device is its own Telegram authorization). The API id and hash come from `Resources/TelegramAPI.json`, which `scripts/telegram-api-config.py` writes from `TELEGRAM_APP_ID`/`TELEGRAM_APP_API_HASH` (environment or `.env.local`) and which is gitignored (the repository is public). Without it `TelegramClient.isAvailable` is false and Settings shows Telegram as unavailable.
- **Chats list:** `messages.getDialogs` (50) with `folder_id: 0` for the main list and `folder_id: 1` for the Archive → `ChatSummary` with `.telegram(peer:)`, carrying the peer's access hash. Without `folder_id`, Telegram returns both folders mixed. `ChatListViewModel.archivedChats` holds the Archive apart from `chats` (own cache file), and `ChatsView` shows it behind an Archived Chats row. Broadcast channels and forbidden chats are skipped. The preview uses the top message, prefixed with "You: " or the sender's first name in groups. A message is the user's own when it has `out` or its sender is the signed-in user (Saved Messages has no `out`).
- **Chat (`TelegramChatViewModel`):** `messages.getPeerDialogs` for the title, member count and `read_inbox_max_id`; `messages.getHistory` pages (newest first, `offset_id` for older); refresh on pushed updates that touch this chat (`TelegramClient.update(_:concerns:)`: new, edited and deleted messages and read receipts; status and typing updates are ignored), debounced 400 ms, and every 30 s; `messages.sendMessage` with `inputReplyToMessage`; `messages.readHistory` or `channels.readHistory` 600 ms after reading. The last 50 messages are kept in `ChatSnapshotCache`.
- **Service messages:** `TelegramClient.message(_:selfId:names:)` words `messageService` actions with the page's user names (the sender is the actor; `messageActionChatAddUser.users` and `messageActionChatDeleteUser.user_id` name the others), as "X joined the group via invite link", "X added Y", "X left the group", "X removed Y", "X pinned a message".
- **Members (`TelegramClient.members(peer:)`, `TelegramMembersView`):** supergroups use `channels.getParticipants` with `channelParticipantsRecent` (up to 200, plus the total `count`); basic groups the participants of `messages.getFullChat`. Roles come from the participant constructor (`…Creator`, `…Admin`); statuses from `user.status` (`userStatusOnline`, `userStatusOffline.was_online`, `Recently`, `LastWeek`, `LastMonth`). Hidden member lists answer `CHAT_ADMIN_REQUIRED`. `TelegramChatView` opens it from the title in groups; it reloads each time it opens.
- **Reply quotes:** after each history page, `TelegramClient.messages(peer:ids:)` fetches the quoted messages that aren't loaded in one call (`channels.getMessages` for supergroups, `messages.getMessages` otherwise) before the page is shown; ids Telegram doesn't return are unavailable.
- **Media (`TelegramMedia.swift`):** a file is a `tgfile://file/<cache key>?dc=<dc>&loc=<TL-encoded InputFileLocation, base64url>` URL, and `TelegramFileURLProtocol` (registered at launch) serves the scheme through `TelegramClient.file(at:)`, so every image view loads Telegram files lazily through `URLSession`. Downloads are `upload.getFile` in 512 KB parts on the file's DC (following `FILE_MIGRATE_X`), de-duplicated while in flight and cached under `Caches/telegram-media`. Another DC gets its own session, signed in with `auth.exportAuthorization` on the home DC and `auth.importAuthorization` as its first call (`authorizedDCs` in the stored session). Photos use the largest size up to 1280 px; static WebP stickers and small images sent as files load whole; videos, GIFs and animated stickers show their thumbnail; videos, voice, audio, files, locations, contacts, polls and web pages are cards (`TelegramMediaParser.content(of:)`). Avatars are `inputPeerPhotoFileLocation`; a "min" user's photo goes through `inputPeerUserFromMessage` with a message they sent.
- **Reactions:** `messageReactions.results` give the totals (`chosen_order` marks the user's), `recent_reactions` the reactors; custom-emoji and paid reactions show as ⭐️. `messages.sendReaction` sets one emoji or none, and its `updateMessageReactions` replaces the totals.
- **Sending media:** `upload.saveFilePart` (or `saveBigFilePart` over 10 MB) in 512 KB parts, then `messages.sendMedia` with `inputMediaUploadedPhoto` or `inputMediaUploadedDocument`.
- **Push:** Telegram pushes straight to APNs (token type 1) with the APNs certificate (Sandbox & Production, for `tech.stupid.StupidSocial`) uploaded to my.telegram.org; the certificate's private key is outside the repository. `TelegramPushService` calls `account.registerDevice` (`no_muted`, no `secret`, `app_sandbox` from the provisioning profile) after sign-in, at launch and when the APNs token changes; sign-out calls `account.unregisterDevice`. Alerts are `loc-key`/`loc-args`, which `Resources/en.lproj/Localizable.strings` (Telegram's templates from core.telegram.org/api/config.json, by `scripts/telegram-push-strings.py`) formats; the Notification Service Extension passes them through. A tap reads `custom.channel_id`/`chat_id`/`from_id` and opens the chat, matching the Chats list on kind and id since the push has no access hash. Web Push (token type 10, which tweb uses with Telegram's VAPID key) isn't available to third-party api_ids (`APP_PUSH_APIKEY_MISSING`).

## X Chat

X Chat replaced X DMs in 2025 and is end-to-end encrypted. The app is a native client of X's own web protocol (the `@x-clients/dm-core` library in the x.com XChat bundle), validated live with `scripts/xchat-client.py`. Legacy DMs (`/i/api/1.1/dm/*`) still answer, and `scripts/x-web-client.py dm-*` probes them, but conversations moved to X Chat and new messages arrive there, so the app reads only X Chat.

- **Transport:** X's persisted GraphQL operations at `https://x.com/i/api/graphql/<queryId>/<name>` with the X cookies and `XClient.apiHeaders` (no transaction id). Queries are GET with `variables`, mutations POST `{queryId, variables}`. Inbox: `GetInitialXChatPageQuery`, then `GetInboxPageRequestQuery` with the `{cursor_id, graph_snapshot_id}` continue cursor until an `XChatGetInboxPageEndCursor`. History: `GetConversationPageQuery`, whose `min_local_sequence_id` is an exclusive upper bound (`Int64.max` for the newest page). New events arrive over X's chat WebSocket (see Live events).
- **Events (`XChatThrift.swift`):** every event is a Thrift binary-protocol `MessageEvent` (base64 in GraphQL): 1 sequence id, 2 message id, 3 sender, 4 conversation, 5 conversation token, 6 created at (ms), 7 detail union (1 create, 3 key change, 7 delete, 12 read marker…), 9 signature. A create event's field 100 is the encrypted `MessageEntryHolder`; 101 the conversation key version; 108 franking data. Decrypted entries are messages (`MessageContents`: 1 text, 3 attachments, 4 reply preview), reactions (2 add / 3 remove, by target sequence id) and edits (4).
- **Keys (`XChatCrypto.swift`):** the account has P-256 identity (ECDH) and signing (ECDSA) keys, backed up in X's Juicebox realms. `XChatClient.recoverKeys(pin:)` reads the newest key version's `token_map` (`GetPublicKeysQuery` with Juicebox tokens), runs `JuiceboxSdk` `recover` with the PIN as UTF-8 and empty info (the realm configuration is X's `key_store_token_map_json`), splits the 64-byte secret into identity then signing scalars, checks both against the public keys X registered, and stores them in the Keychain item `xchat` (synchronizable, like the X cookies). Each conversation key (32 bytes, versioned) arrives in key-change events wrapped to each participant: ephemeral P-256 public key (65) ‖ AES-128-GCM ciphertext, key and IV = SHA-256(ECDH secret ‖ 00000001 ‖ ephemeral key) split 16/16. Contents encryption version 0 is a libsodium secretbox (XSalsa20-Poly1305, implemented natively) under the conversation key, stored nonce (24) ‖ MAC ‖ ciphertext; version 1 (a per-message HKDF key) isn't seen on any account yet and fails loudly.
- **Juicebox (`Vendor/JuiceboxSdk`):** the official MIT Swift SDK and a stripped XCFramework of its prebuilt Rust FFI (device and arm64 simulator), vendored by `scripts/vendor-juicebox.sh` from the artifacts commit the 0.3.7 tag pins, checked against its `checksums.txt`.
- **Sending:** `SendMessageCreateMutation` with `encoded_message_create_event` = base64 of just the `MessageCreateEvent` (100 contents, 101 key version, 102 should_notify, 105 false, 106 priority 1, 108 franking, 109 false) and `encoded_message_event_signature` = base64 `MessageEventSignature` (1 ECDSA r‖s unpadded base64, 2 key version, 3 signature version `7`, 4 signing public key, 5 `[{member_id, version, signing key}]`). The signed payload is `MessageCreateEvent,<message id>,<sender>,<conversation>,<key version>,<unpadded base64 contents>`. Franking (recipients may drop messages that fail it): tag = SHA-256(`xchat-franking` ‖ SHA-256(plaintext) ‖ media count ‖ media hashes ‖ 32-byte nonce ‖ message id ‖ len(conversation id) ‖ conversation id), and the nonce sealed under the conversation key. Reactions are create events too. The read marker is a full `MessageEvent` with detail 12 `{seen_until_sequence_id, seen_at_millis}` signed over `MarkConversationReadEvent,<message id>,<sender>,<conversation>,<seen until>,<seen at>`, sent with `SendMessageEventMutation`.
- **Chats list:** `XChatClient.chatSummaries(archived:)` maps inbox items to `.x(conversationId:)` rows; unread = others' events after the viewer's newest `latest_read_events_per_participant` marker that decrypt to messages (reactions are create events but X's badge doesn't count them). Archived rows come from the same inbox load. Group metadata carries no title (it is an encrypted group event), so groups are named for their members.
- **Live events (`XChatLiveFeed`):** one WebSocket for the account while the app is in the foreground, `wss://chat-ws.x.com/ws?token=<token>` with `Origin: https://x.com` and no subprotocol, the token from `GenerateXChatTokenMutation` (`user_get_x_chat_auth_token`), minted for each connection. Frames are raw Thrift `Message`s: 1 a `MessageEvent`, 3 `BatchedMessageEvents`, 2 a `MessageInstruction` (1 pull messages, 2 keep-alive…). X sends nothing on open, so the client sends the keep-alive (`Message{2: {2: {}}}`, every 30 s as the web client does) at once and treats its success as the connection being up. Every conversation's events come on the one socket: `XChatClient.ingest` adds them to the cached inbox conversations (latest events, read markers, key changes) and returns fresh rows for `ChatListViewModel.updateChats`; an event for a conversation the inbox hasn't loaded reloads the list. Open chats get their conversation's events. Each connection after the first, and a pull instruction, makes open chats fetch their newest page and the list reload, which covers events missed while closed. A closed socket (X closes with `unauthorized` when the token is stale) reconnects with backoff from 1 s to 60 s and a new token. It stops in the background and when X Chat is locked.
- **Chat (`XChatViewModel`):** history from the conversation page plus older pages; events are kept by sequence id, and edits, deletes and reactions are applied to the messages they name. Message ids are sequence ids. Replies render from the decrypted reply preview when the original isn't loaded. Sending replies is off: it needs the re-encrypted quoted source event, which isn't validated yet.
- **Unlock (`XChatUnlockViewModel`, Settings → X):** the PIN field, Unlock, and Forget Keys (with a confirmation).

## Sending

`ChatViewModel` owns optimistic sending for every network. Networks publish their messages as `history`; `messages` is `history` followed by the user's messages still sending (`ChatMessage.isSending`, drawn with a clock beside the time). `sendOptimistically(text:attachment:replyToId:deliver:)` adds the sending copy (a picked image is written to a temporary file and shown from it), clears the composer, and runs the network's `deliver`, which sends and returns the network's id for the message. The copy stays until a message with that id is in `history` (Apron's broadcast, Telegram's refresh, the copy Instagram and Spotify add), so it never blinks out; the confirmed message then keeps showing the picked image (`pickedImages`), so the swap doesn't reload the image or change its size. A failure removes the copy and puts the text and attachment back in an empty composer. Apron commands don't use it, since a command may post nothing.
