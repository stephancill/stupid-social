# Android Expo validation

## Scope and decision

This document records the initial transport/authentication spike. The full Android implementation now lives in `android-app/`; see [ANDROID.md](ANDROID.md) for current setup and validation status. The original diagnostic screen is preserved as `ValidationApp.tsx`. These initial results do not establish complete feature parity.

The initial device results support proceeding with Expo **plus a small native Android module**. A JavaScript-only implementation using the standard WebView injection prop is not sufficient for dependable early Spotify request interception.

## Test environment

- Expo 57.0.23, React Native 0.86.3, React 19.2.3, Hermes.
- `react-native-webview` 13.16.1; AndroidX WebKit 1.14.0 in the local Expo module.
- Android 16 / API 36, ARM64 Google APIs emulator; WebView 133.0.6943.137.
- App ID: `net.stupidtech.socialvalidation`.
- A native debug build, not Expo Go. Device tests were performed on 2026-09-17 UTC.

## Results

| Check | Observed result | Scope of evidence |
| --- | --- | --- |
| Native Android build and launch | Pass | Debug APK installed and executed on the emulator. |
| SecureStore | Pass | Write/read succeeded; the stored marker and imported sessions remained available after actual force-stop/relaunch. No reinstall/backup guarantee is inferred. |
| Explicit Cookie and CSRF headers | Pass after fix | Controlled endpoint verified exact values even with conflicting WebView cookies. |
| Manual redirects | Pass | HTTP 302 and Location were available without following the redirect. |
| Multiple Set-Cookie values | Pass | Both controlled response values were accessible. Full provider session-renewal logic is still required. |
| HttpOnly cookies | Pass | Native CookieManager read the cookie; page JavaScript could not. |
| Standard WebView early injection | Intermittent | The inline page script observed injection missing on multiple runs and present on another. A passing single run is insufficient. |
| Native document-start injection | Pass | Injection preceded the inline page script on every observed run. Requires supported Android System WebView features. |
| JPEG generation and HTTP upload | Pass | Android generated a 1080×1920 JPEG; byte count and checksum matched the local receiver. |
| X Android login and authenticated API | Pass | Fresh Android WebView login captured selected credentials into SecureStore, then successfully fetched unread count. No notification-read mutation was used. |
| Instagram authenticated API | Pass | Imported session bootstrapped web state and fetched Direct inbox. No conversation was marked read. Fresh Android interactive login remains untested. |
| Instagram real image upload | Pass | Instagram accepted the Android-generated 1080×1920 JPEG. No configure-to-story call or publication was performed. |
| GitHub | Awaiting fresh login | Imported session redirected to login in both Python and Android. This is an expired session, not evidence of Android incompatibility. |
| Spotify | Awaiting login | No saved test session was available. Native early capture mechanism is tested, but real token capture, renewal, and friend activity are not yet established. |
| Bluesky OAuth preparation | Pass | Live handle/DID/PDS discovery, PKCE, ES256 DPoP, nonce handling, and pushed authorization ran on Android. |
| Bluesky complete session | Awaiting login | Browser callback, code exchange, token refresh, and authenticated notification read need a separate Android login. Existing iOS DPoP credentials are deliberately not copied. |

Upload acceptance does not prove story publication; no configure-to-story call is made by this harness. Pending account checks are not counted as passes.

## Findings that affect a migration

### Explicit HTTP session ownership

Expo's Android fetch implementation shares a WebView-backed cookie jar by default. After bootstrap, jar cookies overrode explicitly supplied API cookies: Instagram returned HTML in place of inbox JSON and X returned HTTP 403 on a later run. The same minimal requests worked through the Python clients.

The harness now uses `expo/fetch` with `credentials: "omit"` and explicitly supplies selected cookies. On this native implementation, that disables automatic jar use while retaining the explicit Cookie header. Both live API reads then passed. The local test seeds conflicting cookies to make this behavior reproducible. This native behavior must not be assumed to work in a browser.

A production port should keep an explicit per-provider session store and deliberately process selected Set-Cookie updates, CSRF changes, expiry, and retry behavior. This harness proves transport access, not every renewal path.

### Document-start execution

`injectedJavaScriptBeforeContentLoaded` raced with the fixture's inline script. The Kotlin Expo view uses `WebViewCompat.addDocumentStartJavaScript` and an origin-restricted message listener instead. Runtime feature checks fail visibly when unavailable. Spotify's real login still needs testing for redirects, challenges, token interception, and friend activity.

### X response schema

The live unread endpoint returned `id` and `unreadCount`. The Python reference previously read `unread_count` and silently reported zero. Its parser now reads the verified `unreadCount` field and fails if missing. The Android check validates the same shape. The public CLI summary remains `unread_count`.

## Running the harness

Requirements: Bun, Java 17, Android SDK/toolchain, and a booted emulator. Run commands from `android-app/` unless indicated otherwise. Generated Android project files and build outputs are ignored; the local module's Kotlin sources are retained.

The default entry point launches the real app. For a diagnostic development build, temporarily change the `App` import in `index.ts` from `./App` to `./ValidationApp`; restore it before building a distributable app.

Enable hardware keyboard input in the AVD (`hw.keyboard = yes` in its `config.ini`, applied after restarting the emulator) to type using the host keyboard. The validation AVD initially had this disabled. For shortcut passthrough, the emulator's extended controls expose Settings → General → Send keyboard shortcuts to → Virtual device.

```sh
bun install --frozen-lockfile
bun run check
bun run lint
bun run fixture
```

In another terminal, start Metro using IPv4 loopback so `adb reverse` can reach it. On this host, plain `--localhost` resolved to IPv6 loopback and caused a red “Unable to load script” screen.

```sh
NODE_OPTIONS=--dns-result-order=ipv4first bunx expo start --port 8081 --localhost
```

Build/install with Java 17 and the Android SDK configured:

```sh
bunx expo prebuild --platform android
bun run android
adb reverse tcp:8081 tcp:8081
adb reverse tcp:8789 tcp:8789
adb shell am start -n net.stupidtech.socialvalidation/.MainActivity
```

If a native APK already exists, install it with `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`. Native module changes require a new build; TypeScript changes use Metro.

Use the account buttons to log in on Android. For Spotify, keep native document-start mode selected. Enter an actual account handle before starting Bluesky authorization. Check results below the buttons. The Instagram upload button uploads only the generated test image; it does not publish a story.

An optional debug-only script imports existing simulator sessions directly through standard input into the Android app's private files directory:

```sh
uv run scripts/import-simulator-sessions.py --simulator <simulator-udid> --serial emulator-5554
# If the simulator is shut down, supply its already-known app data directory instead:
uv run scripts/import-simulator-sessions.py --container <app-data-directory>
adb shell am force-stop net.stupidtech.socialvalidation
adb shell am start -n net.stupidtech.socialvalidation/.MainActivity
```

The app deletes the seed file on import and stores credentials in SecureStore. No credentials are included in the result report. Importing sessions validates API transport separately from Android interactive login; it does not prove the latter.

Read the sanitized report with:

```sh
adb exec-out run-as net.stupidtech.socialvalidation cat files/validation-report.json
```

Keep local reports/screenshots under the root ignored `logs/` directory. To remove all validation sessions, uninstall the isolated app with `adb uninstall net.stupidtech.socialvalidation`.

## Remaining acceptance gates

1. Complete fresh Android logins for Instagram, GitHub, and Spotify. X login/capture/read passed; challenge/2FA and cancellation variants still need coverage for each provider.
2. Validate Spotify token capture, cookie-based renewal, and friend activity against a real session.
3. Complete Bluesky OAuth callback, token exchange, refresh, and notification read with a separate device session.
4. Validate GitHub authenticated activity using a fresh session.
5. Verify provider cookie/CSRF rotation, explicit expiration handling, and app lifecycle behavior over longer sessions.
6. Validate Instagram story publication separately if authorized. The harness intentionally does not expose publication.
7. Test at least one physical device and older supported Android/WebView combinations, including unsupported-feature handling.

Feed UI, caching, story playback/editor interactions, media permissions, Farcaster, background scheduling, notifications, accessibility, and cross-device sync were not implemented in this integration spike. Their parity remains a separate migration workstream.

## Primary references

- [Expo fetch](https://docs.expo.dev/versions/latest/sdk/expo/#expofetch-api) and the installed `expo/android/src/main/java/expo/modules/fetch/NativeRequest.kt` cookie policy.
- [React Native WebView reference](https://github.com/react-native-webview/react-native-webview/blob/master/docs/Reference.md#injectedjavascriptbeforecontentloaded).
- [Android WebViewCompat](https://developer.android.com/reference/androidx/webkit/WebViewCompat#addDocumentStartJavaScript(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E)).
- [Expo local modules](https://docs.expo.dev/modules/get-started/).
- [AT Protocol OAuth specification](https://atproto.com/specs/oauth).
