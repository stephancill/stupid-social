# Project Conventions

## Project Structure

```
Sources/
  NoFeedSocial/                     # App UI layer (SwiftUI views)
    NoFeedSocialApp.swift           # iOS @main entry point
    Views/
      ContentView.swift             # Root view, dependency wiring
      FeedView.swift                # Main list + StoriesBar + story viewer triggers
      NotificationDetailView.swift  # Standard form-based notification detail
      ProfileDetailView.swift       # Actor profile detail
      InstagramStoryViewer.swift    # Full-screen Instagram story viewer
      SpotifyStoryViewer.swift      # Full-screen Spotify listening viewer
      InstagramConnectionView.swift # Instagram credential setup
      InstagramLoginWebView.swift   # Instagram WebView login
      SpotifyConnectionView.swift   # Spotify credential setup
      SpotifyLoginWebView.swift     # Spotify WebView login
      XConnectionView.swift         # X credential setup
      XLoginWebView.swift           # X WebView login
      FarcasterConnectionView.swift # Farcaster credential setup
      DebugConnectionView.swift     # Debug notifications toggle
      SettingsView.swift            # Settings with connection links
  NoFeedSocialCore/                 # Shared core (models, services, sources)
    Models/
      AppModels.swift               # All public model types
      CachedNotification.swift      # SwiftData cache model
    Services/
      FeedService.swift             # Central feed orchestration
    Sources/                        # Network clients + notification sources
      NotificationSource.swift      # Protocol definition
      InstagramClient.swift / InstagramNotificationSource.swift
      SpotifyClient.swift / SpotifyActivitySource.swift
      XClient.swift / XNotificationSource.swift
      FarcasterClient.swift / FarcasterNotificationSource.swift
      DebugNotificationsClient.swift / DebugNotificationSource.swift
    Storage/
      AccountMetadataStore.swift
      CookieHeaderParser.swift
      KeychainCredentialStore.swift
      NotificationCacheStore.swift
      ReadWatermarkStore.swift
    ViewModels/
      FeedViewModel.swift
      SettingsViewModel.swift
  NoFeedSocialMac/                  # macOS app entry point
    NoFeedSocialMacApp.swift
```

- Keep `## Project Structure` in sync when files are added, moved, or renamed.

## Required Context

- Always read `docs/PLAN.md` before making product, architecture, or implementation decisions.
- Treat `docs/PLAN.md` as the source of truth for current requirements.
- Always read `docs/TECHNICAL_DESIGN.md` before making architecture or implementation decisions once it exists.
- Treat `docs/TECHNICAL_DESIGN.md` as the source of truth for planned implementation details.
- Record implementation decisions, tradeoffs, endpoint discoveries, and notable deviations in `docs/IMPLEMENTATION.md` as work progresses.
- Keep `docs/IMPLEMENTATION.md` factual and chronological enough that another agent can resume work without re-discovering context.

## Product Direction

- This is a universal macOS and iOS app built with xtool.
- The MVP is notifications-only for X and Farcaster.
- The app should help users avoid algorithmic feeds while still seeing direct social notifications.
- Posting, Bluesky, multiple accounts, and backend services are future scope unless `docs/PLAN.md` changes.

## Apple App Conventions

- Prefer SwiftUI for shared macOS and iOS UI.
- Keep UI very simple, restrained, and aligned with Apple's Human Interface Guidelines.
- Prefer built-in SwiftUI and platform UI primitives over custom controls, custom styling, or bespoke interaction patterns.
- Keep platform-specific code isolated behind small adapters or conditional compilation.
- Prefer native Apple APIs over extra dependencies unless the dependency clearly reduces risk or complexity.
- Preserve a universal app structure that can run on both macOS and iOS through xtool.
- Verify xtool build/run behavior after meaningful project changes when feasible.

## State And Storage

- Store credentials in iCloud Keychain.
- Never persist raw X cookie headers after extracting the required selected cookie values.
- Never log credentials, cookie headers, tokens, or derived auth values.
- Sync read watermarks with `NSUbiquitousKeyValueStore`.
- Keep notification item cache local-only for the MVP.
- Keep the normalized notification schema minimal unless `docs/PLAN.md` is updated.

## Network Integration

- Implement X as a native Swift client using `docs/CLI_DOCS.md` and the patched `twitter-cli` behavior as references only.
- Do not shell out to `twitter-cli` for the production app path.
- X background polling must use count-only behavior to avoid marking notifications read server-side.
- X full notification fetch must be explicit manual refresh only.
- Use Hypersnap at `https://haatz.quilibrium.com` for Farcaster reads.
- Resolve Farcaster usernames with `GET /v2/farcaster/user/by-username`.
- Fetch Farcaster notifications with `GET /v2/farcaster/notifications`.

## Read State

- Read state is explicit only.
- Opening the app, refreshing the feed, or opening notification detail must not mark notifications read.
- Only explicit user actions such as `Mark all as read` can advance a read watermark.
- Derive unread state from per-network/account timestamp watermarks.

## Build And Install

- When the user says "install" without specifying a target, default to `xtool dev run --simulator --no-attach --no-logs --launch-timeout 420`.
- Only target a physical device over USB when the user explicitly says "install to iphone" or similar.
- After making source or resource changes, run `xtool dev build` for them to take effect in the Xcode workspace. `xtool dev run` also performs a build, but a standalone build is faster for verification.
- When asked to bump the build number, increment `CFBundleVersion` in `Info.plist` by 1, then run `xtool dev build` to regenerate the Xcode workspace.

## Engineering Style

- Prefer small, direct changes over broad abstractions.
- Keep adapters narrow and source-specific normalization explicit.
- Avoid backward compatibility code unless required by persisted data, shipped behavior, or an explicit requirement.
- Add comments only when code is not self-explanatory.
- Keep secrets out of logs, diagnostics, fixtures, screenshots, and documentation examples.
- When adding new SwiftData model properties, always provide a default value at the property declaration to avoid migration failures with existing installed caches.

## Formatting

- Run `swiftformat Sources/ Tests/` to auto-correct formatting violations.
- Run `xtool dev build` after formatting to verify the build still passes.

## Debug Servers And State

- Debug server scripts should persist generated state to disk so IDs and timestamps survive restarts and are not reissued with fresh timestamps.
- Debug server state files and runtime logs go under `logs/` and must never be committed.

## Documentation

- Update `docs/PLAN.md` when requirements change.
- Update `docs/IMPLEMENTATION.md` when implementation choices are made or changed.
- Keep API endpoint assumptions, response quirks, and side effects documented.
- If behavior differs from the plan, record the reason and whether it is temporary or intentional.

## Reading Simulator Credentials For API Testing

The `sim-prefs` skill provides a script to read app preferences from a booted simulator without launching the app.

```bash
# Read Instagram credentials for curl testing
python3 ~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py --raw-key "tech.stupid.StupidSocial.credentials.instagram.localFallback"
```

Typical output:
```json
{
  "csrfToken": "MZ5Rlef2Xa4gi_VJ3W_7Cm",
  "mid": "af-i4QAEAAE3WI_GYFY1GbhwnpHI",
  "sessionId": "70150151668%3AbRdSZLSgsYuNCb%3A28%3AAYjenJEIf-Oj50Qahe3jXKl80ttRA0Q60VkhkIiMgw",
  "dsUserId": "70150151668",
  "rur": "FRC,70150151668,1809898590:01fe6d5b21ac89e9cf47fa...",
  "igDid": "2BD14C47-5D7C-45A6-9AAD-B6919359748C"
}
```

Use the extracted values directly in curl:

```bash
SESSIONID='...' CSRF='...' USERID='...' MID='...'
# Verify session is valid
curl -s -H "Cookie: ds_user_id=$USERID; csrftoken=$CSRF; sessionid=$SESSIONID; mid=$MID" \
  -H "X-CSRFToken: $CSRF" \
  -H "X-IG-App-ID: 567067343352427" \
  -H "User-Agent: Instagram 416.0.0.47.66 Android (35/35; 480dpi; 1080x2400; samsung; SM-S938U; qcom; en_US; 718621835)" \
  "https://i.instagram.com/api/v1/accounts/current_user/"

# Fetch stories tray
curl -s -X POST \
  -H "Cookie: ds_user_id=$USERID; csrftoken=$CSRF; sessionid=$SESSIONID; mid=$MID" \
  -H "X-CSRFToken: $CSRF" \
  -H "X-IG-App-ID: 567067343352427" \
  -H "User-Agent: Instagram 416.0.0.47.66 Android ..." \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "_csrftoken=$CSRF" \
  "https://i.instagram.com/api/v1/feed/reels_tray/"

# Check account status
python3 ~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py --accounts
```

Other useful flags: `--credentials` (field presence only), `--keychain` (raw keychain dump), `--bundle-id <id>` for non-default apps.

The simulator must be booted (`xcrun simctl list devices booted`). The app must have been run at least once to populate credentials. Credentials are stored in iCloud Keychain with UserDefaults fallback; the fallback key is `tech.stupid.StupidSocial.credentials.<network>.localFallback`.
