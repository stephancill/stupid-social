# Implementation Notes

## 2026-07-15

- Moved the Bluesky AT Protocol OAuth client metadata back onto the first-party `stupidtech.net` domain. The app client id is now `https://stupidtech.net/stupid-social/oauth/client-metadata.json`, the private-use redirect URI is `net.stupidtech:/oauth/bluesky/callback`, and the OAuth metadata Worker/checked-in metadata JSON now publish matching values. Added `scripts/bluesky-oauth-par-probe.py` to verify OAuth startup without completing browser login. Direct PAR probing for `@stephancill.co.za` showed this apex Worker route still fails from `https://pds.stupidtech.net/oauth/par` with `invalid_client` / metadata fetch status 404; Cloudflare's Worker routing docs say Worker routes cannot be targets of same-zone Worker `fetch()` calls, while Worker Custom Domains can. PAR probing with the same apex client metadata succeeds with HTTP 201 for Bluesky-hosted accounts `@bsky.app`, `@pfrazee.com`, and `@jay.bsky.team`, so the remaining failure appears local to the custom PDS fetching another same-zone Worker route. The route remains on `stupidtech.net/stupid-social/oauth/*` intentionally. This is an intentional breaking OAuth client change; existing Bluesky credentials should be reconnected after installing the updated app.
- Fixed the custom PDS same-zone metadata fetch for `@stephancill.co.za` in `/Users/stephan/environments/personal/pus/cirrus-pds-config`. The PDS Worker now has an `OAUTH_METADATA` service binding to the `stupid-social-oauth-metadata` Worker and wraps Cirrus PDS with a targeted fetch shim so only `https://stupidtech.net/stupid-social/oauth/client-metadata.json` is fetched through the binding. After deploying PDS version `b202a30b-0f88-4e09-a2c0-0c569d8ca304`, `scripts/bluesky-oauth-par-probe.py @stephancill.co.za --client-id https://stupidtech.net/stupid-social/oauth/client-metadata.json` returned HTTP 201 with a `request_uri`.
- Instagram story-like notification detail now hydrates the target story from story endpoints instead of relying only on the low-resolution activity thumbnail from `news/inbox`. Active stories use the existing `/stories/{username}/` story page path; archived stories use web REST `POST /api/v1/feed/reels_media/` with form field `reel_ids=["archiveDay:<archive_reel_id>"]`, which returned archived media with high-resolution `image_versions2.candidates` such as 1179x2096 in live probes. The detail path matches the notification media id to story media and uses the widest candidate URL, matching the stories viewer's image selection.
- Probed Instagram activity notifications with `scripts/instagram-web-client.py --simulator activity` after REST `news-inbox` returned HTTP 429. The GraphQL activity payload showed story-like rows have `args.media: null` and no story image candidates; the real story media id is embedded in `args.destination` as `feeditem_id=<media_id>_<owner_id>`, while the row `pk` is only a notification id. `InstagramNotificationParser` now uses `feeditem_id` for story-like notification targets when thumbnail media is absent, and story detail hydration also recovers `initial_media_id` and archive reel ids from existing cached target URLs before matching against story media.
- Search input now disables automatic capitalization and autocorrection so handles are entered exactly as typed. Profile detail hides follower/following/post count rows while a partial profile from search is hydrating, matching the existing bio behavior instead of showing dash placeholders. Notification detail target hydration is cached in `FeedService` by network/account/target id so navigating away from and back to the same detail screen reuses already-loaded post/thread details instead of briefly showing loading indicators again.
- Fixed expired Instagram web sessions being treated as generic story/feed failures. Instagram JSON requests now detect HTTP 200 login/challenge HTML responses from authenticated REST/GraphQL endpoints and throw `SourceError.notConfigured`; Instagram notification/story sources mark account metadata `invalidCredentials` while keeping the stale credentials available for checkpoint recovery. The Instagram settings screen now treats `invalidCredentials` as a reconnect state, shows a `Reconnect Instagram` login button, hides content toggles until a valid login is saved again, and seeds the reconnect WebView with the existing Instagram cookies so Instagram can present its own login challenge/checkpoint flow. The seeded WebView skips auto-completion on the first page load to avoid immediately re-saving the challenged cookie set before the user acts; newly captured reconnect cookies are deleted only if validation still reports an expired login.
- Added invalid-credentials attention indicators in Settings. The Settings tab shows a red badge when any credential-backed connection is invalid, and individual connection rows show a small red dot beside the affected network.

## 2026-07-14

- Added initial Bluesky support using AT Protocol OAuth. The app registers `dev.workers.stephan-cloudflare.stupid-social-oauth-metadata:/oauth/bluesky/callback`, starts authorization through discovered atproto OAuth authorization servers, performs PAR with PKCE and DPoP, exchanges authorization codes for DPoP-bound access/refresh tokens, stores tokens and the DPoP private key in the existing Keychain credential store, and saves DID/handle metadata in `AccountMetadataStore`. The OAuth client id is `https://stupid-social-oauth-metadata.stephan-cloudflare.workers.dev/stupid-social/oauth/client-metadata.json`; login requires that exact public JSON document to be hosted with matching metadata and redirect URI. `docs/BLUESKY_OAUTH_CLIENT_METADATA.json` contains the JSON content to publish.
- Added `BlueskyClient`, `BlueskyNotificationSource`, and `BlueskyConnectionView`. Bluesky notifications are fetched from `GET /xrpc/app.bsky.notification.listNotifications` and normalized into the combined feed; profile lookup/search use `app.bsky.actor.getProfile` and `app.bsky.actor.searchActors`, and notification post detail hydration uses `app.bsky.feed.getPostThread`.
- Added a Cloudflare Worker at `workers/oauth-metadata` plus `wrangler.toml` to serve the Bluesky OAuth client metadata at `https://stupid-social-oauth-metadata.stephan-cloudflare.workers.dev/stupid-social/oauth/client-metadata.json`. The Worker returns HTTP 200 JSON with no redirect for `GET` and `HEAD`, 405 for other methods on the metadata path, and 404 for other paths.
- Fixed Bluesky OAuth startup after live PAR testing returned two issues. Atproto requires private-use URI schemes for discoverable native client metadata to be the reversed fully qualified domain name of the `client_id`; the Worker client id therefore uses `dev.workers.stephan-cloudflare.stupid-social-oauth-metadata:/oauth/bluesky/callback`. Bluesky's PAR endpoint also returns the initial `use_dpop_nonce` challenge with HTTP 400 rather than 401, so `BlueskyClient` now retries nonce challenges on both statuses. The Bluesky login button is disabled until a handle or email is entered.
- Changed Bluesky OAuth startup to perform atproto discovery for handle login hints. For handles such as `stephancill.co.za`, the app resolves the handle to a DID, fetches the DID document, discovers the PDS service endpoint, reads the PDS protected-resource metadata, and uses that authorization server instead of hardcoding `bsky.social`. Live checks showed `stephancill.co.za` points to `https://pds.stupidtech.net`; using `bsky.social` for that DID produced an incorrect reactivation-account prompt. The client metadata URL was moved to the Worker `workers.dev` hostname after the custom-domain routes returned 404/523 to the custom PDS metadata resolver even though they were browser-visible.
- Future fix for Bluesky OAuth client metadata hosting: move the `client_id` back to a first-party custom domain once the PDS resolver issue is understood. Observed failures: `https://stupidtech.net/stupid-social/oauth/client-metadata-v2.json` returned HTTP 200 from browser/Node/WebFetch but `https://pds.stupidtech.net/oauth/par` reported `invalid_client` with `Client metadata fetch failed with status 404`; serving the same Worker route at `https://pds.stupidtech.net/stupid-social/oauth/client-metadata.json` changed the PDS error to status 523, implying the custom PDS could reach/attempt the hostname but Cloudflare/origin routing failed from the PDS environment. `wrangler tail` did not show Worker hits for the 404 case. The current working workaround is the Worker `workers.dev` URL, which live PAR-tested successfully against `https://pds.stupidtech.net/oauth/par` with HTTP 201. When revisiting, check Cloudflare route precedence/DNS/proxy settings for `stupidtech.net` and `pds.stupidtech.net`, whether the PDS blocks or rewrites same-zone/custom-domain fetches, and whether PDS client metadata resolution caches failed lookups.
- Added Bluesky network badge PNG resources from the favicon links advertised by `https://bsky.app`: `https://web-cdn.bsky.app/static/favicon-16x16.png`, `favicon-32x32.png`, and a 48x48 resized copy of `favicon.png` for `@3x`. The direct `https://bsky.app/favicon.ico` path returned 404.
- Added `scripts/bluesky-web-client.py`, a dependency-light Python probe for fetching Bluesky API responses with the OAuth credentials stored by the simulator app. It reads `tech.stupid.StupidSocial.credentials.bluesky.localFallback` through the `sim-prefs` helper, signs DPoP proofs from the stored P-256 private key, retries resource nonce challenges, and supports `notifications`, `post-thread`, and `profile` commands with `--output` for saving raw JSON fixtures under `logs/`. Live probing showed `app.bsky.notification.listNotifications` returns 18 notifications for `stephancill.co.za`; like/repost/follow notifications often have an empty `record.text` and only identify the target post through `reasonSubject`, so feed rows should not fall back to repeating the actor handle as the preview line.
- Fixed Bluesky notification row text for live payloads. Reaction reasons now map to explicit verbs (`liked`, `reposted`, `quoted`) instead of appending `ed` to the raw reason (`likeed`), target links are derived from `reasonSubject` when present, and Bluesky rows no longer show a duplicate actor handle preview when the notification payload does not include target post text.
- Fixed Bluesky notifications not appearing in the app feed. The live Bluesky API returns fractional-second timestamps such as `2026-07-14T12:00:50.268751Z`; Swift's default `JSONDecoder.DateDecodingStrategy.iso8601` did not decode these reliably, causing the entire `listNotifications` response decode to fail while other sources still refreshed. `BlueskyClient` now uses a custom date decoder that accepts ISO-8601 timestamps with and without fractional seconds. After reinstalling and launching the simulator app, the local SwiftData cache contained `bluesky|34` cached rows.

- Moved Settings into the root tab bar as a first-class tab beside Home and Search. Removed the feed/search toolbar gear links; the feed empty-state `Open Settings` action now switches to the Settings tab, leaving the Settings tab refreshes feed and stories as before, opening the Search tab now focuses the search field, and tapping the already-selected Home tab triggers the same feed/story refresh as pull-to-refresh.
- Increased dark-mode contrast for the initial stories loading skeleton by replacing low-opacity secondary gray fills with adaptive tertiary-label/separator colors.
- Fixed the pending `N New` toolbar button after SwiftUI rendered the prior `Label` in icon-only style in the navigation toolbar. The button now uses an explicit horizontal stack so the red dot and count text are both visible.
- Changed profile search to use search endpoints only. X uses `users/search.json`, Farcaster uses Hypersnap `GET /v2/farcaster/user/search?q=...&limit=10`, Instagram uses `/web/search/topsearch/`, and Spotify uses Pathfinder `findTopResults` (`sha256Hash=755858df4daab8d212980b02a81dcf8c9a58447de318b59d07c4651a1d0450b9`) while keeping only `usersV2` results. Python probes verified Spotify returns zero user results for `example user` even though album/artist sections are populated, preventing fabricated invalid fallback profiles.
- Fixed app search for capitalized Farcaster queries. Hypersnap `/v2/farcaster/user/search` is case-sensitive (`q=Stephan` returned no users while `q=stephan` returned results), so the Farcaster client lowercases search terms before sending them. Profile search also no longer suppresses repeated searches for the same typed query, allowing a manual retry after an empty or failed result.
- Fixed Instagram and Spotify search result decoding. Instagram topsearch returns `user.pk` as a string, so `InstagramUserInfoResponse.InfoUser` now accepts string or numeric ids. Spotify Pathfinder `findTopResults` can place users under `searchV2.topResultsV2.itemsV2` as `UserResponseWrapper` entries rather than `usersV2`, so the app and probe parse both locations and dedupe by username.
- Profile detail now treats search results as partial profiles. When a profile opened from search lacks detail fields such as bio, follower/following counts, post count, join date, website, or relationship state, the detail screen renders the search result immediately and lazily fetches the full profile in the background.
- Added Instagram profile posts to profile detail. Full Instagram profile hydration now fetches `GET /api/v1/feed/user/{id}/?count=12` after resolving the profile and maps returned media thumbnails into `NetworkProfile.posts`; `ProfileDetailView` renders those posts as a compact 3-column thumbnail grid when available. `web_profile_info` still provides post counts but returned empty timeline edges in live probes, so posts are intentionally loaded from the feed-user endpoint.
- Made Instagram profile posts best-effort during detail hydration. If `feed/user/{id}` fails or an item shape cannot be decoded, the profile detail still shows bio/counts from `web_profile_info` instead of failing the whole detail load.
- Fixed Instagram profile post decoding for live `feed/user/{id}` payload variants. Feed media and nested carousel media can mix string and numeric `id`/`pk` values, and nested `user.pk` can be string-valued; `InstagramMediaInfoItem` and `InstagramMediaUser` now decode those identifiers flexibly so one variant does not drop the full posts grid. Added a regression test that maps carousel media thumbnails into `NetworkProfilePost`.
- Changed Instagram profile posts to render as the final profile detail section. `NetworkProfilePost` now keeps a thumbnail URL separate from the full image URL; profile grids use the smallest available Instagram candidate and fixed square cells, leaving the full-resolution candidate available for a future post-detail view.
- Added pagination for Instagram profile posts. `feed/user/{id}` responses expose `more_available` and `next_max_id`; the client now sends `max_id` for subsequent pages, returns a normalized `NetworkProfilePostsPage`, and `ProfileDetailView` shows a native `Load more posts` footer that appends de-duplicated posts while preserving the next cursor.
- Restyled the Instagram profile posts section to behave more like the Instagram app gallery: the posts section is full-width within the profile detail, uses an icon tab strip above the selected grid, renders a tight 3-column square grid with 1pt gutters and no rounded thumbnail corners, and shows top-right badges for video and carousel posts.
- Removed the Instagram-style gallery tab strip because the app only exposes the default grid. Profile thumbnails now use measured square cells with fill-cropped images for a more consistent Instagram-like aspect ratio, and profile post pagination now auto-loads the next page when the bottom sentinel appears instead of requiring a manual load-more tap.
- Added a native Instagram post detail view for profile gallery taps. `NetworkProfilePost` now carries normalized media entries with full image, thumbnail, optional video URL, and video/carousel flags from `feed/user/{id}` `carousel_media` and `video_versions`; the detail view renders single media directly, carousel posts in a horizontal scroller, videos with `VideoPlayer`, captions below, and an optional external Instagram link.
- Fixed the Instagram profile grid disappearing after adding post detail support. Optional media detail fields (`caption`, `image_versions2`, `video_versions`, `carousel_media`, and nested `user`) are now decoded best-effort inside each media item so a malformed optional video/carousel payload cannot fail the whole `feed/user/{id}` posts page. Profile grid taps also use explicit selected-post navigation instead of inline `NavigationLink` cells inside the form grid.
- Fixed Instagram profile hydration from partial search results. Search results can include follower/profile metadata but omit `media_count` and posts, which previously made `ProfileDetailView` treat the profile as hydrated and skip the full profile/posts fetch. Instagram profiles with empty posts and unknown/nonzero post count now hydrate, and post fetch falls back to username if a numeric pk is unavailable.
- Reproduced the missing posts section for `stephaniekeenan_` with simulator credentials. `web_profile_info` succeeds and returns id `300947541` with a positive media count, but `GET /api/v1/feed/user/300947541/?count=12` returns Instagram anti-spam/feedback responses (`{"spam":true,"status":"fail"}` on the web path and `feedback_required` on mobile-style headers). Removed the silent `try?` around initial profile post hydration, made positive-media-count/zero-decoded-posts fail, included Instagram HTTP error bodies in `SourceError.serviceError`, and made `ProfileDetailView` show the posts hydration error in a visible Posts section when a partial profile is already displayed.
- Found the working profile-post endpoint for the same `stephaniekeenan_` session: `GET /api/v1/feed/user/{username}/username/?count=12` returns posts and paginates with `max_id`, while numeric `GET /api/v1/feed/user/{pk}/?count=12` returns the anti-spam response. `InstagramClient.userPostsPage` now uses the username route whenever the identifier is nonnumeric, initial Instagram profile hydration prefers `response.user.username` for post fetches, and subsequent profile pagination passes `profile.username` through `FeedService`.
- Reproduced `stephaniekeenan_` username-route pagination for 11 pages with simulator credentials and the app's base referer; each page returned 12 items with a next cursor. The profile pagination footer now surfaces the exact `error.localizedDescription` instead of the generic “Could not load more posts,” includes a retry button, and tracks auto-loaded cursors so one failing cursor is not repeatedly auto-requested while the footer remains visible.
- Tightened the native Instagram post detail layout. Media is now an edge-to-edge square area sized from available width instead of a fixed-height carousel with horizontal inset padding; carousel spacing is reduced to a 1pt seam, caption and external-link actions are grouped directly below the media, and the post title uses inline navigation display on iOS.
- Instagram post detail videos now auto-play when their media view appears and pause when it disappears, while still using the native `VideoPlayer` controls.
- Refined profile search: search now debounces typed input, Search keeps the settings gear available in its toolbar, search rows show the shared network icon badge beside the username instead of the network name, and iOS 26+ uses `tabBarMinimizeBehavior(.onScrollDown)` so the liquid-glass tab bar minimizes while scrolling.
- Added a tab bar with Home and Search tabs. Search uses the existing profile-fetching source capability to look up a typed handle across connected networks and shows separate network-specific profile results without cross-network identity merging. Farcaster search resolves usernames through Hypersnap before showing the profile detail screen.
- Added a small red dot to the pending `N New` toolbar button so newly available background/foreground notifications are more visibly actionable.
- Changed story refresh orchestration so story loading starts at the same time as notification feed refresh on initial launch, foreground activation, and pull-to-refresh. Story fetching is no longer gated on the feed refresh completing successfully, so the stories skeleton can appear immediately while both requests are in flight.
- Added an initial stories-bar loading skeleton. While `StoryBarViewModel` is fetching story content for the first time, `FeedView` now renders a placeholder stories row with pulsing avatar and label shapes instead of hiding the stories area until results arrive. Existing loaded stories remain visible during later refreshes.
- Fixed Farcaster reply detail rendering for parent casts. The detail view now hydrates `parentTarget` separately from the reply target and passes the fetched parent author/text/media/timestamp into the thread renderer. Previously the parent row used only the lightweight notification payload, which often contains just a parent hash/FID and therefore rendered as an incomplete Farcaster fallback row.
- Removed Farcaster reply-detail flicker and reduced parent-row relayout jank. Parent and reply rows now keep rendering their fallback post shells while details hydrate; rows with no text yet reserve space with lightweight placeholder bars instead of swapping between a spinner-only row and the final post content. Thread rows suppress the inline loading row because it briefly appeared below the already-rendered reply after parent hydration and caused visible layout jank.
- Refined the Farcaster parent loading skeleton so it does not show placeholder author fallback values such as a bare FID or generic network username while parent details are still loading.
- Fixed Instagram notification detail target attribution. Story/post notification targets now set `NotificationTarget.author` to the connected Instagram account, while the notification `actors` remain the people who liked/commented/followed. This prevents the Post section for story likes from showing Instagram/fallback or the liker as the post author; it now shows the user's own account when target details cannot be hydrated. If stored Instagram account metadata has no avatar, notification fetch opportunistically refreshes the current user profile and stores/passes that avatar into the target author.
- Fixed initial app launch refresh ordering. `ContentView` now triggers `FeedViewModel.refreshOnForegroundActivation()` immediately after creating the app container instead of relying only on a later `scenePhase == .active` transition, which can be missed if the scene is already active before dependencies are configured. This ensures freshly available Instagram notifications are fetched on open rather than only cached rows being shown.
- Fixed Instagram notification inbox decoding after live simulator payloads showed `args.profile_id` and `args.second_profile_id` now arrive as strings. The app previously expected numeric `UInt64` values, so a string profile id could fail decoding for the whole `news/inbox` response and leave Instagram notifications absent from the feed while other networks still refreshed. Instagram news story actor ids are now decoded through the existing flexible string helper, with a regression test covering the current story-like payload shape.
- Investigated Instagram story music sticker album art with live simulator credentials against `kirstendp_77`. The current web story-page payload included `story_music_stickers[].music_asset_info.title` and `display_artist` but no artwork URL field, so the app now treats missing artwork as an expected payload variant and renders the bottom music pill without a broken album-art square. The music pill includes a music-note icon plus title and artist. The decoder also accepts `cover_artwork_thumbnail_url` and `cover_artwork_url` variants in addition to the existing `_uri` keys when Instagram does provide artwork.

## 2026-07-13

- Changed the stories bar create-story affordance so tapping `+` in the combined All Stories feed opens a native destination menu with Instagram as the only current target. In the Instagram-specific stories feed, Instagram remains implied and the same `+` opens the story composer directly.
- Implemented Phase 5 of `docs/ARCHITECTURE_REFACTOR_PLAN.md`: renamed feed display/cache-diff state from unread/read to new/known. `DisplayNotificationItem` now exposes `isNew`; `FeedService` maps `revealedIds` to `isNew`, clears presentation-new state with `isNew: false`, and `FeedView` groups `newItems` and `knownItems` while preserving the visible `New` separator and layout behavior. `ReadWatermarkStore.isUnread` remains unchanged for explicit timestamp watermark read-state, and persisted `CachedNotification.isNew`/`isPending` remain in the SwiftData model but are still unused by `NotificationCacheStore` pending a future migration-aware cleanup.
- Implemented Phase 4 of `docs/ARCHITECTURE_REFACTOR_PLAN.md`: split `InstagramClient.swift` by reason to change while preserving existing Instagram request paths and parsing behavior. The client file now keeps the high-level facade/API methods, session/bootstrap/request/doc-id helpers live in `InstagramSession.swift`, Instagram response DTOs are grouped into notification/direct, story, and profile model files, and news/direct normalization parsers live in dedicated parser files.
- Implemented Phase 3 of `docs/ARCHITECTURE_REFACTOR_PLAN.md`: replaced the broad `NotificationSource` protocol with capability protocols for notification fetching, account validation, profile fetching, target details, stories, posting, and activity. `FeedService` now receives those capabilities directly, Spotify no longer pretends to be a notification source, source-level unread count support was removed, and target hydration was renamed from target metrics to target details while preserving existing refresh, profile, story, and notification-detail behavior.
- Implemented Phase 2 of `docs/ARCHITECTURE_REFACTOR_PLAN.md`: added `StoryBarViewModel` for story bar state/actions, Instagram story ordering/pagination/optimistic updates, Spotify activity fetching/seen marking, and story viewer helper methods. `FeedViewModel` now only owns notification feed state, refresh flags, pending-new count, feed errors, health check, and `FeedService` access. Added `SpotifyActivitySeenStore` to isolate the existing Spotify seen `UserDefaults` timestamp persistence. `AppContainer`, `ContentView`, and `FeedView` now observe/use both feed and story view models while preserving the previous initial load, pull-to-refresh, foreground refresh, story composer, unified viewer, like/delete, and seen-marking behavior.
- Implemented Phase 1 of `docs/ARCHITECTURE_REFACTOR_PLAN.md`: added app-layer `AppContainer` as the composition root for stores, clients, sources, `FeedService`, `FeedViewModel`, and `SettingsViewModel`. `ContentView` now owns only the container, passes through the exposed feed/settings view models and Spotify client, still loads the cached feed during setup, and still starts the initial story-bar fetch after the container is created.
- Added `docs/ARCHITECTURE_REFACTOR_PLAN.md` to capture the agreed architecture cleanup sequence: introduce an app composition container, split feed/story view model responsibilities, replace broad `NotificationSource` conformance with capability protocols, extract Instagram client DTO/parser/session files, and clarify new/pending/unread feed semantics. The document records source references, justifications, migration instructions, and verification expectations for each step.

## 2026-07-12

- Aligned the app's Instagram story-page doc ID discovery with `scripts/instagram-web-client.py`: `InstagramClient.storyReel(username:)` now scans both `/stories/<username>/` HTML and its loaded static JS bundles for Relay operation IDs. This preserves the web-client delete flow, where story-only mutations such as `usePolarisStoriesV3DeleteMediaMutation` can be discovered from story-page chunks before a GraphQL delete request.
- Replaced Instagram stories-tray reads with the working web REST path `POST /api/v1/feed/reels_tray/` after the current `PolarisStoriesV3TrayContainerQuery` GraphQL request began returning HTTP 400 `{"spam":true,"status":"fail"}` for otherwise-valid simulator credentials. `scripts/instagram-web-client.py stories-tray` and `InstagramClient.reelsTray()` now use the REST tray response; current-user resolution uses the authenticated `viewer` from `GET /api/v1/direct_v2/inbox/` before fetching `web_profile_info`.
- Simplified the feed empty state back to the native `ContentUnavailableView` with a vanilla bordered `Open Settings` button directly below it, grouped with tight spacing so the button stays near the centered empty-state content.
- Fixed Spotify WebView login completion handing off to the Spotify app. `SpotifyLoginWebView` now cancels non-web navigation schemes such as `spotify:`/app-store links and forces `open.spotify.com` completion redirects to load in the existing `WKWebView`, preserving WebPlayer token capture inside the app.
- Rebuilt the production Swift Instagram client around the proven mobile web behavior from `scripts/instagram-web-client.py`. `InstagramClient` is now stateful: it bootstraps `https://www.instagram.com/` with the iPhone Safari user agent, parses web runtime tokens/config, tracks `x-ig-www-claim`, discovers current Relay doc IDs from the loaded web bundles at runtime, and sends explicit selected-cookie headers instead of Android-private request headers for Instagram reads/writes.
- Moved Instagram notifications, Direct inbox, current-user validation, stories tray, profile lookup, story media extraction, story seen marking, story like/unlike, story upload, and story deletion to the web API path. Story tray data comes from `PolarisStoriesV3TrayContainerQuery`; story slide media is extracted from server-rendered `/stories/<username>/` Relay payloads; story upload uses `rupload_igphoto/fb_uploader_<upload_id>` plus web `configure_to_story`; delete and like/seen actions use dynamically discovered Relay mutation doc IDs. Media metrics lookup is temporarily unsupported because the previous Android `media/info` endpoint was intentionally removed from the production path.
- Fixed app story liking after the web rebuild by using the homepage-discoverable media like/unlike Relay mutations (`usePolarisLikeMediaXIGLikeMutation` / `usePolarisLikeMediaXIGUnlikeMutation`) with root fields `xig_media_like` / `xig_media_unlike`. The story-specific V4 like mutations can require story-page bundle discovery and the app's like call only has a media ID, not a username to pre-load `/stories/<username>/`.
- Changed the unified story viewer so Instagram image-slide progress only starts after the current slide's `CachedAsyncImage` completes loading or fails. Loading slides render the progress capsule in the same inactive/loading style as Spotify preview loading, preventing slow story images from being skipped before they are visible.
- Made Instagram story like/unlike optimistic in the unified story viewer: tapping the heart immediately updates the local slide state and haptic feedback, duplicate taps are ignored while the request is in flight, and failures revert the heart state while showing the existing error alert.
- Added `InstagramClient.currentUserProfile()`, which resolves the authenticated viewer through the stories-tray GraphQL response and then fetches the richer `web_profile_info` profile for that username. Instagram setup, account validation, revalidation, and the user's own story-composer actor now use this profile path so stored metadata includes the current username/avatar from the profile endpoint instead of relying on the minimal tray viewer object.
- Verified Instagram story seen marking against live simulator credentials. The current homepage bundle exposes `PolarisAPIReelSeenMutation`, not `PolarisStoriesV3SeenMutation`, so the Swift client uses `PolarisAPIReelSeenMutation` directly. Live testing also showed the mutation returns `xdt_mark_story_reel_seen: null` with an execution error when passed the full story `id` (`<media_pk>_<owner_id>`), and only advances the tray `seen` timestamp when passed numeric `pk`. Fetched `InstagramStorySlide.id` now uses `media.pk` (or the numeric prefix of `id`) so seen/like/delete mutations receive the numeric media ID.
- Added `scripts/instagram-web-client.py`, a dependency-free Python probe CLI for validating Instagram web APIs with cookies captured by the app/simulator auth flow. It can read simulator fallback credentials via `--simulator`, loads `https://www.instagram.com/` with an iPhone Safari web user agent, extracts web token/config state from the homepage, dynamically discovers GraphQL doc IDs by scanning loaded homepage JS modules for `*_instagramRelayOperation` definitions, and probes web GraphQL/REST calls for activity, stories tray, story media, profile, news inbox, and direct inbox. Normal output summarizes responses and token presence to avoid printing credential values; full JSON can be written explicitly with `--output` or printed with `--raw-output` for endpoint debugging. The CLI also has explicit `refresh` and `docids` commands, updates its in-memory cookie jar from Instagram responses, retries web API calls once after a fresh homepage bootstrap on HTTP 400/401/403 auth/CSRF-style failures, and can export rotated cookies with `--save-credentials`.
- Compared doc ID discovery with desktop Safari versus iPhone Safari user agents. Overlapping operation IDs were identical, but the mobile web user agent loaded a broader homepage chunk set (103 discovered operations versus 67 desktop operations in the live simulator probe). Mobile-only operations included media like/unlike (`usePolarisLikeMediaXIGLikeMutation`, `usePolarisLikeMediaXIGUnlikeMutation`), comment like/unlike, repost create/delete, save/unsave, follow/unfollow variants, and other write-adjacent mutations. Story seen mutations (`PolarisAPIReelSeenMutation`, `PolarisAPIForceStorySeenMutation`) were present in both. The probe CLI now defaults to iPhone Safari and sends the mobile web app id (`1217981644879628`) with `X-IG-Max-Touch-Points: 5`; the desktop web path is not currently pursued.
- Added an `upload-story-image` command to `scripts/instagram-web-client.py` for validating the mobile web story image upload flow. The probe posts raw JPEG bytes to `https://i.instagram.com/rupload_igphoto/fb_uploader_<upload_id>` with web rupload headers and then finalizes with `POST https://www.instagram.com/api/v1/media/configure_to_story/`. The command requires explicit `--width`/`--height` inputs.
- Added a `delete-story` command to `scripts/instagram-web-client.py` for validating the mobile web story deletion flow. Saved mobile web bundles showed `usePolarisStoriesV3DeleteMediaMutation_instagramRelayOperation` in the story page chunk, with root field `xdt_api__v1__create__delete` and variables shaped as `{ "mediaId": "<numeric media pk>" }`. The probe now supports loading `/stories/<username>/` before doc ID scanning, sends Relay mutation metadata (`fb_api_req_friendly_name`, `X-FB-Friendly-Name`, and `X-Root-Field-Name`), posts deletion to `/graphql/query`, and intentionally has no hardcoded doc ID fallbacks.
- Live-tested the story upload/delete probe path with simulator credentials. `upload-story-image` published the neutral test image and returned story media `pk` `3939762933499709460`; the stories tray then showed 8 entries with the viewer reel first for `stephancill`. `delete-story 3939762933499709460 --story-username stephancill` loaded the story page assets for live doc ID discovery and returned `did_delete: true`; a follow-up stories tray request showed 7 entries, confirming the test story was removed. Added `__pycache__/` to `.gitignore` because Python syntax checks/probe runs can generate bytecode caches.
- Added a local cache to `scripts/instagram-web-client.py` for dynamically discovered GraphQL doc IDs and the latest CSRF token metadata. The default cache path is `logs/instagram-web-client-cache.json` (already ignored by the repo), the default TTL is one hour, and the CLI exposes `--cache-file`, `--cache-ttl-seconds`, and `--no-cache`. Cached doc IDs avoid rescanning Instagram's JS bundles on every probe run while preserving the rule that doc IDs are never hardcoded in source.
- Extended `scripts/instagram-web-client.py` toward web-API parity with the app's Instagram surface without adding Android/private API emulation. The probe now exposes web-only current viewer lookup (`current-user` via stories tray GraphQL), username profile lookup (`profile-username` via `/api/v1/users/web_profile_info/`), direct inbox with the same useful query parameters as the app, story slide extraction from preloaded `/stories/<username>/` Relay payloads, story seen marking (`story-seen` via `PolarisStoriesV3SeenMutation`), force story seen marking, generic media like/unlike mutations, and story-specific V4 like/unlike mutations. Safe live reads confirmed `current-user`, `profile-username`, `news-inbox`, and `direct-inbox` work with the iPhone Safari session. The raw standalone stories media GraphQL resolver returns Instagram execution errors for tested tray reel IDs, so the advertised CLI uses `story-page` extraction instead.
- Verified the final advertised web probe commands with simulator credentials. The top-of-home stories list is `stories-tray` (`PolarisStoriesV3TrayContainerQuery`), which returns reel/user entries but not story slide media. Actual slide media can be read from the server-rendered `/stories/<username>/` page, so the probe now exposes `story-page` to extract the preloaded Relay story payload and to discover story-only mutation doc IDs. Live verification succeeded for `bootstrap`, `docids`, `activity`, `stories-tray`, `story-page sai.k1065`, `current-user`, `profile-username stephancill`, `news-inbox`, `direct-inbox`, `story-seen`, `force-story-seen`, `like-story`, `unlike-story`, `like-media`, `unlike-media`, `upload-story-image`, and `delete-story`. Sai's active story media `3939190598695291337` was used for like/unlike/seen testing and was explicitly unliked after verification. A fresh neutral test story upload returned media `3939830645252948024` and was deleted successfully with `did_delete: true`; a follow-up tray request returned 7 entries, confirming cleanup. Removed unverified `profile`, `reels-media`, and `post` convenience commands from the advertised CLI; raw `graphql` remains available for endpoint diagnostics.
- Investigated story sticker/tappable rendering data from live `/stories/<username>/` payloads and saved mobile web bundles. Current tray samples contained `story_bloks_stickers` with `ig_mention` sticker data, `story_feed_media` repost embeds, and `story_music_stickers`. Instagram's web bundle normalizer (`polarisGetTappableObjectsFromMediaDict`) maps additional payload fields into tappable object types: hashtags, guides, reel mentions, polls, locations, links, visual comment replies, feed media/clips, anti-bully Bloks tappables, generic Bloks stickers, text-post-share stickers, and fallback tappables for sliders/questions/countdowns. All mapped tappables share normalized geometry (`x`, `y`, `width`, `height`, `rotation`), so future native rendering can start with a generic overlay pipeline and add per-type content rendering as fixtures appear. Full-fidelity `BloksSticker` rendering remains fixture-dependent; the only live Bloks sticker variant observed so far is `ig_mention`.
- Updated `InstagramLoginWebView` to stop forcing an Android WebView user agent during browser login. The login flow now uses WKWebView's platform-native Safari user agent while still waiting for the complete cookie set required by both the existing mobile API and web API probes (`sessionid`, `csrftoken`, `ds_user_id`, `mid`, `rur`, and `ig_did`) before saving credentials.

## 2026-05-24

- Added an `Open Settings` call-to-action to the home feed empty state so users with no notifications or visible story content can navigate directly to connection setup. Restyled on 2026-07-12 as a compact prominent button close to the empty-state content.

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
- Gander notification endpoints (`gander/v2/GetUserHasUnreadNotification`, `gander/v2/GetNotifications`) work with `accept-language: en`, but live responses were marketing/concert notifications only. Social notifications likely require Dealer WebSocket integration and remain out of scope, so these endpoints are intentionally not exposed by the Python Spotify probe.
- Added `scripts/spotify-web-client.py`, a dependency-free Python probe CLI for Spotify WebPlayer APIs using the same credential sources as the app. It reads simulator fallback credentials from `tech.stupid.StupidSocial.credentials.spotify.localFallback` or explicit JSON, ports the WebPlayer TOTP token algorithm (`totpVer=61`, self-test `031750` for timestamp `1777993436`), refreshes transport/init bearer tokens through `open.spotify.com/api/token`, and probes buddylist, current profile attributes, user profile/follower/following endpoints, audio analysis, track preview extraction, library save state/add/remove Pathfinder calls, and custom spclient GET paths. Unlike the Instagram probe, Spotify request commands print full JSON responses by default; `--summary` is available for compact output.
- Live-verified `scripts/spotify-web-client.py` against the iOS simulator Spotify login. The simulator fallback credential blob contained bearer/client tokens, `sp_dc`, `sp_t`, `sp_key`, and init token metadata. `buddylist` returned friend listening activity, `profile-attributes` resolved the current profile as `stephan2882`, `track-preview 63iPYTdJKfwTo2YDWKHOqr` extracted an MP3 preview URL, and `audio-analysis 63iPYTdJKfwTo2YDWKHOqr` returned the expected large audio-analysis payload with track tempo/loudness/mode metadata. Probe outputs were saved under `logs/spotify-*.json`; the script now creates parent directories for `--output` paths.

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

### Audio session, ordering, and top bar fixes

- Configured `AVAudioSession` for `.playback` category in `SpotifyStoryViewer.onAppear` — fixes no audio on physical devices where the default category is ambient/silent.
- Sorted `spotifyActivityItems` by `timestamp` descending in `FeedViewModel.fetchSpotifyActivity()` so latest activity appears first.

## 2026-05-16

### Android Instagram APK proxy experiment

## 2026-05-17

- Hid the stories vertical cycling affordance when only one visible stories source is available. `StoriesBar` now shows a single Instagram or Spotify row for one-source content and only enables the All/Instagram/Spotify pager when both sources have visible content.

- Made Instagram story posting optimistic: `FeedViewModel.postInstagramStory` now writes the rendered upload bytes to a temporary local preview file, inserts that as the user's own story immediately, and starts the real Instagram upload in a background task. A successful upload refetches the story tray and replaces the optimistic slide when the server story appears; a failed upload removes the optimistic slide and surfaces a feed error.
- `CachedAsyncImage` now supports file URLs and configurable fit/fill content mode so optimistic local story previews can render in the unified story viewer without waiting for a remote CDN URL.

- Curl-verified Instagram Direct inbox with saved simulator credentials: `GET https://i.instagram.com/api/v1/direct_v2/inbox/?visual_message_return_type=unseen&thread_message_limit=10&persistentBadging=true&limit=20` returns HTTP 200 when using the fuller Android private API header set plus `Authorization: Bearer IGT:2:<base64 {ds_user_id,sessionid}>`. The raw live response was saved to ignored `logs/instagram-direct-inbox-sample.json` for decoder reference.
- Added unread Instagram DM feed support. `InstagramClient.notifications` now optionally fetches Direct inbox when the new `Direct Messages` category is enabled, derives unread threads from `last_permanent_item.timestamp > last_seen_at[viewer_id].timestamp` while ignoring viewer-sent latest messages, and normalizes them as `.message` `NotificationItem`s.
- Direct inbox failures are caught independently so existing Instagram `news/inbox` notifications are not dropped if Direct returns a gated service response.
- Chose not to add a category metadata migration for existing Instagram accounts. Accounts saved before `Direct Messages` existed must disconnect/sign in again to get the new default category set.
- Instagram DM notification summaries now include the message snippet directly (`username: message`) instead of only the generic `sent you a message` text, and notification detail labels the target section as `Message` for DM items.
- Fixed group DM summary wording to use the latest message sender for normalized text instead of the actor group summary, avoiding misleading labels like `sender and 4 others sent you a message` when only one person sent the latest message.
- Fixed Instagram DM previews for shared reels/posts by decoding `xma_clip` and `xma_media_share` payloads in addition to story XMA payloads. DM previews now use text, XMA title/caption/subtitle, or media-specific fallbacks like `Sent a reel by username` instead of generic `Sent a message`.
- Feed rows now show the XMA thumbnail for Instagram DM media fallbacks such as `Sent a reel by username`, matching the existing story-like thumbnail treatment instead of repeating the fallback text as the subtitle.
- Instagram DM detail views now suppress generic media fallback body text such as `Sent a reel by username` when an image preview is available, so the Message section shows the shared media preview/link rather than treating the fallback as message content.
- Added a dedicated Instagram `Messaging` settings section with `Direct Messages` and `Posts and Reels` toggles. `directMediaSharesEnabled` is persisted on `InstagramAccountMetadata`; when disabled, Direct notifications whose latest item is `xma_clip` or `xma_media_share` are suppressed.
- Plain/non-media Instagram DM row titles now use generic wording (`username sent you a message`) while the message content remains only in the row subtitle via `target.text`. Media-share DMs keep their media fallback summary behavior.
- Instagram DM detail views now render message content as a chat-style bubble with sender avatar/name, rounded bubble background, and optional shared-media thumbnail instead of the generic post-style target view.
- Instagram DM row titles for shared media now use media-specific wording (`username sent you a reel` / `username sent you a post`) while media context remains in the thumbnail/detail rather than in the title.
- Instagram DM detail bubbles now show the message timestamp beside the sender name using the shared compact relative time format.
- Instagram DM row titles for story replies now use `username replied to your story` for `xma_reel_share` items, with the reply text remaining in the subtitle.

- Replaced deprecated SwiftUI `Text` concatenation in feed row summary rendering with interpolated `Text` composition so iOS 26 builds no longer warn while preserving inline badge and bold actor styling.

- Set up an Android emulator experiment for the official Instagram APK at `third-party/instagram-429-0-0-32-70.apk` to compare native Android app requests against the Swift Instagram story-posting implementation from the previous commit.
- The existing `testAVD` initially failed to boot because its referenced system image `system-images/android-30/google_apis/arm64-v8a/` was missing. Installed `system-images;android-30;google_apis;arm64-v8a` with `sdkmanager`, then started the emulator with `ANDROID_SDK_ROOT=$HOME/Library/Android/sdk`.
- Added the mitmproxy CA as a system CA on the emulator. This required restarting the AVD with `-writable-system`, running `adb root`, `adb remount`, pushing the hash-named CA file into `/system/etc/security/cacerts/`, and rebooting.
- Port `8080` was already in use by macOS, so the capture proxy uses mitmproxy on port `8888`. The emulator global proxy is set to `10.0.2.2:8888`.
- Installed and launched Instagram package `com.instagram.android` (`versionName=429.0.0.32.70`, `versionCode=383506545`) from the APK. The app opened to the login screen.
- mitmproxy capture is writing to `logs/instagram-android-flows.mitm` with console logs in `logs/mitmdump-instagram.log`. The proxy and system CA were verified by decrypted Android/Google HTTPS traffic, but Instagram app-specific hosts had not appeared before login/user interaction. This may indicate that Tigon does not honor the Android global proxy for the relevant app traffic, or simply that authenticated app paths have not been exercised yet.
- A login attempt while the emulator global proxy pointed at mitmproxy failed in Instagram's native Tigon stack with `mbedtls_ssl_handshake(): Pin verification failed (-0x2700)`. The root cause is certificate pinning on Meta/Instagram TLS requests, not bad credentials. Cleared the emulator proxy with `adb -s emulator-5556 shell settings put global http_proxy :0` and restarted Instagram so login can be retried without interception.
- Updated `scripts/android-instagram-mitm.sh` to start mitmproxy with `--ignore-hosts` for likely pinned Meta domains (`instagram`, `cdninstagram`, `facebook`, `fbcdn`, `fbsbx`, `tfbnw`, `meta`, `whatsapp`). This passthrough mode avoids breaking pinned hosts but cannot decrypt those request/response bodies; deeper request capture will require Tigon/pinning instrumentation such as Frida/Objection or a patched APK.
- After successful login with the proxy disabled, restarted mitmproxy in pinned-host passthrough mode and re-enabled the emulator proxy. The emulator established connections to `10.0.2.2:8888` and Instagram did not emit the previous pin-verification failures, but ignored/passthrough hosts are not written as decrypted mitmproxy flows. This confirms mitmproxy can either break pinned Instagram TLS when intercepting or pass it through without useful request bodies; endpoint/body discovery needs instrumentation below Tigon or inside the app process.
- Added `scripts/android-instagram-mitm.sh` to reproduce the experiment: starts mitmdump, starts the writable AVD if needed, ensures the system CA is installed, sets the emulator proxy, installs the APK, and launches Instagram. Clear the emulator proxy with `adb -s emulator-5556 shell settings put global http_proxy :0` after the experiment.
- Installed Frida server/client version `16.7.19` for this emulator. Frida `17.9.10` attached to the process, but `Java.perform` failed with `Error: illegal instruction`; the older `16.7.19` Java bridge worked.
- Added Frida probe scripts for Instagram Java and native networking (`scripts/instagram-frida-hooks.js`, `scripts/instagram-frida-smoke.js`, `scripts/instagram-frida-native-net.js`, `scripts/instagram-frida-enumerate-native.js`, `scripts/instagram-frida-list-modules.js`, and `scripts/instagram-frida-libc-exports.js`). The scripts are diagnostics only and redact obvious cookie/token values.
- Native export enumeration showed Instagram's request stack is bundled in `libstartup.so`, with Tigon/MNS/proxygen/MCI symbols such as `TigonRequest`, `MCIURLRequest*`, `SSL_write`, `BIO_write`, `TigonUrl`, and `HTTPMessage`. Generic libc/socket and bundled TLS hooks saw traffic but mostly at encrypted/binary layers; C++ string argument decoding still needs more ABI-specific work.
- Java-level `com.instagram.api.tigon.TigonServiceLayer.startRequest` / `makeTigonRequest` hooks produced readable request URIs during an APK feed pull-to-refresh. The refresh issued requests to `https://i.instagram.com/api/v1/feed/reels_tray/` and `https://i.instagram.com/api/v1/feed/timeline/`, followed by CDN media requests and `https://graph.instagram.com/pigeon_nest` background requests.
- Added `com.facebook.pando.PandoGraphQLRequest` hooks. During the same refresh, one observed GraphQL request was `IGDirectGetPresenceQuery` with root field `ig_direct_get_presence`; the primary feed refresh paths above were direct Tigon REST requests, not Pando GraphQL.
- Captured a full Android APK story-photo publish flow with `scripts/instagram-frida-story-capture.js`. The app first uploaded WebP bytes to `https://i.instagram.com/rupload_igphoto/3273093631227_0_2037642386`, then finalized with `https://i.instagram.com/api/v1/media/configure_to_story/`.
- The upload request used `Content-Type: application/octet-stream`, `X-Entity-Type: image/webp`, `X-Entity-Length: 8726`, and `X-Instagram-Rupload-Params` containing `upload_id=3273093631227`, `media_type=1`, `share_type=stories`, `is_optimistic_upload=false`, `image_compression` (`libwebp`, version `30`, quality `86`, original size `1280x720`), `xsharing_user_ids=[]`, and zeroed `retry_context` counters.
- The configure request body was `application/x-www-form-urlencoded; charset=UTF-8`, 3700 bytes, with `signed_body=SIGNATURE.<urlencoded-json>`. Decoded JSON included `upload_id=3273093631227`, `configure_mode=1`, `source_type=3`, `async_publish=1`, `audience=default`, `original_media_type=1`, `original_width=1280`, `original_height=720`, `camera_entry_point=11`, `camera_position=back`, `client_shared_at=1778961818`, `timezone_offset=7200`, `edits.crop_original_size=[1280,720]`, `edits.filter_type=0`, `edits.filter_strength=0.5`, and `extra.source_width/source_height=1280/720`.
- Clean capture artifacts were written under `logs/`: raw log `instagram-frida-story-capture.log`, upload body `instagram-story-upload-3273093631227_0_2037642386.webp`, configure form body `instagram-story-configure-to-story-body.txt`, decoded configure JSON `instagram-story-configure-to-story-body.decoded.json`, and summary `instagram-story-post-capture-summary.json`. These files contain runtime request data and should remain uncommitted.
- Curl-tested the APK-like flow against simulator Instagram credentials using `/Users/stephan/Downloads/sample-story.jpg`: local conversion to 1280x720 WebP with quality 86, raw `POST /rupload_igphoto/{upload_id}_0_{random}` with `application/octet-stream`, WebP `X-Entity-*` headers, APK-style `X-Instagram-Rupload-Params`, then signed `POST /api/v1/media/configure_to_story/`. Rupload consistently returned HTTP 200 with `status=ok`, but configure returned Instagram's generic HTTP 500 publish failure. Retried with the captured configure template, APK-shaped device identifiers, APK-style random 13-digit upload IDs, and candidate 64-hex APK string keys; finalize still returned the same publish failure. No runtime logs or generated request files were added to source control.
- Replaced the app story posting request shape with the official APK-like flow despite the live curl finalize block: the composer now encodes rendered stories as WebP, `InstagramClient.publishPhotoStory` uploads WebP bytes to `i.instagram.com/rupload_igphoto/{upload_id}_0_{random}`, uses `upload_id` as both `upload_id` and `session_id`, sends WebP `X-Entity-*` headers plus `X_FB_PHOTO_WATERFALL_ID`, and finalizes with signed `configure_to_story` on `i.instagram.com` using the existing HMAC signing helper and `ig_sig_key_version=4`.
- Configure payload fields are parameterized from the generated upload and rendered image dimensions: `original_width`, `original_height`, `edits.crop_original_size`, `extra.source_width`, `extra.source_height`, and WebP `image_compression.original_width/original_height` all match the uploaded bytes. The app keeps portrait 1080x1920 composer output rather than forcing the APK capture's 1280x720 camera dimensions.
- Fixed composer posting for text-only stories after testing showed ImageIO does not expose a WebP encoder on the current Apple platform (`CGImageDestinationCopyTypeIdentifiers` lacks `org.webmproject.webp`). The composer now tries WebP first but falls back to JPEG encoding when WebP export is unavailable, while keeping the same APK-like rupload/configure flow and matching `X-Entity-Type` plus `image_compression` metadata to the actual uploaded bytes. This is an intentional runtime deviation from the captured APK until a bundled WebP encoder is added.
- Fixed the `configure_to_story` publish step. Live curl testing showed both the APK-like WebP upload and the older `instagram-private-api` JPEG upload reached `rupload` successfully but `configure_to_story` returned a generic HTTP 500 when sent with cookie auth. Calling `accounts/current_user` exposed Instagram's mobile `ig-set-authorization` header, which is deterministically `Bearer IGT:2:<base64({ds_user_id,sessionid})>`. Retrying the same uploaded media with that `Authorization` header and no `Cookie` header made `configure_to_story` return HTTP 200 with completed media. Story posting now uses this mobile authorization header for upload/configure only; read endpoints continue using explicit cookies.

## 2026-05-11

### Notification detail native post section

- `NotificationTarget` now carries optional display-safe native post metadata: multiple image URLs, author, posted timestamp, and cached like count. Decoding preserves compatibility with existing cached `targetData` rows that only stored `imageURL`.
- X targets populate author, tweet creation time, all tweet media URLs from `extended_entities.media`, and `favorite_count` when present in `notifications/all.json`.
- Farcaster targets populate cast author, cast timestamp, embed URLs, and `reactions.likes_count` when Hypersnap includes it. The detail view also loads fresh target metrics on appear via `GET /v2/farcaster/reaction/cast?hash=...&types=likes&fid=<cast_author_fid>`, counting the returned likes so the displayed value is total likes available from the detail endpoint rather than only the actors in the notification activity. Passing `fid` is required for reliable hash resolution; without it the endpoint can return zero likes.
- Instagram targets continue using notification-safe media thumbnails and now thread them through the new multiple-image field. Detail view loads `GET /api/v1/media/{media_id}/info/` on appear, using the hydrated media owner as the post author, `like_count` as the total likes, caption text when available, and full media/carousel image URLs. If the notification media id includes an owner suffix, the client retries with the stripped media id after a failed request.
- `NotificationDetailView` now renders target content in its own `Post` section with a native post-style header, author avatar/name, relative post time, full text, full-width images, total like count when available, and an external-link affordance when a target URL is available.
- Added `NotificationSource.fetchTargetMetrics(for:)` and `FeedService.fetchTargetMetrics(for:)` for on-demand detail-screen target hydration. X implements this with `GET https://x.com/i/api/1.1/statuses/show.json?id=...&tweet_mode=extended` and reads `favorite_count`; unsupported sources return `.unsupported` and the UI silently falls back to cached target metadata.
- Fixed target hydration dispatch: `fetchTargetMetrics(for:)` must be a protocol requirement, not only a protocol-extension helper, otherwise calls through `any NotificationSource` resolve to the default `.unsupported` implementation and never reach Farcaster/Instagram/X source implementations.
- Farcaster target hydration now falls back to the notification `accountId` as the cast author FID when older cached targets do not include `target.author`. It also fetches `GET /v2/farcaster/cast?identifier=...&type=hash&fid=...` to refresh post author/display text/timestamp in detail. The post header prefers display name over username.
- Instagram story-like notifications expose aggregate story-like counts in `rich_text` rather than `counts` or `media/info`. For `story_like`, normalization now parses patterns like `@a, @b and N others liked your story` and stores `2 + N` in `NotificationTarget.likeCount` so story details can show the total story-like count when target media hydration does not provide one.

### Instagram story rendering endpoint probe

- Live-probed `POST /api/v1/feed/reels_media/` with simulator Instagram credentials, using the existing `reels_tray` IDs and redacting CDN URLs from command output. A 12-reel sample returned 50 story items: 14 video items (`media_type = 2`) and 7 post-embed items with `story_feed_media`.
- Video story items include `video_versions` arrays with directly playable MP4 URLs, dimensions, and type values, plus `video_duration`; the app already decodes `video_versions` into `InstagramStorySlide.videoURL` but `UnifiedStoryViewer` currently renders only `imageURL`.
- Post/reel reshares are represented by `story_feed_media` entries. Observed fields include `media_code`, `media_id`, `media_compound_str`, `media_type` (for example `sidecar`), `product_type` (for example `feed`), and normalized placement fields (`x`, `y`, `width`, `height`, `rotation`, `start_time_ms`, `end_time_ms`). The detail payload does not hydrate a separate caption/thumbnail for the embedded post; the story image itself remains the flattened visual preview. `media_code` is sufficient to build an external Instagram post link such as `https://www.instagram.com/p/{code}/`.
- Other available overlay arrays in the sample include `story_music_stickers`, `story_locations`, and `story_captions`; these can be layered later if needed, but video playback and a simple post/reel embed link are the most direct rendering improvements from the current endpoint response.
- Implemented richer story rendering from those fields: `InstagramStorySlide` now carries optional `videoDuration`, `embedURL`, and `embedLabel`; `InstagramStoryMedia` decodes `video_duration` and `story_feed_media`; and `InstagramNotificationSource` builds Instagram post/reel links from `story_feed_media.media_code`.
- `UnifiedStoryViewer` now plays Instagram video stories with `AVPlayer`/`VideoPlayer`, uses video duration for progress when available, pauses playback during touch-and-hold, and shows an `Open post`/`Open reel` link overlay when the story contains a feed-media embed.
- Replaced SwiftUI `VideoPlayer` for Instagram stories with a small `AVPlayerLayer` wrapper (`UIViewRepresentable`/`NSViewRepresentable`) so video playback has no native transport controls overlapping the app's story progress/header controls.
- Live `story_music_stickers` entries expose `music_asset_info.title`, `display_artist`, `cover_artwork_thumbnail_uri`, and optional audio URLs. The app now decodes title/artist/artwork into `InstagramStoryMusic`, carries it on `InstagramStorySlide`, and renders a compact music metadata pill at the bottom of Instagram story slides. Sticker audio URLs are not separately played; story video/audio remains the single active `AVPlayer` stream.
- Added a mute toggle to the unified story viewer top bar. It applies immediately to the active `AVPlayer` and is reused for Instagram video audio and Spotify preview playback.
- Disabled animations on the mute toggle state change so the icon swaps immediately without SwiftUI's default button/content transition.

### Connection screen status cleanup

- Connection detail screens now hide webview login buttons and manual/dev setup inputs once an account is configured. Farcaster likewise hides the username input and save button after setup.
- Connection detail Status rows now use the same per-network connection labels as Settings, showing the stored username/handle when available instead of the generic `Valid` status.
- Connection detail rows are labeled `Connection` instead of `Status` to better describe the displayed account identity/state.
- Credential save success messages no longer duplicate the connected account identity with `Connected as @...`; the account identity is shown only in the Status field.

### Farcaster Notification Type Filters

- Added Farcaster notification category filtering for mentions, replies, reactions, and follows, matching Instagram's per-type settings pattern.
- `FarcasterAccountMetadata.enabledCategories` persists the selected category set and defaults older saved accounts to all categories enabled.
- `FarcasterNotificationSource` filters normalized Farcaster items before reaction/follow grouping and unread counts so disabled categories are hidden consistently.

### Spotify story top bar

- Replaced static "Listening" subtitle in the top bar with `item.timestamp.compactRelativeTime` so it shows the relative time since the user listened.

### Pulse rendering refactor

- Switched from `.repeatForever` animation to manual timer-driven phase interpolation. A `pulsePhase` counter advances each timer tick (0.05s) and resets when it reaches `pulseDuration`. The ring's scale and opacity are computed directly from `phase / maxPhase`, so each cycle fades to zero before restarting — no visible snap between cycles.
- Ring size reduced to 260px (from 280px album art size) so it starts slightly inside and emerges from behind the album art.
- Single pulse ring (was two staggered rings).
- Pulse ring moved behind album art in ZStack so the stroke never overlaps the art.
- Extracted `SpotifyPulseRing` into a shared `Views/SpotifyPulseRing.swift` used by both the full-screen viewer and (if needed) the feed thumbnail.
- Removed pulse rings from feed `SpotifyAnimatedStoryThumbnail`; the thumbnail now only spins album art.
- Removed orphaned animation helpers (`confidence`, `loudnessIntensity`, `pulseDuration`, `pulseScale`, `pulseOpacity`) from `SpotifyAnimatedStoryThumbnail`.

### Instagram story reel ordering

- Slides within each reel are now sorted by `takenAt` descending (newest first) in `InstagramNotificationSource.fetchStoryReels()`.
- Reels are sorted by: (1) unseen first, then (2) latest slide timestamp descending. Shared `sortReels` helper used in both `instagramReels()` and `markInstagramReelAsSeen()`.
- The `latestReelMedia` field from the Instagram tray model is available but not used for sorting since actual slide `takenAt` is more reliable.
- Story bar display ordering remains newest-first, but opening an unread story now starts an oldest-first viewer queue. Unread Instagram reels also reorder their slides oldest-first only for playback so unread story sessions advance chronologically without changing the bar's visual ordering.

### StoriesBar loading gate

- Added `@Published var storyBarLoading` to `FeedViewModel`. Set to `true` before `fetchStoryBarContent()` starts and `false` after both Instagram and Spotify fetches complete.
- `FeedView` now requires `!viewModel.storyBarLoading` before showing the stories bar, preventing partial rendering when one provider loads before the other.

### Inline images for X and Farcaster notifications

- **X**: Added `XExtendedEntities` / `XMediaEntity` models to decode `extended_entities.media.media_url_https` from tweet objects. Both `parseTweetEntry` and `parseNotificationEntry` pass the first media URL as `imageURL` on `NotificationTarget`.
- **Farcaster**: Added `FarcasterEmbed` model to decode `embeds` on `FarcasterCastResponse`. Hipersnap cast embeds contain `url` fields; the first embed URL is passed as `imageURL` on `NotificationTarget`.
- **FeedView**: Removed the `cdninstagram.com` URL gate in `previewContent` — any notification with a non-nil `imageURL` now shows the 48×48 inline thumbnail regardless of network.
- Hipersnap API confirmed embeds response shape with live `GET /v2/farcaster/notifications` probe.

### Test fixes for macOS compilation

- Tests failed because the test target compiles for macOS but used iOS-only APIs. Fixed with `#if os(iOS)` / `#else` conditionals:
  - `SpotifyStoryViewer`: wrapped `AVAudioSession` calls in `#if os(iOS)`
  - `XLoginWebView`, `InstagramLoginWebView`: added `#if os(iOS)`/`#else` blocks with `NSViewRepresentable` for macOS, and `#if os(iOS)` around `.navigationBarTitleDisplayMode(.inline)`
  - `FeedView`: wrapped `.fullScreenCover` in `#if os(iOS)` with `.sheet` fallback for macOS
- All 19 tests pass (1 skipped, 0 failures).

### Instagram story viewer timestamp

- Replaced Apple's `RelativeDateTimeFormatter` (yielding localized strings like `"3 min. ago"`) with the shared `Date.compactRelativeTime` extension (yielding compact strings like `"3m"`), matching the Spotify story viewer and feed rows.

### StoriesBar refresh behavior

- Initial story bar loading now fetches Instagram stories and Spotify activity together before publishing either result, preventing a partial one-source stories bar from flashing first.
- Pull-to-refresh and foreground refresh no longer hide the existing stories bar while replacement story content is loading. The previous stories remain visible until both refreshed sources have completed and are swapped in together.

### Spotify story user slides

- Spotify story activity is now deduplicated by `userURI` after sorting newest-first, so each Spotify user contributes at most one story bubble/slide.
- `SpotifyStoryViewer` now shows a single progress segment for the current user's slide instead of rendering every Spotify user as a stop in one combined progress bar. Taps/swipes still advance between users.
- Spotify story progress now starts only after the preview audio begins playing. While the preview URL/player is loading, the full progress bar pulses gray as a loading indicator.
- Removed tap/press-to-pause from `SpotifyStoryViewer`; taps are reserved for navigating between Spotify user slides.
- Replaced `SpotifyStoryViewer` album-art `.repeatForever` rotation with timer-driven rotation phase updates so navigation and playback state changes do not restart or slow the rotation animation.
- Increased the Spotify story viewer animation tick from 20 fps to 60 fps so timer-driven album-art rotation remains smooth in full-screen playback.

### Instagram story seen state

- Instagram story bubbles now treat the tray `seen` field as a timestamp rather than a boolean. A reel is seen only when `seen` is greater than or equal to the newest fetched slide's `takenAt`, so users correctly return to the unseen ring when they post a newer story after their previous stories were seen.
- Instagram story viewer presentation now uses a snapshot of the story reels captured at tap time and marks reels seen by stable reel id. This prevents the live stories bar re-sort after marking the tapped reel seen from changing which reel appears at the viewer's current index.
- Instagram story presentation now uses a single identifiable selection payload for the full-screen cover/sheet, instead of separate boolean/index/snapshot state. This prevents the viewer from presenting against an empty snapshot during state update ordering, which could show a blank modal for already-seen stories.

### Spotify activity seen state

- Added local seen tracking for Spotify activity stories using `UserDefaults` timestamps keyed by Spotify `userURI`. A user's latest activity is considered seen only when the stored timestamp is greater than or equal to that activity timestamp, so new listening activity becomes unseen again.
- Spotify activity bubbles now render unseen users with the green ring and seen users with a gray ring. Activity is sorted unseen-first, then newest-first.
- Spotify story presentation now uses a snapshot payload and marks activity seen by stable `userURI`, avoiding live stories-bar reordering from changing the currently presented user.
- Spotify activity story rings now use the same simple 3px circle stroke style as Instagram story borders, with green for unseen activity and gray for seen activity.
- Spotify full-screen album art is keyed by image URL and shows a loading placeholder during `AsyncImage.empty`, preventing the previous user's album art from lingering after navigation.
- Fixed Spotify unseen story rings using gray by restoring `Color.spotifyActivityBorder` to Spotify green; seen rings remain the same gray as Instagram seen stories.
- Removed the spinner from Spotify full-screen album-art loading; the image area now pulses gray while `AsyncImage` is loading.
- Replaced `AsyncImage` with a generic `CachedAsyncImage` backed by a shared `StoryImageCache` for all avatars across the app: Instagram/Spotify story bubbles, viewer top-bar avatars, feed notification row avatars, notification detail actor avatars, and profile detail avatars. Previously loaded images render instantly across all screens.

### Debug redaction

- Added UI-only username redaction when `devModeEnabled` is active. Feed rows, story bubbles/viewers, notification detail people rows/content, profile headers, and settings connection labels replace usernames/display names with `Redacted` while leaving stored source data unchanged.

### Unified story feed

- Combined Instagram stories and Spotify listening activity into a single reverse-chronological unified stories bar and viewer (`UnifiedStoryViewer`).
- Introduced `StoryBarItem` enum in `AppModels` wrapping `.instagram(InstagramStoryReel)` and `.spotify(SpotifyActivityItem)`, with unified `id`, `timestamp`, `isSeen`, `userAvatarURL`, `userName`, and `network` accessors.
- `FeedViewModel` now publishes a single `storyBarItems: [StoryBarItem]` array sorted unseen-first then newest-first. `fetchStoryBarContent()` merges both provider fetches atomically.
- `StoriesBar` in `FeedView` renders all items from one sorted list. Each bubble type (`InstagramStoryBubble` / `SpotifyStoryBubble`) renders from `StoryBarItem` cases in the bar; provider-specific rendering is localized to the bubble views, not centralized in the bar.
- `UnifiedStoryViewer` is a pure navigation container: progress bar (N segments for Instagram multi-slide, N=1 for Spotify), top bar (avatar + name + time + close), swipe/pause gestures, auto-advance timer, and Spotify audio playback. Provider-specific slide content (Instagram image, Spotify album art with pulse ring and track info) lives in `StoryBarItem` extensions, not in the viewer body.
- The progress bar is unified: Instagram reels with multiple slides show segmented progress; Spotify's single-slide-per-item is just the N=1 case of the same segmented bar.
- Navigation swipes between items regardless of provider; swipe down dismisses; touch-and-hold pauses Instagram auto-advance only (Spotify removed tap-to-pause per prior design).
- Replaced the two separate `fullScreenCover`/`sheet` modifiers with a single `StoryViewerSelection` payload.
- Removed `InstagramStoryViewer.swift` and `SpotifyStoryViewer.swift`.

### Instagram reels media batch limit

- Investigated missing Instagram stories for simulator account `helaineduv`. `POST /api/v1/feed/reels_tray/` returned 179 tray entries, with 116 active user reels after app filtering, but the single `POST /api/v1/feed/reels_media/` request for all 116 reel IDs returned HTTP 400 `Too many reels requested`.
- Live probes showed `/feed/reels_media/` succeeds with 30 reel IDs and fails at 40. `InstagramClient.reelsMedia(reelIds:)` now chunks requests into batches of 30 and merges the returned reel map so large accounts still render stories.
- The batch requests now run concurrently to reduce story bar load time for accounts with large trays while preserving the 30-ID request cap.

### Feed refresh after settings

- Returning from `SettingsView` to the feed now triggers `FeedViewModel.refreshOnForegroundActivation()`, reusing the existing safe refresh policy: X count-only, fetch-capable sources refresh cache/story content, and pending new items remain gated behind the new-items affordance.

### Story avatar refresh stability

- Investigated Instagram story avatar flashes after refresh. Live tray probes showed Instagram returns different signed `profile_pic_url` values for the same users between `reels_tray` calls, usually with the same CDN path but different query parameters. The image cache previously keyed only by full URL, so refreshed story items missed cache and briefly rendered placeholders.
- `CachedAsyncImage` now accepts an optional stable `cacheKey`; when a refreshed URL misses the URL cache but the logical key has an image, it keeps showing the previous image while fetching and updating the new signed URL. Instagram story avatars use `instagram-avatar-<userId>` and Spotify avatars use `spotify-avatar-<userURI>`.

### Instagram story refresh failure handling

- Returning from Settings can trigger story refresh while existing story content is visible. If Instagram's story fetch fails transiently while Spotify succeeds, the unified story list previously replaced existing Instagram stories with a Spotify-only list. `InstagramNotificationSource.fetchStoryReels()` now throws on tray failures instead of collapsing them to an empty result, and `FeedViewModel.fetchStoryBarContent()` preserves existing Instagram stories for transient Instagram failures while still clearing them when Instagram is not configured.

### Story viewer swipe navigation

- Horizontal swipe gestures in `UnifiedStoryViewer` now jump directly between story users/items. Tap zones still navigate within the current Instagram user's slides, preserving familiar story behavior: tap advances slide, swipe advances user.
- Replaced the competing invisible button tap zones, pause gesture, and navigation gesture with one unified drag gesture. This allows horizontal swipes to be recognized anywhere in the viewer, preserves short tap left/right for slide navigation, and prevents a long-press pause from advancing/skipping when released.

### Instagram muted stories

- Live `reels_tray` payload inspection confirmed Instagram includes mute metadata in tray entries: top-level `muted`, plus `user.friendship_status.is_muting_reel` and `user.friendship_status.muting`. `InstagramTrayItem` now decodes these fields and `InstagramNotificationSource.fetchStoryReels()` filters muted tray entries before deduping users or fetching story media.
- Live `reels_tray` payload inspection confirmed Instagram exposes close-friends story availability as `has_besties_media` and `latest_besties_reel_media` on tray entries. `reels_media` did not expose a matching per-slide close-friends field in a 12-reel/61-item sample. `InstagramStoryReel` now carries `hasCloseFriendsMedia`, and Instagram story bubbles render a green star badge at the bottom-right when `has_besties_media` is true.
- Unread Instagram Close Friends stories now sort before other unread stories in both Instagram-only reel ordering and the unified stories bar. Seen ordering remains timestamp-based after the existing seen/unseen split.
- Debugged story posting failure from simulator CFNetwork logs: the image upload request with the large story body returned HTTP 403 before `configure_to_story` ran. `publishPhotoStory` now uses cookie-authenticated mobile headers for `/rupload_igphoto/...` and keeps the mobile `Authorization: Bearer IGT:2:...` header for the configure step. Publish failures now surface the failed step/status in the composer instead of a generic retry message.
- Fixed the follow-up `configure_to_story` HTTP 403 `login_required` failure: live auth probes showed Instagram accepts the mobile `Authorization: Bearer IGT:2:<base64-json>` header only when the base64 padding is preserved. The app no longer strips trailing `=` padding from that bearer payload.

## 2026-05-12

### Story composer scaffold

- Added a presentation-only story composer opened from the first bubble in the stories bar. The composer starts with Instagram as the displayed target, has a top-right vertical editing toolbar with image selection as the first tool, and fits a selected local image centered on the fullscreen canvas.
- Added a text tool as the second composer toolbar action. Each tap creates a new centered editable text caption; captions move live while dragged around the story canvas after editing, and tapping the canvas outside captions clears focus. On iOS, dragging is backed by small UIKit overlays so pan updates move native text views directly instead of triggering SwiftUI layout on every frame. State is kept local to the composer.
- No upload, submit, account-selection, or cross-posting network logic was added; the composer state is local UI scaffolding only.

### Instagram story posting investigation

- Inspected `third-party/instagram-429-0-0-32-70.apk` via DEX strings because `jadx`/`apktool` are not installed. The APK contains the same private posting endpoints used by `instagram-private-api`: `/rupload_igphoto/{name}`, `/rupload_igvideo/{name}`, `/api/v1/media/configure/`, `/api/v1/media/configure_sidecar/`, `/api/v1/media/configure_to_story/`, and `/api/v1/media/configure_to_clips/`.
- The checked-in `third-party/instagram-cli/node_modules/instagram-private-api/dist` has the clearest request reference. Story photo publishing is a two-step flow: upload JPEG bytes to `/rupload_igphoto/{upload_id}_0_{random}` with `X-Instagram-Rupload-Params` containing `media_type=1`, `upload_id`, `retry_context`, `xsharing_user_ids=[]`, and JPEG compression metadata; then `POST /api/v1/media/configure_to_story/` with a signed form containing the upload id, dimensions, `source_type=3`, `configure_mode=1`, `client_shared_at`, `edits.crop_original_size`, `edits.crop_center`, and `edits.crop_zoom`.
- Story video publishing is longer: upload MP4 to `/rupload_igvideo/{name}` using video rupload params (`media_type=2`, dimensions, duration, upload id, retry context), upload a cover image to `/rupload_igphoto/` with the same upload id, call the upload-finish endpoint with `source_type=3` and video length, then `POST /api/v1/media/configure_to_story/?video=1` with a signed form including `clips`, `extra.source_width`, `extra.source_height`, `audio_muted`, `poster_frame_index`, dimensions, length, and `configure_mode=1`.
- Close Friends story publishing uses `audience=besties` in the configure-to-story form. Direct story sends use `configure_mode=2` with `recipient_users`, `thread_ids`, `view_mode`, `reply_type`, and `client_context` instead of normal story audience publishing.
- Sticker/link metadata is serialized into configure-to-story fields such as `reel_mentions`, `story_hashtags`, `story_locations`, `story_polls`, `story_sliders`, `story_questions`, `story_countdowns`, `story_cta`, `attached_media`, `story_chats`, `story_quizs`, and `story_sticker_ids`. Link stickers are represented as `story_cta=[{ links: [{ webUri: ... }] }]`.
- Configure requests are `signed_body` form posts using the existing Instagram HMAC key/version (`ig_sig_key_version=4`), matching the signing path already implemented for `markStorySeen`. Upload requests are raw `application/octet-stream` bodies with explicit `Content-Length`, `X-Entity-*` headers, and `X-Instagram-Rupload-Params` JSON.
- No live post/upload test was performed during this investigation to avoid creating visible Instagram content or leaving server-side uploaded media without explicit approval.

### Instagram story deletion investigation

- Inspected the APK DEX strings and `instagram-private-api` deletion references. The shared media deletion endpoint is `POST /api/v1/media/{mediaId}/delete/?media_type={PHOTO|VIDEO|CAROUSEL}`. The signed form contains `igtv_feed_preview=false`, `media_id`, `_csrftoken`, `_uid`, and `_uuid`.
- The APK also contains story-adjacent deletion endpoints and actions: `media/%s/delete/`, `media/%s/delete/?media_type=%s`, `media/%s/deleted_info/`, `media/%s/delete_stitched_media_story_parts/`, `media/%s/delete_story_countdown/`, `media/story_comment/delete/`, `media/%s/async_delete_story_poll_reply/`, `media/%s/async_delete_story_quiz_reply/`, and `stories/prompt_stickers/delete_story_template/`. For deleting a normal active story item, the generic media delete endpoint is the primary candidate.
- `instagram-private-api` exposes `media.delete({ mediaId, mediaType })` for feed/photo/video/carousel media and `highlights.deleteReel(highlightId)` for deleting an entire highlight reel via `POST /api/v1/highlights/{highlightId}/delete_reel/` with a signed `_csrftoken`/`_uid`/`_uuid` form.
- Direct-message story/item deletion is separate from public story deletion: `POST /api/v1/direct_v2/threads/{threadId}/items/{itemId}/delete/` with `_csrftoken` and `_uuid` only.
- No live delete test was performed. Before implementing destructive deletion in the app, test against a throwaway story created explicitly for this purpose and verify whether Instagram expects `media_type=PHOTO` for image stories and `media_type=VIDEO` for video stories, or whether story media accepts either value based on the media id.

### Login region and verification hardening

- Investigated user feedback that Instagram requested many verification steps and Spotify could not find the account. No South Africa-specific region lock was present, but the login flows had hard-coded locale/browser identity hints: Spotify used `/en/login` with a fixed iPhone Safari user agent, and Instagram used an old Android Chrome login user agent while API calls used a different Instagram Android app user agent with `en_US` locale.
- Spotify login now uses `https://accounts.spotify.com/login` without a fixed `/en/` locale or custom webview user agent. Spotify API requests now send `Accept-Language` from `Locale.preferredLanguages` instead of hard-coded `en`.
- Spotify login now sets the post-login `continue` URL to `https://open.spotify.com/?nd=1` so the web player loads after login without relying on a navigation-cancel/rewrite fallback.
- Instagram login now uses a more current Android WebView user agent. Instagram API calls keep using the Instagram Android app user agent, because live simulator probes showed saved sessions return HTTP 400 `useragent mismatch` with the WebView user agent while the app user agent succeeds for both `current_user` and `reels_tray`. API calls still use a device-local `Accept-Language` header instead of hard-coded English locale hints.
- Instagram login no longer dismisses as soon as only a `sessionid` cookie appears. The WebView waits until all cookies required by the mobile API session are present (`sessionid`, `csrftoken`, `ds_user_id`, `mid`, `rur`, and `ig_did`) before saving and closing. This lets verification continue until the cookie set is complete without requiring navigation to the home screen.

### Spotify story preloading

- `UnifiedStoryViewer` now preloads adjacent Spotify stories' preview audio in the background by resolving the previous/next preview URLs, creating `AVURLAsset`s, and loading their durations. When the user navigates to a preloaded Spotify story in either direction, playback creates the `AVPlayerItem` from the warmed asset instead of starting from a cold URL fetch.

## 2026-05-13

### Farcaster reply notification discrepancy

- Live Hypersnap check for FID `1689` and cast `d03cc675be6caa0ae98df283a989d3341083d901` found `GET /v2/farcaster/cast/conversation` returns 4 direct replies with `parent_hash` equal to that cast and `parent_author.fid == 1689`.
- The same cast appears repeatedly in the first `GET /v2/farcaster/notifications?fid=1689&limit=50` page as `likes` target data, but none of the 4 direct replies appear as `reply` notifications. Given the reply timestamps are interleaved with first-page like timestamps, they would be expected in the current notifications response if parent-based reply lookup were active.
- Conclusion: Hypersnap can read the replies through the conversation path, but the deployed notifications endpoint is still omitting direct parent-based replies for this case.


### Feed and story feedback pass

- Pull-to-refresh now short-circuits while foreground/on-appear refresh is active and the refresh modifier is removed during active refresh state, preventing overlapping manual and automatic refreshes.
- `FeedViewModel` now runs a safe foreground-style auto refresh every 15 seconds. This reuses the existing automatic policy: X stays count-only through the source path, fetch-capable sources update cache/story content, and pending new notifications remain gated behind the `N New` affordance.
- Manual refresh now treats changed cached grouped notifications as new, not only brand-new IDs, when a non-X group gains actor IDs under the same stable group ID. X grouped notifications are excluded from this diff because the live X notifications endpoint can vary grouped actor metadata between consecutive fetches without an actual new notification.
- Notification detail no longer displays `Loading post details`; target hydration now shows only a compact loading indicator. Multiple target images render as a horizontal carousel instead of a vertical stack.
- Reply details render a `Parent Post` section when sources provide `parentTarget`. X reply entries populate this from in-memory parent tweets when X includes the parent in `globalObjects.tweets`; Farcaster stores parent hash/author metadata when Hypersnap provides it, but full parent text still depends on a future source response or targeted hydration.
- Story seen marking is delayed until after the full-screen presentation animation window completes, avoiding immediate seen-state changes before the modal visibly settles.
- Story entry behavior now depends on the tapped item: tapping an unread story opens only unread story-bar items, while tapping a seen story opens that user's story item/slides only.
- Instagram story rendering now decodes and displays lightweight rich metadata pills for `reel_mentions` and `story_link_stickers`, linking @mentions to Instagram profiles and story links to their target URLs.
- `UnifiedStoryViewer` preloads adjacent Instagram story images in addition to existing adjacent Spotify audio preloading.
- Spotify activity now carries the Spotify buddylist track context name and displays it as `From ...` below album metadata when available, surfacing playlist/context information for the song.

### Spotify login validation

- Spotify credential saves now require `SpotifyClient.validateAccount()` to resolve the authenticated username through the `profileAttributes` API. The previous fallback username (`"spotify"`) was removed because it could make incomplete credentials look valid.
- If username resolution fails after captured credentials are saved, the settings flow now deletes the saved Spotify credentials, clears Spotify account metadata, sets a service-error status, and shows an explicit retry message instead of treating the login as a successful connection.
- `SpotifyConnectionView` keeps the login button visible whenever no Spotify username is connected, including service-error states, so users can immediately retry after a failed credential capture/validation.

### Seen story navigation

- Tapping a seen story now opens the full seen-story set, starting at the tapped item, instead of limiting navigation to only that user's story item. Tapping an unread story continues to open only unread story-bar items.

### Story mention profile navigation

- Instagram story @mention pills now navigate to `ProfileDetailView` when the `reel_mentions` payload includes a user id. `UnifiedStoryViewer` receives the shared `FeedService` and wraps its content in a `NavigationStack` so mention taps use the same native profile detail path as notification detail People rows. Mentions without a user id remain non-navigating text pills.

### Auto refresh interval removal

- Removed the 15-second foreground auto-refresh loop from `FeedView`. The app still refreshes on foreground activation and supports pull-to-refresh, but no longer polls continuously while the feed is open.

### Spotify story progress behavior

- Removed the animated Spotify loading-progress pulse in `UnifiedStoryViewer`; loading now uses a stable gray progress track so the full-screen modal does not show a bouncing/pulsing loader during presentation.
- Spotify story slides now advance immediately when the preview `AVPlayerItem` reaches end-of-playback. The timer also permits `.finished` Spotify status so elapsed-duration fallback behavior remains consistent with Instagram story slides.

### Instagram music story duration

- Instagram story music stickers decode clip timing from `start_time_ms`/`end_time_ms` when present, with fallback duration fields from `music_asset_info` (`duration_in_ms`, `duration_ms`, `audio_asset_duration_ms`) for future audio handling.
- Instagram story timing remains media-driven: video slides use `video_duration` when available, while still-image slides stay at the default 5 seconds even when they have a music sticker. The app does not currently play a separate Instagram music audio asset; video audio continues to come from the story video stream itself.

### X tweet notification category

- Added `XNotificationCategory` with configurable Mentions, Replies, Reactions, and Tweets categories. `XAccountMetadata` now persists enabled X categories with a default of all categories enabled for existing stored accounts.
- `XConnectionView` now shows the same per-category notification toggles used by Farcaster and Instagram. `SettingsViewModel` persists X category toggle changes through `AccountMetadataStore`.
- X post/tweet notification elements such as `device_follow_tweet_notification_entry`, `user_tweeted`, `user_tweeted_entry`, `tweet_notification`, and `user_posted` normalize to the new `.post` `NotificationType`. The X source filters normalized notifications through the configured X category set before returning items to the feed.
- Live simulator credential testing against `GET /i/api/2/notifications/all.json` showed the missing ~21h tweet notification is a `notification` entry with `element: device_follow_tweet_notification_entry`, `url.title: Posts`, non-empty `fromUsers`, and an empty `targetTweets` array. The parser now treats these notification entries as supported even without a target tweet, rendering them from actor metadata and the notification `sortIndex` timestamp.

### Instagram story pagination

- Changed Instagram story loading so `reels_tray` still establishes the full ordered tray, but `/feed/reels_media/` is requested only for the first 15 active, unmuted reels initially. Spotify activity is fetched in the same initial story-bar pass, so the first page across providers is merged before display without fetching all Instagram media pages.
- Added lazy Instagram story pagination: when the user reaches the end of the currently loaded story row, `FeedViewModel.loadNextStoryBarPage()` requests the next 15 Instagram reels and appends them to the unified stories bar. Additional pages are Instagram-only because Spotify activity has no paginated story provider path in the current implementation.
- `NotificationDetailView` now hydrates X `.post` notifications on demand with `GET /i/api/2/notifications/device_follow.json`. The feed remains no-fanout; detail fetches the current device-follow timeline and renders each returned tweet as a separate native post card. Live probing confirmed the endpoint returns `globalObjects.tweets` plus tweet timeline entries; X's grouped notification entries can omit `targetTweets`, so detail intentionally shows the device-follow feed instead of trying to correlate a stale grouped notification to exact tweet IDs.
- Updated product/technical direction so foreground activation refresh full-fetches X notifications rather than count-only polling. The app accepts X's possible server-side read side effect for foreground/manual refresh because current feed content is preferred.
- Foreground activation cache writes now replace only the networks that successfully refreshed, instead of replacing the entire notification cache with the partial result set. This preserves cached X/Farcaster rows when another foreground source succeeds while X or Farcaster fails transiently.
- Manual refresh now returns the existing cached feed without surfacing a blocking refresh alert when every source fails but cached notifications are available. If the cache is empty and all sources fail, the alert is still shown so first-run/account problems remain visible.
- Manual refresh now also replaces only successfully refreshed networks that returned items, matching foreground refresh. Failed networks and networks that transiently return an empty result keep their existing cached notifications, so consecutive refreshes cannot clear the feed just because one source failed or returned no current entries.
- Root-caused the reproducible post-auto-refresh manual refresh alert to task cancellation, not API failures: simulator logs showed X, Farcaster, and Instagram all failing with `NSURLErrorDomain Code=-999 cancelled`. `FeedView` used a conditional `.refreshableIf(!isForegroundRefreshing && !isRefreshing)` modifier; when pull-to-refresh set `isRefreshing = true`, SwiftUI recomputed the view, removed the `.refreshable` modifier, and cancelled the in-flight refresh task. The fix keeps `.refreshable` attached permanently and relies on `FeedViewModel.refresh()` guards to ignore overlapping refresh attempts.

## 2026-05-14

### Spotify liked-song status in full-screen viewer

- Added `areEntitiesInLibrary` (hash `134337999233cc6fdd6b1e6dbf94841409f04a946c5c7b744b09ba0dfe5a85ed`) and `addToLibrary` (hash `7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d`) Pathfinder GraphQL operations to `SpotifyClient` for checking and setting track library status.
- These queries require the initial browser login Bearer token (from `reason=init`) which carries library scope. Refreshed WebPlayer transport tokens do not have sufficient scope.
- Spotify login now captures the transport Bearer token plus `sp_dc`/`sp_t`/optional `sp_key`, then `SettingsViewModel` fetches `https://open.spotify.com/api/token?reason=init&productType=web-player` natively after account validation and stores the returned token and expiry as `initialBearerToken` / `initialBearerTokenExpiresAt` on `SpotifyCredentials`.
- `SpotifyCredentials` gained `initialBearerToken: String?`, `initialBearerTokenExpiresAt: Date?`, and optional `spKey` to preserve the init token separately from the regular transport token and retain all relevant Spotify session cookies.
- Live Pathfinder testing showed `areEntitiesInLibrary` returns `403 Forbidden` without browser-like `Origin`, `Referer`, and `User-Agent` headers even when the token is valid. The Spotify library check/add requests now send those headers.
- `UnifiedStoryViewer` checks liked status for each Spotify story slide via `SpotifyClient.isTrackSaved(trackId:)`. When saved, shows a "Saved" badge with checkmark. When not saved, shows a `+` button that calls `SpotifyClient.saveTrack(trackId:)` to add the track to the user's Liked Songs.
- The Spotify story save control is icon-only and sits to the right of the "Open in Spotify" button at the same 44-point height; saved tracks render as a white checkmark in a green circle.
- Live mutation testing confirmed `addToLibrary` and `removeFromLibrary` share hash `7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d` and require variables shaped as `{ "libraryItemUris": ["spotify:track:..."] }`. The saved checkmark now calls `removeFromLibrary` so the control toggles liked-song state both ways.
- Refactored Spotify Pathfinder calls behind `SpotifyClient.makePathfinderRequest(...)` and `pathfinderBody(...)` so auth, app, content type, language, and browser-origin headers are defined in one place instead of repeated across profile, library check, add, and remove operations.
- Spotify liked-song save/remove toggles now trigger a light iOS impact haptic after the API call succeeds and the visible state changes. macOS remains a no-op.

## 2026-05-17

### Instagram profile lookup and story composer polish

- Live simulator probes confirmed Instagram `/api/v1/news/inbox/` and `/api/v1/users/{id}/info/` still return valid profile detail data with the saved simulator credentials.
- Added Instagram story liking from the unified story viewer. The viewer shows a heart control for non-own Instagram story slides and tracks `has_liked` from `/api/v1/feed/reels_media/` when present. Live testing against the `dhlstormers` story showed generic `POST /api/v1/media/{media_id}/like/` returns HTTP 200 with `status=fail` and does not change `has_liked`; the working story-specific path is `POST /api/v1/story_interactions/send_story_like/` and `/unsend_story_like/` with the mobile `Authorization: Bearer IGT:2:...` header, `media_id`, `container_module=reel_feed_timeline`, tray/viewer session ids, `delivery_class=organic`, `like_type=REGULAR`, and `like_duration=0`.
- Added username-based Instagram profile lookup through `/api/v1/users/{username}/usernameinfo/` and made `FeedService.fetchProfile` pass the actor username for Instagram, matching the existing X username lookup behavior. This keeps profile detail working when cached or story-derived actor ids are non-numeric/stale but a username is available.
- Wired the iOS story composer's UIKit trash-target visibility back into SwiftUI state. The bottom `Post Story` button now hides while the trash icon is visible during caption dragging, then returns after the drag ends or the caption is deleted.
- Live-posted `/Users/stephan/Downloads/sample-story.jpg` using simulator Instagram credentials. Rupload and `configure_to_story` both returned HTTP 200 with `status=ok`; a subsequent reels tray check showed the own-story entry present with `media_count=2`.
- The unified stories bar now hard-splits unseen and seen story items. Unseen Instagram/Spotify items sort first by timestamp, seen items follow by timestamp, and the horizontal bar renders a compact `Seen` divider at the boundary when both groups are present.
- Fixed the 12-hour expiry failure: liked-song check/save/remove now use the captured init token only while it is still fresh, then attempt to refresh a new `reason=init` token from the persisted Spotify session cookies and save it back to credentials. If that refresh fails, the library path falls back to `credentialsForRequest()` so the normal refreshed WebPlayer bearer token is used. Live simulator testing confirmed an expired init token returns `401` while the refreshed bearer token still succeeds for Pathfinder library operations when browser-origin headers are present.
- Requires re-login to Spotify in the app for the init token to be captured; existing stored credentials do not have `initialBearerToken`.

## 2026-05-16

### Story composer text deletion

- Story composer text captions now show a bottom-center trash target while an iOS text caption is being dragged. Dropping the caption over the highlighted trash target removes it from local composer state.
- The implementation keeps the existing UIKit-backed drag overlay for smooth movement and reports drag center points back to SwiftUI only for trash affordance visibility/deletion.
- The trash affordance was moved fully inside the UIKit drag canvas after SwiftUI state updates during every pan caused visibly low-refresh dragging. SwiftUI is now notified only when a drag finishes and whether the caption should be deleted.
- Added a composer toolbar download button on iOS. It renders the current local story composition to a 1080x1920 image with the selected photo aspect-fit on black plus text caption overlays, then saves it to Photos with add-only photo library permission.
- Successful story image saves now give non-modal feedback by temporarily changing the download toolbar icon to a checkmark; alerts are reserved for failures or missing permission.
- The story composer empty state now hides as soon as any local element exists, including text-only compositions without a selected background image.
- The story composer canvas now always has a tappable background layer, so tapping outside a focused text element clears text focus even in text-only compositions where no image or empty-state view is visible.
- The composer save button is enabled for any local composition element, not only selected photos. Text-only stories render as white caption overlays on a black 1080x1920 canvas.
- Fixed a text-drag flash near the trash target by preventing drag-time UIKit layout passes from resetting the text view to its committed offset; active drags now only relayout the trash target.
- Added a background color toolbar control to the story composer. Tapping cycles through solid black/white/blue/purple and gradient sunset/ocean/graphite backgrounds; selected backgrounds count as composition elements and are included in saved 1080x1920 story renders.
- The background toolbar control now matches the other toolbar buttons: a translucent circular button containing a smaller live circular swatch of the selected solid or gradient background.
- Text captions now store a per-element scale and support pinch-to-resize on iOS through the existing UIKit overlay. Pan and pinch gestures can recognize simultaneously, resizing stays local to UIKit during the gesture, and the committed scale is included in saved story renders.
- Focused iOS text captions now attach a keyboard accessory toolbar with `BG`, `Font`, `Color`, and `Done` controls. The first three controls cycle per-caption text background, font style, and text color, and those style choices are included in saved story renders.
- The text editing accessory toolbar is always attached to focused iOS text views. Toolbar controls use current-value icons: background swatch, font-styled `A`, text-color swatch, and keyboard-dismiss icon.
- Text captions now visually recenter only the focused UIKit text view while editing, without mutating the caption's saved offset or moving other captions.
- Fixed the text accessory toolbar controls collapsing together by giving each custom toolbar button explicit dimensions, internal center constraints, and spacing.
- Removed the extra filled background from custom text accessory toolbar buttons so the controls render as single toolbar icons/swatches rather than buttons inside buttons.
- While a text caption is focused for editing, the composer now inserts a dim tint overlay between the canvas/background and text overlays, isolating the active editing text without hiding other captions.
- Text caption layer ordering now places non-focused captions below the dim overlay and the focused caption above it.
- Focused text captions now animate into and out of the temporary edit position while preserving their saved canvas offset.
- The focused-text dimming overlay now ignores safe areas so the tint covers the full story composer backdrop.
- Removed the ineffective Core Animation suppression around text overlay layout. The composer now ignores keyboard safe-area resizing so the canvas and unrelated text overlays do not shift with keyboard presentation.
- Focused text captions now use an upward edit-center offset, placing the editing text slightly above the canvas center while keeping the saved caption position unchanged.

### Instagram story posting

- Updated product/technical scope to include Instagram story posting now that the original notification-focused MVP is implemented.
- Added `InstagramClient.publishPhotoStory(jpegData:width:height:)`, using the researched two-step private API flow: raw JPEG upload to `/rupload_igphoto/{upload_name}` with `X-Instagram-Rupload-Params`, then signed `POST /api/v1/media/configure_to_story/` with upload id, dimensions, crop metadata, and account CSRF/device fields.
- Added `InstagramNotificationSource.postPhotoStory` and `FeedViewModel.postInstagramStory` so the composer can post through the existing source/client path and refresh story bar content after a successful publish.
- Story composer now has a post toolbar action. It renders the current 1080x1920 composition to JPEG and posts it to the connected Instagram story; save-to-Photos remains a separate local action.
- The first stories-bar bubble now represents the user's own Instagram story entry when account metadata/profile lookup is available: it shows the user's profile picture and a bottom-right `+` affordance, and tapping it opens the composer.
- The composer post action is now exposed as a prominent bottom `Post Story` button so posting is discoverable; the toolbar download button remains the local save action.
- Own Instagram stories in `UnifiedStoryViewer` show a top-bar kebab menu with a destructive `Delete Story` action. The action presents a confirmation dialog, then calls `POST /api/v1/media/{mediaId}/delete/?media_type=PHOTO|VIDEO` through `InstagramClient.deleteStory` and refreshes story bar content after success.
- Live API debugging found story photo upload succeeds but story configure still fails: `POST /rupload_igphoto/{upload_name}` returns HTTP 200 with `status: ok`, while `POST /api/v1/media/configure_to_story/` returns HTTP 500 `We're sorry, but something went wrong during media publish. Please try again.` for the same upload. A regular feed `POST /api/v1/media/configure/` with the same uploaded image succeeded, so credentials, upload bytes, and basic write access are valid. The accidental feed test post was deleted successfully.
- Reproduced the same `configure_to_story` HTTP 500 through the patched `instagram-private-api` reference implementation, indicating the failure is not Swift-specific.
- Decompiled Instagram Android 429.0.0.32.70 under ignored `third-party/instagram-429-decompiled` for request comparison. The official story builder confirms `media/configure_to_story/`, photo upload through `rupload_igphoto`, `include_e2ee_mentioned_user_list=1`, `upload_id`, `original_width`, `original_height`, `original_media_type=1`, `client_shared_at`, `client_timestamp`, `source_type`, optional `audience`, and `configure_mode` values derived from `ShareType`.
- Curl retries using APK/reference-aligned variants all still returned the same HTTP 500: signed and unsigned bodies, `configure_mode` values `1`, `2`, `3`, `11`, and `13`, `audience=default`, `source_type` `3` and `4`, `supported_capabilities_new`, `device_id`, `original_media_type`, `original_width`/`original_height`, `width`/`height`, `device`, `extra`, cookie-jar propagation from upload to configure, and story-specific `share_type=stories` rupload params.
- `GET /api/v1/accounts/current_user/?edit=true` with the same session returned HTTP 200 but no obvious story creation capability flag beyond `reel_auto_archive=on`. The remaining likely blockers are an official-client session capability/header not captured by webview cookies, a changed server-side requirement not present in the old `instagram-private-api` flow, or account/session trust gating specific to story publishing.
- Captured and curl-verified Instagram's web story publish flow. It uploads to `https://i.instagram.com/rupload_igphoto/fb_uploader_{upload_id}` with web app id `1217981644879628`, `Content-Type: image/jpeg`, and `X-Instagram-Rupload-Params` containing only `media_type`, `upload_id`, `upload_media_height`, and `upload_media_width`. Configure then posts an unsigned form to `https://www.instagram.com/api/v1/media/configure_to_story/` with `caption`, `configure_mode=1`, `upload_id`, and `jazoest` (`"2" + sum(CSRF unicode scalar values)`) plus web headers (`X-Requested-With`, `X-CSRFToken`, `X-ASBD-ID`, `X-Web-Session-ID`, and `X-Instagram-AJAX`). This returned HTTP 200 and created a story with the simulator credentials; the test story was deleted successfully afterward.
- Updated `InstagramClient.publishPhotoStory` to use the verified web story publish flow while leaving mobile API reads, story fetches, seen marking, and deletes unchanged.
- The first stories-bar bubble now opens the user's own active Instagram story when one exists. `FeedViewModel` separates the authenticated user's reel into `ownInstagramStoryReel` so it is not duplicated in the regular unified story list; the small `+` affordance on that bubble still opens the composer.
- The own story bubble is now hidden until the initial unified story-bar fetch completes. `FeedViewModel.storyBarContentLoaded` gates `StoriesBar` rendering so the user's bubble appears atomically with fetched Instagram/Spotify story content instead of flashing alone during startup.
- The own-story kebab menu no longer advances the story. Top-bar interactions are ignored by the story navigation gesture, and tapping the kebab pauses the current Instagram story timer/video before showing the delete menu.
- The own story bubble now renders its story outline with the same logic as regular Instagram story bubbles: gradient ring for unseen own stories, gray ring for seen own stories, and only a subtle placeholder outline when there is no active own story.
- Replaced the own-story delete `Menu` with an explicit kebab button plus `confirmationDialog`, because SwiftUI `Menu` did not reliably expose its open state for pausing. The kebab now pauses before presenting actions, resumes on cancel/dismiss, and stays paused while delete confirmation is pending.
- Replaced the first-step system story action dialog with a compact in-view action menu anchored near the kebab. The story remains paused while this menu is open, resumes when tapping outside it, and only uses the system confirmation dialog for the destructive delete confirmation.
- The in-view story action menu now has explicit `Delete` and `Cancel` rows; `Cancel` dismisses the menu and resumes the paused story.
- The Instagram own-story/posting bubble is hidden when no Instagram account is connected. The unified stories bar can still render non-Instagram story content such as Spotify activity without showing an unusable posting entry.
- Live simulator tray analysis showed Instagram's `reels_tray` order is only weakly chronological while strongly separating unseen from seen reels. The story bar now takes Instagram's first 15 fetched reels, merges that prefix with Spotify listening stories in reverse chronological order, then appends the remaining Instagram reels in their original fetched order. This gives the visible head of the bar a chronological feel while preserving Instagram's algorithmic ordering for the long tail.
- Added story-bar feed modes for `All Stories`, `Instagram`, and `Spotify` as a masked vertical pager. All rows are rendered in a fixed-height vertical scroll area so the next/previous row is visible during vertical scrolling, but only one row is visible at rest. Each row keeps independent horizontal story scrolling and launches the story viewer scoped to that row.
- Deleting an Instagram story slide from `UnifiedStoryViewer` now removes that slide from the active viewer state immediately, so the progress tabs and visible content update without waiting for the feed/story-bar refresh. The own-story kebab menu now only contains `Delete`; cancellation happens in the system confirmation dialog.
- Fixed tapped-story/viewer mismatch for unseen stories. The viewer now preserves the tapped story row's newest-first user ordering and starts at the tapped user; only the slides inside unseen Instagram reels are reordered oldest-first for chronological playback.
- Lowered the Swift package iOS platform minimum from `.v26` to `.v18`; macOS remains `.v26`.
- Added `UIDesignRequiresCompatibility=false` to `Info.plist` so generated iOS app plists explicitly opt out of compatibility-mode design requirements.
- Diagnosed iOS 26 Liquid Glass disappearing after lowering the minimum iOS version: xtool's SwiftPM packer produced a Mach-O `LC_BUILD_VERSION` with both `minos 18.0` and `sdk 18.0`, so the app was not treated as linked against the iOS 26 SDK. Patched local xtool to pass explicit linker `-platform_version` flags using deployment target `18.0` and active SDK `26.1`; rebuilt app binaries now report `minos 18.0` and `sdk 26.1`.

## 2026-05-29

- Fixed TestFlight crash `EXC_BREAKPOINT` during X WebView login credential extraction. `WKHTTPCookieStore.getAllCookies()` can return duplicate cookie names for different domains/paths, and `Dictionary(uniqueKeysWithValues:)` traps on duplicates. X and Instagram WebView login credential extraction now folds cookies into a dictionary with later values replacing earlier duplicates.
- Reply notification details now render the parent post and reply together in a single `Thread` section when both `parentTarget` and `target` are available. The parent appears first, followed by a compact reply connector and the reply post, instead of showing separate `Post` and `Parent Post` sections.
- Thread rendering now applies to mentions that are replies too, based on the presence of both `parentTarget` and `target` rather than only `.reply` notification type. Removed the `Reply` text label beside the thread connector line.
