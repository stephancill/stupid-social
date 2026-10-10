# Expo replacement readiness — 2026-09-20

## Assessment

The main product surfaces and all six provider integrations are implemented in Expo. The remaining work is primarily Apple integration, upgrade compatibility, and live-device acceptance. The current Expo app is a credible candidate for becoming the shared implementation, but it is not yet a drop-in replacement for the shipping Swift iOS app.

Android has substantially more live acceptance evidence than Expo iOS. The Expo iOS comparison demonstrated native controls and visual corrections using preview content; it did not validate signed-in operation or a production upgrade. No fundamental Expo limitation was identified that prevents completing the replacement. Small Swift/Kotlin adapters remain appropriate.

This is an assessment, not a change to the supported-platform or release plan. The Swift app remains supported.

## Feature and evidence matrix

| Area | Implementation | Acceptance still needed |
| --- | --- | --- |
| Combined notifications | Six providers, local cache, deduplication, foreground/manual refresh, per-source errors and read-state handling | Authenticated Expo iOS operation, account expiry and longer lifecycle runs |
| Feed, search, settings, detail pages | Shared content with SwiftUI controls on iOS, Compose controls on Android, native navigation | iOS account forms with real sessions; large text, VoiceOver/TalkBack and physical-device coverage |
| X | Login, notifications, tweet/parent details, profiles/search, follow and post-notification controls | iOS login and transport acceptance; relationship changes on devices |
| Farcaster | Handle connection, notifications, search, profiles and cast details | End-to-end device acceptance beyond checked public responses |
| Instagram | Notifications/DM filtering, stories/media/music, likes/seen, current Relay profile/posts queries, follow controls, composer/mentions/export/publish/delete | Fresh interactive login; iOS profile pagination/media/export; full publish/delete acceptance with explicit authorization |
| Spotify | Selected-cookie login, cookie renewal, identity, friend stories, preview audio, library controls and profiles/search | Safe iOS login flow; fresh device login, playback/library and renewal acceptance |
| GitHub | Cookie login, For You reels, owned-repository star notifications, profiles/repos | Full activity and renewal acceptance with a valid session; iOS login |
| Bluesky | PKCE/PAR/DPoP OAuth, notification read/seen, search/profile/thread | Fresh callback, code exchange and token renewal on both platforms |
| Custom stories/composer | Shared layouts, native keyboard adapters, navigation/hold/swipe controls, image/video/audio, caption gestures/styles | Physical multi-touch, interruption handling, iOS photo permissions/export and exact visual/interaction comparisons |

Recent implementation notes supersede older outstanding items in `ANDROID.md` and the initial `ANDROID_VALIDATION.md` spike:

- Instagram profile/post loading was fixed with validated current Relay queries. Android live profile/grid loading passed; it is no longer the earlier unresolved REST 400/429 blocker.
- Android live X, Instagram and Spotify sessions refreshed successfully after session import. Spotify cookie-only activity and username renewal passed through the same TypeScript clients under Bun.
- Existing Android X and GitHub WebView sessions completed automatic connection successfully. This does not establish fresh login, challenge handling, or all GitHub activity flows.
- An expired native GitHub/Bluesky probe session is separate from the Android app's retained sessions. Neither constitutes acceptance of fresh OAuth/login.

## Concrete replacement gaps

### Existing accounts and Apple synchronization

The Swift app uses Keychain service `tech.stupid.StupidSocial.credentials`, synchronizable credentials on devices, UserDefaults account/preferences metadata, and iCloud key-value synchronization for Spotify/GitHub seen timestamps. Expo uses default SecureStore entries named `social.credentials.<network>` plus a new SQLite database. Its only migration reads earlier Expo `validation.<network>` keys.

Changing the bundle identifier alone would not make Expo read the native accounts, preferences or seen state. There is no Swift-to-Expo migration, synchronizable Keychain bridge, or `NSUbiquitousKeyValueStore` bridge in the Expo implementation.

Recommendation: retain the native Keychain service and iCloud seen-store behavior through a narrow iOS module, and add an idempotent import of native account metadata/preferences/seen values. Preserve the original records until migration is verified. Explicitly decide whether the short-lived notification cache is imported or safely refetched. Verify an actual in-place upgrade, including Spotify date formats and Bluesky private-key/session formats.

Evidence: `Sources/NoFeedSocialCore/Storage/KeychainCredentialStore.swift`, `AccountMetadataStore.swift`, `StorySeenSync.swift`, and `android-app/src/app/storage.ts`. The installed SecureStore implementation does not add the synchronizable attribute; its default service is different. [Expo SecureStore documentation](https://docs.expo.dev/versions/latest/sdk/securestore/) describes local secure storage, not this app's iCloud integration.

### Spotify iOS login safety

The shipping Swift login now captures `sp_dc`, cancels top-level navigation to `open.spotify.com`, uses an ephemeral cookie store, and handles WebKit process termination/retry. The Expo iOS `EarlyWebView` still loads the login continuation into the player, injects interception code and uses the default shared cookie store. Its one-second automatic cookie detector may complete first, but it does not provide the native navigation guard or process-termination recovery.

This is a confirmed implementation difference and a regression risk, not a newly reproduced Expo crash. Port the cookie-only login boundary and recovery before replacing the Swift app; the shared Spotify client already supports renewal from `sp_dc` alone.

Evidence: `Sources/NoFeedSocial/Views/SpotifyLoginWebView.swift`, `android-app/src/bridge.ios.tsx`, `android-app/src/screens/Accounts.tsx`, and `android-app/src/storage.ts`.

### Production identity, signing and iPad

Expo iOS is configured as `net.stupidtech.socialexpo`, displayed as Social Expo, with `supportsTablet: false`. Its run script uses simulator-only ad-hoc signing. The shipping app uses `tech.stupid.StupidSocial`, and its device family includes iPhone and iPad.

A replacement requires the shipping app identity, proper distribution provisioning/entitlements, continued Keychain access, the existing iCloud store identity, version/build configuration, and an iPad layout/keyboard pass. Device archive, TestFlight installation and an upgrade over the native app have not been validated. Keep the isolated comparison target available for safe parallel testing.

Evidence: `android-app/app.config.ts`, `android-app/scripts/run-ios-simulator.sh`, `stupid-app.yml`, `Info.plist`, and `App.entitlements`.

### Exact behavior and device acceptance

The September 18 iOS comparison corrected substantial layout and caption-toolbar differences but explicitly did not establish pixel identity. Current features are more complete than that original comparison. All fresh iOS provider logins, authenticated search/profile flows, renewal, photo export/publishing, accessibility, larger text and hardware typing need acceptance on the current code.

One smaller confirmed behavior difference: native Spotify story animation derives rotation/pulse timing from available track analysis; Expo uses fixed default-tempo timings in `SpinningArtwork`. This is polish rather than a blocker to basic use, but matters if identical behavior is the requirement.

No background-push implementation needs porting to match the currently shipped behavior: both implementations use foreground/manual refresh. Background scheduling appears in older planning text, but the current technical design explicitly excludes it from the MVP path. Previous macOS support was removed; it is not part of the current replacement target.

### Distribution and OTA

The local Android release-mode APK remains a development-ID/development-signed preview. Production Android signing/distribution and physical-device acceptance remain separate release tasks.

The repo has no `expo-updates` dependency, configured update URL/runtime policy or EAS release configuration. OTA is available as a future setup step, not a capability of the APK currently installed. EAS is optional for building, but an update service and native update module must be configured for OTA. [EAS Update](https://docs.expo.dev/eas-update/introduction/) supports JavaScript/assets; changes to native modules, entitlements, permissions or SDKs need a compatible new binary. [Runtime versions](https://docs.expo.dev/eas-update/runtime-versions/) tie updates to that native binary. This is a distribution improvement rather than feature parity with the Swift app.

## Recommended order and replacement gate

1. Port Spotify's safe iOS login behavior and add the Keychain/iCloud bridge plus migration.
2. Configure a production iOS target with the shipping identity, iPad support and real signing. Verify a signed in-place upgrade retains accounts/preferences/seen state.
3. Exercise each provider on iPhone and Android: fresh login, cancellation/challenges, cold launch, foreground refresh, offline cache, expired session, reconnect and disconnect. Verify the actual expiry/renewal path, not only short successful sessions.
4. Complete stories/composer acceptance: video/music playback, interruptions, physical gestures, photo permissions/save, mentions and an explicitly authorized publish/delete check. Compare real content on iOS, including larger text and iPad.
5. Run an internal TestFlight/device beta; configure Android distribution and OTA separately if desired. Replace the supported Swift implementation only after the upgrade and provider/device gates pass.

This is a focused integration/validation phase rather than another full feature port. Calendar estimates depend mainly on interactive account access and defects revealed by device testing; a percentage of implemented screens would overstate release readiness.

## Checks performed for this assessment

- Reviewed current requirements/design, implementation history, source-specific clients, storage, platform UI/WebView adapters, composer/story code and build configuration.
- Re-ran TypeScript checking and lint successfully.
- Re-ran all 75 tests: 217 assertions, zero failures.
- Exported the current iOS JavaScript/Hermes bundle successfully; output is in ignored `.expo/readiness-ios-export`, with log `logs/expo-readiness-ios-export.log`.
- Used the immediately preceding successful Android release build/install/launch as current Android build evidence.
- Did not perform a new native iOS build, fresh interactive login, physical-device test or provider mutation during this assessment. Earlier simulator screenshots and acceptance results remain historical evidence rather than a new live pass.
