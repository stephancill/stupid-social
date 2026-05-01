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
