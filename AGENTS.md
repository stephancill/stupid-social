# Project Conventions

## Project Structure

```
Sources/
  NoFeedSocial/                     # App UI layer (SwiftUI views)
    AppContainer.swift              # App-layer composition root
    AppDelegate.swift               # APNs token, notification taps, inline replies and foreground presentation
    NoFeedSocialApp.swift           # iOS @main entry point
    Views/
      ContentView.swift             # Root view, container wiring
      FeedView.swift                # Main list + StoriesBar + story viewer triggers
      HomePager.swift               # UIPageViewController pager: Chats to the left of the feed
      ChatsView.swift               # Chats list across Apron rooms, Spotify chats and Instagram threads
      SearchView.swift              # Cross-network profile search
      SearchBar.swift               # Shared search field modifier (Search, Chats)
      CompactListRow.swift          # Shared row insets for the feed and Chats lists
      StoryComposerView.swift       # Full-screen story composer scaffold
      NotificationDetailView.swift  # Standard form-based notification detail
      ProfileDetailView.swift       # Actor profile detail
      NetworkBadgeIcon.swift        # Shared social network icon badge
      UnifiedStoryViewer.swift      # Full-screen unified story viewer
      SpotifyPulseRing.swift        # Shared phase-driven pulse ring
      InstagramConnectionView.swift # Instagram credential setup
      InstagramLoginWebView.swift   # Instagram WebView login
      SpotifyConnectionView.swift   # Spotify credential setup
      SpotifyLoginWebView.swift     # Spotify WebView login
      GitHubConnectionView.swift    # GitHub credential setup
      GitHubLoginWebView.swift      # GitHub WebView login
      BlueskyConnectionView.swift   # Bluesky OAuth setup
      XConnectionView.swift         # X credential setup
      XLoginWebView.swift           # X WebView login
      FarcasterConnectionView.swift # Farcaster credential setup
      FarcasterExternalClientView.swift # Farcaster external client picker
      DebugConnectionView.swift     # Debug notifications toggle
      ApronServersView.swift        # Apron server list, add form, and server detail
      ApronLinkView.swift           # Confirmation sheet for opened Apron links
      ChatView.swift                # Shared chat screen: title pill, connection lifecycle; NetworkChatView for Spotify
      ChatUIKitView.swift           # Shared chat UIKit view controller: message list, floating composer, attachments
      ChatAudioPreview.swift        # Inline audio preview player and track card for chat messages
      ChatImageViewer.swift         # Full-screen chat image viewer: zoom, swipe to dismiss, save to Photos
      ApronChatView.swift           # Apron chat: the shared chat plus members and profiles
      ApronMembersView.swift        # Apron room member list, opened from the chat title
      ApronProfileView.swift        # Apron user profile and shared avatar with presence dot
      SettingsView.swift            # Settings with connection links
      TelegramConnectionView.swift  # Telegram sign-in: phone, code, 2FA password
  NoFeedSocialPush/                 # Shared with the notification extension: Web Push decryption, push store, notification content
    WebPushDecryptor.swift
    ApronPushStore.swift
    ApronPushNotification.swift
  NoFeedSocialNotificationService/  # Notification Service Extension: decrypts Apron pushes
    NotificationService.swift
  NoFeedSocialCore/                 # Shared core (models, services, sources)
    Models/
      AppModels.swift               # All public model types
      CachedNotification.swift      # SwiftData cache model
    Services/
      FeedService.swift             # Central feed orchestration
      ApronService.swift            # Apron server list, tokens, and signed-in sessions
      ApronLiveFeed.swift           # Foreground WebSocket per Apron server for realtime feed items
      ApronPushService.swift        # Apron push registration through the push.stupidtech.net relay
      ApronRoomNotifications.swift  # Per-room notification levels mapped to mute and wake scopes
      TelegramPushService.swift     # Telegram APNs registration (token type 1) after sign-in, at launch, on token change
    Sources/                        # Network clients + notification sources
      NotificationSource.swift      # Protocol definition
      InstagramClient.swift / InstagramSession.swift / Instagram*Models.swift / Instagram*Parser.swift / InstagramNotificationSource.swift
      InstagramProfile.swift       # Current web profile/posts queries and runtime configuration
      InstagramHomepage.swift      # Authenticated viewer and preloaded stories tray parsing
      InstagramDirect.swift        # Direct inbox/thread/send/read via web GraphQL, Chats list rows
      GitHubClient.swift
      GitHubActivitySource.swift
      GitHubNotificationSource.swift
      SpotifyClient.swift / SpotifyActivitySource.swift
      SpotifyMessagesParser.swift / SpotifyMessagesSource.swift  # Spotify Messages (speechless) chats in the feed
      XClient.swift / XNotificationSource.swift
      FarcasterClient.swift / FarcasterNotificationSource.swift
      BlueskyClient.swift / BlueskyNotificationSource.swift
      DebugNotificationsClient.swift / DebugNotificationSource.swift
      ApronModels.swift / ApronClient.swift / ApronNotificationSource.swift  # Apron Chat Protocol WebSocket client
      ApronLink.swift               # Apron links (link.apron.chat and apron:): parse, validate, write
      TelegramTL.swift              # TL schema parsing and generic encoder/decoder
      TelegramCrypto.swift          # BigUInt, AES-IGE, RSA_PAD, factorization, SRP
      TelegramMTProto.swift         # MTProto transport, auth key exchange, encrypted session actor
      TelegramClient.swift          # Telegram account: DCs, sign-in, dialogs, history, send, read, files, push
      TelegramMedia.swift           # tgfile: URLs and their URLProtocol, media/avatar/reaction parsing
    Resources/
      TelegramSchema.tl             # Telegram TL schema (scripts/telegram-schema.py); TelegramAPI.json is gitignored
    Storage/
      AccountMetadataStore.swift
      CookieHeaderParser.swift
      KeychainCredentialStore.swift
      NotificationCacheStore.swift
      SpotifyActivitySeenStore.swift
      GitHubActivitySeenStore.swift
      StorySeenSync.swift             # iCloud KVS seen-state sync (Spotify/GitHub)
      ApronReadStore.swift            # Apron read cursors (server truth or iCloud KVS)
      ApronServerSync.swift           # Apron server list across devices (iCloud KVS, with removals)
      ApronMessageCache.swift         # Recent Apron messages per room for instant chat open
      ApronDraftStore.swift           # Unsent Apron composer text per room
      ChatSnapshotCache.swift         # Last messages and metadata per Spotify/Instagram chat for instant open
    ViewModels/
      FeedViewModel.swift
      ProfileSearchViewModel.swift
      StoryBarViewModel.swift
      SettingsViewModel.swift
      ApronServersViewModel.swift
      ChatViewModel.swift            # Shared chat models (ChatMessage, ChatUser, ChatEmbed) and base view model
      ChatListViewModel.swift        # Chats list: ChatSummary, merged from Apron and Spotify
      ApronChatViewModel.swift
      ApronLinkViewModel.swift       # What an opened Apron link offers: add server, sign in, join, open
      SpotifyChatViewModel.swift     # Spotify Messages chat: history, polling, send, seen, track metadata
      InstagramChatViewModel.swift   # Instagram Direct chat: history, polling, send, replies, read receipt
      TelegramChatViewModel.swift    # Telegram chat: history, pushed updates, send, replies, read cursor
      TelegramConnectionViewModel.swift # Telegram sign-in steps
```

Outside `Sources/`: `NotificationService/` holds the extension's Info.plist and entitlements, and `workers/push-relay/` the Apron push relay Worker (`bun run push-relay:test`, `bun run push-relay:deploy`).

- Keep `## Project Structure` in sync when files are added, moved, or renamed.

## Required Context

- Always read `docs/PLAN.md` before making product, architecture, or implementation decisions.
- Treat `docs/PLAN.md` as the source of truth for current requirements.
- Always read `docs/TECHNICAL_DESIGN.md` before making architecture or implementation decisions once it exists.
- Treat `docs/TECHNICAL_DESIGN.md` as the source of truth for planned implementation details.
- Record implementation decisions, tradeoffs, endpoint discoveries, and notable deviations in `docs/IMPLEMENTATION.md` as work progresses.
- Keep `docs/IMPLEMENTATION.md` factual and chronological enough that another agent can resume work without re-discovering context.

## Product Direction

- This is a universal macOS and iOS app built and released with the `stupid-app` CLI.
- The MVP is notifications-only for X and Farcaster.
- The app should help users avoid algorithmic feeds while still seeing direct social notifications.
- Posting, Bluesky, multiple accounts, and backend services are future scope unless `docs/PLAN.md` changes.

## Apple App Conventions

- Prefer SwiftUI for shared macOS and iOS UI.
- Keep UI very simple, restrained, and aligned with Apple's Human Interface Guidelines.
- Prefer built-in SwiftUI and platform UI primitives over custom controls, custom styling, or bespoke interaction patterns.
- Keep platform-specific code isolated behind small adapters or conditional compilation.
- Prefer native Apple APIs over extra dependencies unless the dependency clearly reduces risk or complexity.
- Preserve a universal app structure that can run on both macOS and iOS.
- Verify `stupid-app` build/run behavior after meaningful project changes when feasible.

## State And Storage

- Store credentials in iCloud Keychain.
- Never persist raw X cookie headers after extracting the required selected cookie values.
- Never log credentials, cookie headers, tokens, or derived auth values.
- Keep notification item cache local-only for the MVP.
- Keep the normalized notification schema minimal unless `docs/PLAN.md` is updated.

## Network Integration

- Always diagnose network behavior and validate the fix in the dependency-free Python client first, before implementing or changing the native Swift client. The probes (`scripts/x-web-client.py`, `scripts/instagram-web-client.py`, `scripts/github-web-client.py`, `scripts/spotify-web-client.py`, `scripts/bluesky-web-client.py`, `scripts/apron-web-client.py`, `scripts/telegram-client.py`) are the source of truth for endpoint behavior, auth/session freshness, redirects, and response shape. Reproduce the issue live with the probe (using simulator credentials where applicable), add or update a probe command that demonstrates the diagnosis, then port the validated behavior into Swift. Do not guess endpoint/auth behavior from Swift alone.
- Implement X as a native Swift client using `docs/CLI_DOCS.md` and the patched `twitter-cli` behavior as references only.
- Do not shell out to `twitter-cli` for the production app path.
- X background polling must use count-only behavior to avoid marking notifications read server-side.
- X full notification fetch must be explicit manual refresh only.
- Use Hypersnap at `https://haatz.quilibrium.com` for Farcaster reads.
- Resolve Farcaster usernames with `GET /v2/farcaster/user/by-username`.
- Fetch Farcaster notifications with `GET /v2/farcaster/notifications`.
- For Instagram AND X mutations (follow/unfollow, notify toggles, likes, seen, posting), first validate the new web endpoint in the dependency-free probe scripts (`scripts/instagram-web-client.py` / `scripts/x-web-client.py`) against live simulator credentials BEFORE implementing the mutation in the native Swift client. Add the probe command, verify it against a real account (restoring any changed state), then port the validated request shape (endpoint, headers, root field name, variables) into the client. This mirrors the existing like-story/seen/posting flow: the Python probe is the source of truth for endpoint behavior.

## Build And Install

- When the user says "install" without specifying a target, default to `stupid-app run --simulator`.
- Only target a physical device over USB when the user explicitly says "install to iphone" or similar.
- After making source or resource changes, run `stupid-app build` for them to take effect.
- After making changes, install to the simulator with `stupid-app run --simulator` unless the user explicitly asks not to install or asks for a different target.
- When asked to bump the build number, increment `CFBundleVersion` in `Info.plist` by 1.

## Engineering Style

- Prefer small, direct changes over broad abstractions.
- Keep adapters narrow and source-specific normalization explicit.
- Avoid backward compatibility code unless required by persisted data, shipped behavior, or an explicit requirement.
- Add comments only when code is not self-explanatory.
- Keep secrets out of logs, diagnostics, fixtures, screenshots, and documentation examples.
- When adding new SwiftData model properties, always provide a default value at the property declaration to avoid migration failures with existing installed caches.

## Formatting

- Run `swiftformat Sources/ Tests/` to auto-correct formatting violations.
- Run `stupid-app build` after formatting to verify the build still passes.

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
