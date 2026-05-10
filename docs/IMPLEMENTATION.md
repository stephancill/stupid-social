# Implementation Notes

## 2026-04-27

- Scaffolded an xtool SwiftPM app in the repository root with bundle id `tech.stupid.StupidSocial`.
- Split reusable implementation into `NoFeedSocialCore` so unit tests can link without the app target's `@main` entry point.
- Added minimal MVVM app shell with built-in SwiftUI primitives: combined feed tab, settings tab, notification row/detail views, manual refresh, and `Mark All Read` action.
- Added normalized notification models, SwiftData `CachedNotification`, `NotificationSource` protocol, feed service, feed/settings view models, UserDefaults account metadata store, iCloud KVS read watermark store, synchronizable Keychain credential store, and X cookie header parser.
- Added initial Farcaster Hypersnap client and notification source for username resolution and notification fetches at `https://haatz.quilibrium.com`.
- Added X client/source placeholders that require the planned endpoint discovery spike before count and notification endpoints are implemented.
- Added a `BGTaskScheduler` wrapper that registers/schedules only on iOS; macOS builds skip background task registration because BackgroundTasks types are unavailable there.
- Added unit tests for X cookie extraction, read watermark behavior, and feed sorting/unread derivation.
- Verified `swift test` passes with 4 tests.
- Verified `xtool dev build` succeeds and writes `xtool/NoFeedSocial.app`.
- Attempted `xtool dev run --network -u 00008130-001C4CA030A1401C --no-attach --no-logs --launch-timeout 420`; build succeeded but install failed because the iPhone was locked and the developer disk image could not be mounted.
- Fixed Farcaster username setup after discovering Hypersnap `GET /v2/farcaster/user/by-username` returns a `UserResponse` wrapper shaped as `{ "user": { ... } }`, not a flat user object.
- Farcaster username lookup now strips a leading `@` before request construction.
- Verified `swift test` passes with 4 tests after the Farcaster decoder fix.
- Reinstalled and launched the fixed app on the booted iOS Simulator with `xtool dev run --simulator --no-attach --no-logs --launch-timeout 420` and `xcrun simctl launch booted tech.stupid.StupidSocial`.
- Tested Farcaster username lookup for `stephancill`; Hypersnap returned FID `1689`.
- Tested Farcaster notifications for FID `1689`; live response shape uses `type` values such as `reply`, a top-level `user`, and an ISO-8601 `timestamp`, with `cast` sometimes `null`.
- Updated Farcaster notification decoding and normalization to support the observed live Hypersnap response shape while keeping support for the documented `most_recent_timestamp` aggregate shape.
- Implemented native X unread-count polling with selected `auth_token` and `ct0` cookies against `GET https://x.com/i/api/2/notifications/all/unread_count.json?include_tweet_replies=true`.
- Verified local browser X authentication with `twitter status --json` and `twitter notifications-count --json`; local account is `stephancill` and unread count returned successfully without printing credentials.
- Added live service tests for Farcaster `stephancill` and opt-in X unread count. The X live test was run with temporary environment variables populated from local browser cookies using the patched `twitter-cli` extraction code; credentials were not printed or written to files.
- Tried adding a Keychain access-group entitlement for simulator builds, but xtool pseudo-signed simulator apps failed to launch with `NSPOSIXErrorDomain Code=163`. Removed the entitlement file and made simulator builds use local non-synchronizable Keychain storage for development/testing. Non-simulator builds still attempt synchronizable Keychain storage and surface missing entitlement/iCloud availability errors.
- Implemented Farcaster reply notification enrichment: when a reply notification has `cast: null`, fetch the actor's recent `user/replies_and_recasts`, match by timestamp, then fetch the parent cast by `parentHash` to populate `reply` and `parentTarget` on the normalized `NotificationItem`.
- Added `parentTarget` to `NotificationItem`, `CachedNotification`, and `NotificationDetailView` so reply detail shows both the reply text and the parent cast it was in reply to.
- Changed feed actor labels from `displayName` to `@username` to match Farcaster conventions and avoid display-name spoofing. Detail view still shows both display name and username.
- Updated `KeychainCredentialStore.saveXCredentials` to return `CredentialSaveResult` (`.synced` or `.localOnly`) so the settings UI can surface when iCloud Keychain sync is unavailable instead of silently succeeding or failing.
- Updated `PLAN.md` and `TECHNICAL_DESIGN.md` to document local-only fallback for both Keychain credentials and iCloud KVS read watermarks when sync is unavailable, instead of blocking account setup.
- Fixed "Mark All Read" not working on simulator: `ICloudReadWatermarkStore` now writes to both `NSUbiquitousKeyValueStore` and `UserDefaults`, and reads from iCloud first with `UserDefaults` fallback. This ensures read watermarks persist even when iCloud KVS is unavailable.
- Fixed reply content missing in detail view: increased timestamp matching tolerance from 1 second to 5 minutes when correlating reply notifications with `user/replies_and_recasts` casts. Added a fallback to take the most recent reply cast with a `parentHash` when no timestamp match is found, since Hyperswap notifications often have `cast: null` and timestamps can diverge between endpoints.
- Discovered and implemented X full notification fetch endpoint: `GET https://x.com/i/api/2/notifications/all.json?include_tweet_replies=true&count=40`. Response shape uses `globalObjects` (users and tweets dictionaries) plus `timeline.instructions[0].addEntries.entries`. Each entry is either a cursor, a `tweet` reference (with `clientEventInfo.element` indicating type like `user_mentioned_you`, `user_replied_to_your_tweet`, `users_liked_your_tweet`, `users_retweeted_your_tweet`), or a `notification` reference (for follows like `follow_from_recommended_user`). Tweet data is resolved from `globalObjects.tweets[id]`; user data from `globalObjects.users[user_id]`. Tweet `created_at` uses Twitter's `EEE MMM dd HH:mm:ss Z yyyy` format. X notifications are manual refresh only per PLAN.
- Fixed Keychain credential save failing with "iCloud unavailable" on device builds: `KeychainCredentialStore` now catches ALL `KeychainCredentialStoreError` cases (not just `errSecMissingEntitlement` and `errSecNotAvailable`) when attempting synchronizable storage, and unconditionally falls back to local-only storage. This handles any device-specific Keychain error code that might be returned when iCloud Keychain sync is unavailable.
- Fixed local Keychain fallback conflicts when replacing X credentials: after synchronizable Keychain save fails, the local fallback now deletes any existing non-synchronizable item before inserting the replacement credential. This avoids surfacing a generic save failure when a stale local item exists.
- Reproduced X credential save failure with a real Keychain test: Keychain operations can return `errSecMissingEntitlement` (`-34018`) even for the local-only Keychain path in this xtool/simulator/test environment. Added a final local fallback store for the extracted credential values only (`auth_token` and `ct0`) when both synchronizable and local Keychain writes fail. Added tests for the pasted Arc cookie header and save/load/update/delete fallback behavior.
- Simplified manual refresh request behavior: Farcaster refresh now performs exactly one `GET /v2/farcaster/notifications` request and normalizes only data returned by that response. Removed reply enrichment calls to `feed/user/replies_and_recasts` and `cast` so refresh cannot fan out into per-notification requests. X manual refresh already performs exactly one `GET /i/api/2/notifications/all.json` request; the unread-count endpoint remains separate for background/count-only flows.
- Simplified notification detail UI to show only network, username(s), and content. X notification entries now preserve all `fromUsers` actors and group likes/retweets/follows with Twitter-style text such as `@user and 3 others liked your tweet`.
- Fixed Farcaster row summary text to use usernames instead of display names. Fixed X notification decoding for the live `notifications/all.json` payload by enabling snake-case key decoding and accepting numeric `id` fields with `id_str` fallback; previous decoding could fail the whole X source, causing no X rows to appear. Feed refresh now logs source item counts and surfaces a refresh alert if all sources fail instead of silently showing stale/cache-only results.
- X normalization now filters the notification timeline to engagement events only: mentions, replies, quotes, likes, and retweets. Follow and device/post notifications are intentionally dropped.
- Feed row timestamps now use compact social-media style relative labels (`now`, `1m`, `12h`, `1d`, `2w`, `1mo`, `1y`) instead of SwiftUI's verbose relative date strings.
- Removed per-row unread dot indicators. The feed now inserts a single `New` separator before the first unread notification and relies on existing row emphasis for unread items.
- Changed manual refresh read behavior: after a successful refresh, the feed immediately advances read watermarks for the loaded items so refreshed notifications become app-read locally.
- Reverted cached-feed load marking items read; opening the app does not advance read watermarks. Fixed read watermark lookup to choose the newest watermark across iCloud KVS and local `UserDefaults` fallback instead of always preferring a potentially stale iCloud value.
- Fixed read watermark precision: the previous `.iso8601` date encoding truncated subsecond timestamps, so newest X items with millisecond timestamps could remain unread after refresh. Watermarks now encode dates as milliseconds since epoch and retain legacy ISO-8601 decoding support. Added a regression test for subsecond watermark precision.
- Removed the centered feed refresh `ProgressView`; pull-to-refresh now only uses the native refresh control.
- Cloned `farcasterorg/hypersnap` into ignored `third-party/hypersnap` for endpoint investigation. Found `/v2/farcaster/notifications` is implemented in `src/api/http.rs::handle_notifications`, which delegates to `hub.get_notifications`. The concrete implementation in `src/network/server.rs::get_notifications` only calls `CastStore::get_casts_by_mention`, so live notifications are mention/reply-like `CastAdd` messages only. Although `handle_notifications` maps `ReactionAdd` to `likes` and `LinkAdd` to `follows`, those message types are never fetched by `get_notifications`. Direct API checks confirmed recent user casts have reactions via `/v2/farcaster/reaction?hash=...`, but those reactions are not included by `/v2/farcaster/notifications`.
- Removed the feed toolbar buttons for `Mark All Read` and explicit refresh. Pull-to-refresh is now the only feed refresh/read action.
- Moved the `New` separator to the boundary between unread and read items. It is not shown when there are no unread items.
- Replaced the single feed table with separate unread and read `List` sections while preserving native inset grouped styling on iOS. The `New` separator sits between sections and is only shown when both sections are present.
- Refined notification actor presentation: feed rows now show notification-type icons, actor avatar strips, inline network favicon badges from direct `Resources/` PNGs generated with ImageMagick (`x.com/favicon.ico` and Farcaster's `favicon-v3.png`), username labels without `@`, bolded actor names, relative timestamps beside avatars, and inline badge/title wrapping that flows under the badge; detail People rows now show smaller actor avatars plus network badge and username only. The direct PNG resources are explicitly listed in `xtool.yml` because standalone imagesets were not copied into the app bundle by `xtool`.

## 2026-05-01

### Settings screen restructure

- Replaced the inline X and Farcaster configuration sections in `SettingsView` with a single `Connections` section showing connection rows (network name on left, status/`@handle` on right).
- Tapping a connection row navigates to dedicated configuration screens: `XConnectionView` and `FarcasterConnectionView`.
- `XConnectionView` contains the cookie header text field, status, and save button (extracted from the old settings form).
- `FarcasterConnectionView` contains the username text field, status, and save button (extracted from the old settings form).
- `SettingsViewModel` gained `xConnectionLabel`, `farcasterConnectionLabel`, `xHandle`, and `farcasterHandle` computed properties for the connection row display.
- Removed unused `xIsConnected` and `farcasterIsConnected` properties from `SettingsViewModel`.
- Settings screen refreshes statuses on appear so connection labels update after returning from a config screen.

### X handle resolution during credential save

- Added `XClient.verifiedUser()` which calls `GET /i/api/1.1/account/multi/list.json` to resolve the authenticated user's `screen_name`.
- `GET /i/api/1.1/account/verify_credentials.json` is deprecated (returns 404 via the `i/api` path). The `account/multi/list.json` endpoint returns `{"users": [{"screen_name": "...", "user_id": "...", ...}]}`.
- `saveXCookieHeader()` is now async: it saves credentials to Keychain, then calls `verifiedUser()` to fetch and store the `screen_name` in `XAccountMetadata.handle`.
- If the handle lookup fails, credentials are still saved but the row shows "Valid" until re-save succeeds.
- Added `XVerifiedUser`, `XAccountListResponse`, and `XAccountListUser` models to support the endpoint.

### Background refresh debug testing

- Found the existing `BackgroundRefreshScheduler` only registered and rescheduled the `BGTaskScheduler` task, then completed immediately; it did not call the feed refresh pipeline.
- Added a scheduler refresh handler wired from `ContentView` after SwiftData-backed dependencies are constructed. Background refresh now calls `FeedService.backgroundRefresh()`.
- `FeedService.backgroundRefresh()` keeps X to `fetchUnreadCount()` only, while Farcaster and Debug sources fetch notifications and update the local SwiftData cache without advancing read watermarks.
- Added required iOS background refresh plist entries: `UIBackgroundModes` with `fetch`, and `BGTaskSchedulerPermittedIdentifiers` containing `tech.stupid.StupidSocial.refresh`.
- Added local-network debug testing plist support with `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription` so device builds can connect to a LAN-hosted HTTP debug server.
- Added a Debug connection type stored in `AccountMetadataStore` as `DebugAccountMetadata(serverURL:)`, exposed from Settings as a third connection row.
- Added `DebugNotificationSource` and `DebugNotificationsClient`; the source fetches `GET <debug-server>/notifications` and normalizes response entries into cached `debug` notifications.
- Added `scripts/debug-notifications-server.js`, a Bun server that returns an increasing list of synthetic notifications from `/notifications` so manual and background refreshes can be observed in the feed.
- The debug server binds to `0.0.0.0` and logs each request method/path so physical devices can reach it over LAN and request activity can be checked in `logs/debug-notifications-server.log`.
- Updated the debug server to append a random number of new notifications between 0 and 5 on each `/notifications` request, returning the accumulated list so cache-diff behavior can be tested against empty and multi-item refreshes.
- Persisted debug server state to `logs/debug-notifications-state.json` so generated notification IDs and timestamps survive server restarts. This prevents old debug notifications from being reissued with fresh timestamps and showing as `now` after app cache upsert.
- Changed background-fetched notification handling: items inserted by background refresh are cached as pending and hidden from the feed until the user taps the feed toolbar `N New` button. Revealing pending items clears their pending flag and shows them as new above the existing `New` boundary.
- Fixed background-only launch wiring: `NoFeedSocialApp` now creates the SwiftData-backed feed service and attaches the `BackgroundRefreshScheduler` handler before registering/scheduling the BG task. Previously the handler was only attached from `ContentView`, so a background task launch could complete without running refresh work if the UI task had not configured dependencies.
- Aligned background refresh scheduling more closely with Apple's guidance by scheduling when the scene enters background, adding BG task received/scheduled/completed logs, and setting an expiration handler that cancels the in-flight refresh task.
- Removed the experimental `App.entitlements` background-modes entry. For `BGAppRefreshTask`, Xcode's Background fetch capability is represented in this xtool project by `UIBackgroundModes = fetch` in `Info.plist`, plus `BGTaskSchedulerPermittedIdentifiers`; a custom entitlement file is not needed and can complicate xtool provisioning.
- Added visible background refresh diagnostics in Settings backed by `UserDefaults`: registration time, schedule attempts/success/errors, task received time, and task completion/result. This distinguishes iOS not launching a task from a task launching and refresh work failing.
- Added a temporary foreground debug trigger: when the app enters the active scene phase, `FeedViewModel.refreshFromForegroundDebugTrigger()` runs the same `FeedService.backgroundRefresh()` path and reloads cached state so pending background-style items appear behind the `N New` button. This is for deterministic testing of background refresh handling independent of iOS BGTaskScheduler delivery.
- Restored the pending new notifications affordance to the navigation toolbar, but placed it on the leading/navigation side so it remains visually separate from the Settings gear on the trailing side.
- Manual refresh now clears pending background items before fetching, which removes the `N New` badge. Pending items become known cached items unless they are rediscovered as newly inserted by the manual refresh response.
- Temporarily changed the background refresh requested earliest begin date from 15 minutes to 30 seconds for debug testing. This is still only an iOS scheduling hint; actual execution remains opportunistic.
- Removed BGTaskScheduler-based refresh scheduling and visible BGTask diagnostics after device testing showed iOS delivery was not deterministic enough for the MVP behavior. Foreground activation refresh is now the permanent automatic refresh path: when the app enters `scenePhase == .active`, `FeedViewModel.refreshOnForegroundActivation()` calls `FeedService.foregroundActivationRefresh()`.
- Foreground activation refresh preserves the safe automatic-refresh policy: X uses count-only polling, while Farcaster and Debug fetch notifications and cache newly inserted IDs as pending. Pending items stay hidden until the user taps the leading `N New` toolbar button.
- Restored the feed `New` separator as a boundary marker between newly discovered items and previously cached items. It is not a section header and is only shown when both groups are present.
- Changed feed `New` derivation from read-watermark timestamp comparison to local-cache identity diffing. `CachedNotification` now stores `isNew`; refreshes mark inserted notification IDs as new while previously cached IDs are treated as known.
- Made `CachedNotification.isNew` default to `false` at the SwiftData model property declaration so existing installed caches can migrate safely when upgrading from builds that did not have the field.
- Cloned `supreme-gg-gg/instagram-cli` into ignored `third-party/instagram-cli` for endpoint investigation. Found it uses `instagram-private-api` (Node.js) emulating the Instagram Android app. Key endpoint: `GET /api/v1/news/inbox/` for notifications at `https://i.instagram.com`. Auth uses cookies: `sessionid`, `csrftoken`, `ds_user_id`, `mid`.
- Implemented cookie-based Instagram integration using `InstagramClient` (native Swift HTTP client), `InstagramNotificationSource`, and `InstagramCredentials` in `CookieHeaderParser`. Added `.instagram` to `SocialNetwork`, `InstagramAccountMetadata` to `AccountMetadataStore`, and Instagram save/load/delete to `KeychainCredentialStore`.
- Instagram `GET /api/v1/news/inbox/` returns `new_stories` and `old_stories` arrays. Story args contain `rich_text` with `{username|color|weight|user?id=N|suffix}` placeholders, `profile_name`, `profile_image`, `profile_id`, `second_profile_id`, `second_profile_image`, `destination`, `media`, and `timestamp` (Unix epoch). Instagram badge uses magenta/brand-colored background with "I" fallback text from a generated Resources PNG.
- Instagram notification categories (`InstagramNotificationCategory`): `.follows`, `.comments`, `.likes`, `.storyHighlights`. Churn/Threads/promotional notifications (e.g., `ig_text_post_app_churn_reminders`, `suspicious_login`) are dropped silently — they don't map to any category. Users toggle categories per collection in `InstagramConnectionView`.
- Rich text parsing extracts structured actors from `{username|color|weight|user?id=N|suffix}` blocks (username + ID) and matches them against `profile_id`/`second_profile_id` for avatar images. Aggregated notifications expose only up to 2 structured actor profiles; the parser does not attempt to count additional unlisted users.
- Story-like notifications parse `destination` (`story_fullscreen?reel_id=archiveDay%3A{HASH}&feeditem_id={MEDIA_ID}_{USER_ID}`) to build Instagram web story links (`https://www.instagram.com/stories/archive/{hash}/?initial_media_id={id}`).
- `NotificationTarget` gained `imageURL: URL?` for thumbnail previews. Feed rows show story thumbnail images (48×48 rounded `AsyncImage`) for reactions with CDN image URLs but no comment text. Detail view shows the image below the Content row and makes the full Content row tappable (external link arrow, no blue tint) when a target URL exists.
- Comment content (text after `:` in `rich_text`) is placed in `target.text` and shown as the feed row subtitle. Story likes display no content text — just the thumbnail.
- Actor profile links on detail view: `https://www.instagram.com/{username}/`.
- Instagram notifications are fetched on foreground activation (like Farcaster) since there is no separate count-only endpoint. Read state uses the same app-local watermark system.

## 2026-05-07

### Hypersnap PR #17 deployed — normalization fix

- Hypersnap PR #17 merged and deployed to `https://haatz.quilibrium.com`. The endpoint now returns `likes` (with hydrated target casts), `follows` (cast=null), and `reply` notification types with opaque base64-JSON cursor pagination.
- `FarcasterNotificationSource.normalizeType` was missing mappings for the new PR type strings `"likes"` and `"follows"` (only had `"reaction"` and `"follow"`). All likes and follows were falling through to `.unknown`, rendering as generic gray bell icons in the feed.
- Added `"likes"` → `.reaction` and `"follows"` → `.follow` mappings. Added decoding tests for the new PR format: likes with hydrated casts and follows with null cast.
- Removed the temporary Cloudflare Worker Farcaster base URL override from `ContentView` and `FarcasterConnectionView` since the Hypersnap endpoint is now operational.
- Follow notification rows no longer show a redundant content preview line (actor username was repeated below the summary text).

### Instagram priority_stories fix

- Instagram's news inbox returns three story arrays: `new_stories`, `old_stories`, and `priority_stories`. The app was only processing `new_stories + old_stories`, causing latest story likes (which land in `priority_stories`) to never appear in the feed.
- Added `priorityStories` to `InstagramNewsInboxResponse` and included it in the merge (prepended first since they are the most recent).

### Farcaster reaction grouping

- Added a post-normalization grouping step in `FarcasterNotificationSource` that merges multiple reaction (likes) notifications sharing the same target cast hash into a single `NotificationItem`.
- Merged actors are deduplicated by FID, the most recent timestamp is used, and text uses the `"@alice and 2 others reacted to your cast"` pattern matching the X and Instagram grouping style.
- Replies and follows remain ungrouped (replies are unique per cast, follows have no common grouping key).

### Farcaster follow grouping and Instagram story URL fix

- Extended Farcaster grouping to also collapse all follow notifications from a single fetch batch into one item with `"@alice and N others followed you"` text.
- Refactored `mergeReactionGroup` into a generic `mergeGroup` that handles both `.reaction` and `.follow` types.
- Fixed Instagram story URL generation for active (non-archived) stories. When `reel_id` matches the user's own FID, the URL now uses the active story pattern `https://www.instagram.com/stories/{username}/{media_id}/` instead of the archive pattern.
- `parseStoryURL` now accepts `accountId` and `accountUsername` parameters. The username is threaded from `InstagramNotificationSource` through `InstagramClient.notifications` to the parser.

### Profile detail page

- Added `ProfileDetailView` accessible by tapping an actor in the notification detail People section. Shows profile image, display name with verified badge, @username, bio, follower/following/post counts, join date, website link, and "View on Network" button.
- `NetworkProfile` gained `bio`, `postsCount`, `joinedAt`, `websiteURL`, `isVerified`, and `isMutualFollow` fields. All `*NotificationSource.fetchProfile` implementations updated to populate the new fields.
- **Farcaster** (`FarcasterNotificationSource`): Uses `GET /v2/farcaster/user?fid=N` (new `FarcasterClient.user(byFid:)`) to look up any user by FID. `FarcasterUserResponse` now decodes `profile.bio.text` as a computed `bio` property and `registered_at` as `registeredAt`.
- **X** (`XNotificationSource`): Uses X's GraphQL `UserByScreenName` endpoint (query ID `IGgvgiOx4QZndDHuD3x9TQ`, same as twitter-cli) since the v1.1 REST `users/show.json` is deprecated. The GraphQL response structure was mapped from real API data: `screen_name`/`name` from `result.core`, `following`/`followed_by` from `result.relationship_perspectives`, avatar from `result.avatar.image_url`, verified from `result.is_blue_verified`, and counts/bio from `result.legacy`. The `id` parameter is the actor's screen name (routed through `FeedService.fetchProfile`).
- **Instagram** (`InstagramNotificationSource`): Extended `InfoUser` to decode `biography`, `media_count`, `is_verified`, `is_private`, `external_url`, and `friendship_status` (with `following`/`followed_by`) from the `/api/v1/users/{uid}/info/` response.
- Avatar decoding fixed: `FarcasterUserResponse` uses `.convertFromSnakeCase` with auto-synthesized `Decodable` (removed conflicting custom `CodingKeys`); added decoding tests for real API user responses.
- `NotificationDetailView` People rows now navigate to `ProfileDetailView` instead of opening external web links. `FeedService.fetchProfile` accepts optional `username` parameter for X screen name lookup.
- Follow notification rows in the feed no longer show a redundant content preview line.

### Hypersnap PR #24 — parent-based reply lookup

- Opened PR to add `get_casts_by_parent` lookup to `GET /v2/farcaster/notifications` in Hypersnap so replies via `parent_cast_id` (without explicit @mention) also appear in notifications. Uses same `cast_targets` list already collected for reactions, with `REPLIES_PER_CAST_CAP = 10` per shard. Added 2 tests for parent-based replies and self-reply exclusion.

### Farcaster mention vs reply distinction and mention text reconstruction

- Hypersnap returns `type: "reply"` for all `CastAdd` notification messages (both replies and mentions). `normalizeType` now checks `parentAuthor.fid` against the account FID: matching → `.reply`, null/mismatched → `.mention`.
- `FarcasterCastResponse` gained `mentionedProfiles` and `mentionedProfilesRanges` fields from the Hypersnap response. The cast `text` field stores mention-stripped text with zero-length ranges; `displayText` reconstructs the full text by inserting `@username` at each range position. Used in `NotificationTarget` for feed row preview content.

## 2026-05-08

### X webview login

- Added `XLoginWebView` — a `WKWebView`-based browser login flow that opens `https://x.com/i/flow/login` in a sheet. Uses a non-persistent cookie store and impersonates Chrome via custom user agent.
- After each page load, the coordinator checks the webview's cookie store for `auth_token` cookie; on finding it extracts `auth_token` + `ct0` and triggers credential save.
- Added `saveXCookies(_ credentials: XCredentials)` to `SettingsViewModel` — saves credentials directly (no header parsing needed) then resolves username via `verifiedUser()`.
- Webview login is now the primary method in `XConnectionView`; the manual cookie header paste is hidden behind the dev mode toggle (4 taps on Settings > About header).
- Fixed a row separator rendering issue between the login button and status by splitting them into separate Form sections.

### Instagram webview login

- Added `InstagramLoginWebView` — `WKWebView`-based browser login for `https://www.instagram.com/accounts/login/`. Same non-persistent cookie store and Chrome user agent approach.
- Cookie extraction watches for `sessionid` cookie, then extracts `sessionid`, `csrftoken`, `ds_user_id`, and optionally `mid`.
- Added `saveInstagramCookies(_ credentials: InstagramCredentials)` to `SettingsViewModel`.
- Updated `InstagramConnectionView` with same layout: webview login button as primary, manual cookie header paste hidden behind dev mode toggle.

## 2026-05-09

### Spotify endpoint research

- Current auth uses WebPlayer credentials captured by `SpotifyLoginWebView`: Bearer token, `client-token`, `sp_dc`, and `sp_t`. `SpotifyClient` refreshes the Bearer token through `GET https://open.spotify.com/api/token?reason=transport&productType=web-player&totp=...&totpServer=...&totpVer=61` using the persisted `sp_dc` cookie and saves the returned expiry.
- `GET https://spclient.wg.spotify.com/presence-view/v1/buddylist` returns friend listening activity with `user`, `track`, `album`, `artist`, and Unix-ms `timestamp` fields. Live simulator probes returned 13 friends. The app renders all returned buddylist entries rather than filtering to Spotify's 15-minute now-playing threshold because valid responses can have zero entries inside that threshold.
- `GET https://spclient.wg.spotify.com/audio-attributes/v1/audio-analysis/{track_id}` works with refreshed WebPlayer credentials for bare track IDs. It returns audio-analysis-style JSON (`meta`, `track`, `bars`, `beats`, `sections`, `segments`, `tatums`); `track` includes `tempo`, `tempo_confidence`, `loudness`, `key`, `mode`, and confidence values. It does not return deprecated public audio-features fields such as `danceability`, `energy`, `valence`, `acousticness`, `instrumentalness`, or `speechiness`.
- URI forms for audio analysis failed (`400`/`404`), `/audio-features/...` returned `404`, and GET requests to `extended-metadata/v0/extended-metadata` returned `405`. The useful HTTP surface is the direct `audio-attributes/v1/audio-analysis/{track_id}` endpoint.
- Gander notification endpoints (`gander/v2/GetUserHasUnreadNotification`, `gander/v2/GetNotifications`) work with `accept-language: en`, but live responses were marketing/concert notifications only. Social notifications likely require Dealer WebSocket integration and remain out of scope.

### Spotify integration

- Added Spotify as a source for friend listening activity. `SpotifyLoginWebView` captures WebPlayer Bearer/client-token headers and `sp_dc`/`sp_t`; `SpotifyCredentials` stores those values plus optional token expiry for refresh.
- `SpotifyClient` currently uses `presence-view/v1/buddylist`, `audio-attributes/v1/audio-analysis/{track_id}`, user profile/follow endpoints, and `api-partner` `profileAttributes` for username resolution. Gander marketing notifications were probed but are not part of the current source path.
- `SpotifyNotificationSource` normalizes buddylist entries into `.music` `NotificationItem`s with actor avatar, album art, track text, and open.spotify.com track links. `NotificationTarget.musicAnimation` stores only derived audio-analysis fields (`tempo`, `tempoConfidence`, `loudness`, `mode`) needed for rendering.
- `FeedView` renders Spotify listening activity only in the top stories bar, not the main notification list. It intentionally does not filter by Spotify's 15-minute now-playing threshold because live buddylist responses can have valid activity while `now_playing_count` is zero.
- Spotify story tiles spin album art and emit layered gray pulse rings from the outer artwork border. Tempo controls spin/pulse timing, tempo confidence controls opacity, and loudness controls pulse scale. Reduce Motion disables rotation and pulse expansion.
- Added Spotify connection/settings views, Spotify badge resources in `xtool.yml`, `.spotify` network support, `.music` notification type support, and Spotify profile/detail URL handling.

### Instagram stories viewer

- Added `GET /api/v1/feed/user/{userId}/story/` and `POST /api/v1/feed/reels_tray/` to `InstagramClient` using the same cookie-based auth as the news/inbox endpoint.
- Added response models: `InstagramReelsTrayResponse`, `InstagramTrayItem`, `InstagramUserStoryResponse`, `InstagramReel`, `InstagramStoryMedia`, `InstagramImageVersions`, `InstagramMediaCandidate`, `InstagramVideoVersion`.
- Added `InstagramStoryReel` and `InstagramStorySlide` public types to `AppModels` for rendering.
- `InstagramNotificationSource.fetchStoryReels()` calls the tray endpoint, then fetches each user's story media (image URLs via `image_versions2.candidates`, video URLs via `video_versions`).
- `FeedViewModel` now holds `@Published var instagramStoryReels` and a reference to the instagram source; `fetchInstagramStories()` is called after dependency setup in `ContentView`.
- `FeedView` shows Instagram reels as tappable tiles in the `StoriesBar` alongside Spotify items. Tapping opens a full-screen `InstagramStoryViewer` with slide navigation.
- `InstagramStoryViewer` renders story images with a progress bar indicator, user header (avatar, username, display name), close button, and swipe-down/left/right navigation.
- Instagram story tiles show the user's profile picture with a gradient ring (purple → pink → orange).
- MVP is image-only; video support is deferred.

### Credential health check

- On startup, `FeedViewModel.performCredentialHealthCheck()` calls `validateAccount()` on every configured source.
- Each source's `validateAccount()` now updates its stored `AccountStatusSnapshot` to `.invalidCredentials` when validation fails (e.g. session expired, token revoked) while preserving `.notConfigured` for accounts that were never set up.
- `SettingsViewModel.loadStatuses()` now reads the stored status snapshot to display the correct connection state.
- `AccountStatusSnapshot` gained `.networkUnavailable` and `.serviceError` cases. `accountStatus(from:)` maps all existing snapshot cases.

### Instagram API auth fixes (2026-05-09)

- Analyzed Instagram's web client GraphQL auth and stories tray fetching from saved page captures.
- Web client uses `POST www.instagram.com/api/graphql` with compiled document IDs that change per build. The stories tray root field is `xdt_api__v1__feed__reels_tray`. Auth is cookie-based (`sessionid`, `csrftoken`, `ds_user_id`, `mid`, `rur`, `ig_did`) plus CSRF tokens embedded in the page source (`fb_dtsg`, `lsd`).
- Document IDs cannot be hardcoded — they change with each `instagram_web_pkg` build. The `bulk-route-definitions` endpoint could provide them at runtime but requires the full CSRF token set from a freshly loaded page.
- Discovered the mobile REST API (`i.instagram.com/api/v1/`) requires: (a) the `rur` cookie in addition to `sessionid`/`csrftoken`/`ds_user_id`, (b) the Android user agent matching the session's issuance, and (c) an explicit `Cookie:` header (not just `HTTPCookieStorage` delegation). `current_user` was more permissive than `reels_tray`/`news/inbox`/`user/story`.
- `InstagramLoginWebView` user agent changed from desktop Chrome to Android Mobile (`Nexus 5 / Chrome 147`) so the login issues mobile-compatible session cookies.
- `InstagramCredentials` now includes optional `rur` and `igDid` fields, extracted from the login WebView's full cookie set.
- `InstagramClient.headers()` now constructs and sends an explicit `Cookie:` header with all available credential cookies (`ds_user_id`, `csrftoken`, `sessionid`, `mid`, `rur`, `ig_did`).
- The Android user agent in `headers()` must match the login WebView user agent for the session to be valid against the mobile API.
- URLSession's default cookie handling was stripping manually-set `Cookie` headers and blocking programmatic cookie insertion due to `cookieAcceptPolicy = .onlyFromMainDocumentDomain`. Fixed by using `URLSessionConfiguration.ephemeral` with `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, and `httpCookieStorage = nil`, plus setting `request.httpShouldHandleCookies = false` on every request.
- `InstagramTrayItem` uses a custom `init(from:)` that tries `UInt64` for `id` first, falling back to `String`, because highlight rewind items have string-prefixed IDs like `highlightRewind:3022481654`.
- Removed `mediaIds` from `InstagramTrayItem` — the API returns an array of integers but the model declared `[String]?`, causing `decodeIfPresent` to throw a `DecodingError.typeMismatch` which crashed the entire tray array decode and triggered false `invalidateAccount()`.
- `fetchStoryReels()` re-validates the account to `.valid` on successful tray fetch, fixing accounts stuck at `.invalidCredentials` after a transient decode failure.
- `fetchInstagramStories()` added to `refresh()` and `refreshOnForegroundActivation()` so stories are re-fetched on pull-to-refresh and foreground activation, not just on initial app launch.
- `InstagramStoryViewer` replaced `TabView` (`.page`) with a flat `AsyncImage` + swipe gesture navigation. The `TabView` was consuming the dismiss drag gesture and could produce untappable empty states when `selectedInstagramReelIndex` was nil during the `fullScreenCover` lifecycle.
- `InstagramStoryReel.seen` now carries the API tray `seen` field. Stories are sorted unread-first in the bar with gradient rings for unread and gray rings for read.
- Attempted `POST /api/v2/media/seen/` and multiple alternatives to mark stories as seen — all return `{"status":"ok"}` but never update the tray `seen` field. This endpoint does not affect story seen state. Story seen marking is deferred; local seen tracking via `UserDefaults` is the next step.
- Duplicate story bubbles (same user appearing as both active reel + highlight reel) fixed by deduplicating in `fetchStoryReels()` via `seenUserIds` set keyed on `item.user.pk`.
- Tapping a story bubble opens that specific story (not always the first unread).

## 2026-05-10

### Instagram story seen APK research

- Decompiled/searched `/Users/stephan/Downloads/instagram-429-0-0-32-70.apk` with APK extraction, `strings`, and Android SDK `dexdump` after `jadx` installation/download proved too slow.
- Found official story seen request builder in obfuscated class `LX/0jt.A00`: endpoint path `media/seen/?reel=%s&live_vod=0`, which resolves to `POST https://i.instagram.com/api/v1/media/seen/?reel=1&live_vod=0`.
- No `xdt_api__v1__stories__reel__seen` mutation string was present in the APK. XDT GraphQL strings existed for unrelated APIs only.
- Official request body is form-encoded. The key field is `reels`, a JSON object serialized by `LX/7YU.A00`. For each seen story media, the JSON maps a compound key to an array of `"<taken_at>_<seen_at>"` strings. The normal compound key construction in `LX/7YV` is `"<owner_id>_<owner_id>_<reel_id>:<media_id>"`.
- The same pending seen-state class can also serialize `stories_view_info_v2` for fetch-reels requests as an array of `{ "reel_media_owner_id": ..., "reel_media_creation_seen_at": [...] }`, but the explicit mark-seen request posts `reels`.
- Additional optional form fields observed in the request builder: `reel_media_skipped`, `nuxes`, `nuxes_skipped`, `container_module`, and `notification_type`. The app only sends them when the relevant local state is populated.
- Headers/auth for this call use the same native mobile API request stack as other `i.instagram.com` calls; no separate auth mechanism was found. The Swift client continues using cookies plus `X-CSRFToken`, `X-IG-App-ID`, Android user agent, device headers, and explicit `Cookie:` header.
- Curl testing against live simulator credentials found plain `reels=<json>` form bodies return HTTP 500 (`Oops, an error occurred.`). Wrapping the body in Instagram's standard `signed_body=SIGNATURE.<json>` form with `ig_sig_key_version=4`, where `reels` is a nested JSON object, returns `{"status":"ok"}`.
- `stories_view_info_v2` is accepted with `{"status":"ok"}` both on `media/seen` and `feed/reels_tray`, but did not update the selected tray item's `seen` field in live testing.
- Live test target: `sai.k1065` (`5682861498`), media `3893660934892232546_5682861498`, `taken_at=1778380574`. Initial attempts with the wrong HMAC key, wrong compound key format, and wrong endpoint version all returned `{"status":"ok"}` but left tray `seen=0`.
- Researched `instagram-private-api` library in `third-party/instagram-cli/node_modules/instagram-private-api/` and found three critical differences from the earlier implementation: (1) endpoint is `/api/v2/media/seen/` (not v1), (2) the `reels` compound key uses `<media.id>_<sourceId>` format (not the APK's `owner_owner_reel:media` format), and (3) the signature key embedded in `dist/core/constants.js` is `9193488027538fd3450b83b7d05286d4ca9599a0f7eeed90d8c85925698a05dc` for app version `416.0.0.47.66` (different from the key used in earlier tests). Additional required form fields include `reel_media_skipped`, `live_vods`, `live_vods_skipped`, `nuxes`, `nuxes_skipped`, `_uid`, and `device_id`.
- Curl-verified the full corrected request: `POST /api/v2/media/seen/?reel=1&live_vod=0` with HMAC-SHA256 signed body and compound keys like `3893660934892232546_5682861498_5682861498`. Live test confirmed `sai.k1065` tray `seen` updated from `0` to `1778380574`.
- Updated `InstagramClient.markStorySeen` to use the correct endpoint, compound key format, HMAC-SHA256 signing with the correct key (via `CryptoKit`), and all required form fields. Removed the unused `reelId` parameter. Updated `InstagramNotificationSource.markReelAsSeen` and `FeedViewModel.markInstagramReelAsSeen` call sites accordingly.
- Curl-verified `/api/v1/feed/reels_media/` as a better story media fetch endpoint. It accepts `POST` form field `reel_ids` as a JSON array string, e.g. `["5682861498"]`; plain IDs and `reel_ids[]=...` return `400 Invalid reel id list`.
- `/feed/reels_media/` returns `{ "reels": { "<reel_id>": ... }, "status": "ok" }`, with the same media fields needed by the viewer: `items[].id`, `pk`, `taken_at`, `media_type`, `image_versions2.candidates`, `video_versions`, and `user.pk`.
- A live batch test requested 5 unique active tray reel IDs and received all 5, all with non-empty `items`; the response included 12 usable image URLs and 12 usable video URLs. Duplicate/highlight tray entries collapse to one response per reel ID, matching the current app's dedupe-by-user behavior.
- Intended client change: keep `/feed/reels_tray/` for ordering, user metadata, and `seen`; switch story slide fetching from repeated `GET /feed/user/{userId}/story/` calls to a single `/feed/reels_media/` batch request for unique active reel IDs.
- Implemented the batch story media path in `InstagramNotificationSource.fetchStoryReels()`: it now deduplicates active tray entries by user PK, skips highlight/non-active reel IDs, calls `InstagramClient.reelsMedia(reelIds:)` once, and builds story slides from the returned reel map while preserving tray ordering, tray user metadata, and tray `seen`.
- Fixed server-side story seen marking: `InstagramClient.markStorySeen` now posts to `POST /api/v2/media/seen/?reel=1&live_vod=0` with the correct compound key format (`<mediaId>_<ownerId>`), the correct HMAC-SHA256 key from `instagram-private-api` constants, and all required form fields (`reel_media_skipped`, `live_vods`, `nuxes`, etc.). Verified with live curl testing against the `sai.k1065` test account.
- Added Instagram stories toggle: `InstagramAccountMetadata.storiesEnabled` (defaults to `true`), persisted in `UserDefaults`. `InstagramConnectionView` shows a "Show Stories" toggle. `FeedViewModel.fetchInstagramStories()` clears `instagramStoryReels` and skips the fetch when toggled off. The feed's `StoriesBar` is hidden when neither Spotify nor Instagram story content is present.

### Notification detail relative timestamps and per-actor time

- Added `Date.compactRelativeTime` extension in `NoFeedSocialCore/Date+RelativeTime.swift` as a shared utility (extracted from the duplicated private computed property in `FeedView` and `NotificationDetailView`).
- Feed rows and notification detail People rows both use this shared extension.
- Added optional `timestamp: Date?` to `NotificationActor` so individual actors can carry their own action time.
- Farcaster notification normalization now threads the per-notification timestamp into each actor during creation. When grouped reactions include multiple actors, each actor retains their individual like/reaction timestamp rather than all sharing the group's newest timestamp.
- `PersonRow` in `NotificationDetailView` shows relative time only when the actor has a timestamp (currently Farcaster only). Other networks that don't provide per-actor timestamps show no time in the People section.

## 2026-05-10 - Spotify Full-Screen Viewer

- Added `SpotifyStoryViewer` modeled after `InstagramStoryViewer`. Receives an array of `NotificationItem` (spotify music items) and a start index. Features: full-screen black background, large album art with rotation/pulse animations driven by `MusicAnimationMetadata`, track/artist info, user avatar and name in the top bar, progress bar (one segment per item, 5s auto-advance), tap zones and swipe gestures matching Instagram stories.

### Preview URL scraping

- Added `SpotifyClient.trackPreviewURL(trackId:)` which fetches `https://open.spotify.com/embed/track/{id}` and extracts `audioPreview.url` from the inline JSON. Returns `nil` when no preview is available (many tracks don't have one). No authentication required — this is the public embed page.

### Audio playback

- Uses `AVPlayer` for streaming the 30-second MP3 previews. Play/pause/replay button shown below the album art. Automatically stops when navigating away or dismissing. Status is tracked via `PlayerStatus` enum (idle/loading/playing/paused/finished/unavailable).

### Feed integration

- `ContentView` stores a reference to `SpotifyClient` and passes it to `FeedView`.
- `StoriesBar` now distinguishes Spotify items from other story bar items: Spotify items use a `Button` that triggers the `SpotifyStoryViewer` full-screen cover, while non-Spotify story bar items continue to use `NavigationLink` to `NotificationDetailView`.
- `FeedView` has new `showSpotifyViewer` / `selectedSpotifyItemIndex` state and a `.fullScreenCover` for the Spotify viewer.
- Refactored the spotlight `SpotifyPulseRing` from `FeedView` into the viewer (adapted for larger `RoundedRectangle` shape at full size vs. `Circle` at thumbnail size).

### AGENTS.md

- Added `## Project Structure` section documenting the source tree, with a note to keep it in sync when files change.

### Auto-play and audio-duration progress bar

- Preview audio now auto-plays when the viewer opens and when navigating to a new item. No manual tap needed.
- Progress bar uses the actual audio duration (via `AVAsset.load(.duration)`) instead of a fixed 5 seconds. Falls back to 5s while the duration loads.
- During touch-and-hold (the existing drag gesture that pauses the progress bar), the audio also pauses/resumes.

### "Open in Spotify" link

- Replaced the pause/play button with an `Open in Spotify` `Link` that opens the track in the Spotify app or website via `target.url`.
- Removed `togglePlayback`, `playbackIcon`, and `playbackLabel` — no longer needed since playback is auto-managed.

### Circular album art

- Changed album art and pulse rings from `RoundedRectangle` to `Circle` to match the Spotify feed thumbnail shape.
- Moved pulse rings in front of album art (higher ZStack layer) so they visually originate from the album art border rather than from behind.

### Decoupling Spotify activity from notifications

- Added `SpotifyActivityItem` as a dedicated model with user, track, album, and animation metadata fields — no longer uses `NotificationItem` with `.music` type.
- Renamed `SpotifyNotificationSource` → `SpotifyActivitySource`. Still conforms to `NotificationSource` for `validateAccount`/`fetchProfile`/`healthCheckAllSources`, but `fetchNotifications` now returns `[]` (Spotify items no longer enter the notification cache). New `fetchActivity(reason:)` returns `[SpotifyActivityItem]`.
- `FeedViewModel` manages `spotifyActivityItems` separately from notification `items`, fetching them via `spotifyActivitySource.fetchActivity()` alongside Instagram story fetches.
- `FeedView` passes `viewModel.spotifyActivityItems` directly to the stories bar and viewer. Removed `isStoryBarItem` filtering, `StoryBubble`, `StoryThumbnail`, `StoryActorAvatar`, `storyAccentColor`, and the non-Spotify path in `StoriesBar` (only Spotify items were ever story bar items).
- New `SpotifyStoryBubble` renders `SpotifyActivityItem` directly in the stories bar using the existing `SpotifyAnimatedStoryThumbnail`.
- `SpotifyStoryViewer` now accepts `[SpotifyActivityItem]` with direct property access (e.g. `item.trackName`, `item.artistName`, `item.userAvatarURL`) instead of navigating `NotificationItem`'s actor/target graph.
- Added `album` field to `NotificationTarget` (retained for future use; Spotify no longer uses it but the field persists for compatibility).
