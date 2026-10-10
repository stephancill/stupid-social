# Android app

The Expo app is in `android-app/`. The Swift app remains the iOS implementation. See `PLAN.md` for scope and `ANDROID_VALIDATION.md` for the preceding transport/authentication validation.

An isolated iOS simulator comparison build is also available with `bun run ios`. See [IOS_EXPO_COMPARISON.md](IOS_EXPO_COMPARISON.md) for setup, observed differences, and validation limits.

## Launcher artwork

`app.config.ts` selects Android-specific legacy and adaptive icons. The adaptive foreground also supplies the monochrome layer for themed launchers. Generate them from the existing artwork with ImageMagick, from `android-app/`:

```bash
magick assets/icon.png -fuzz 1% -trim +repage -resize 610x610 -gravity center -background white -extent 1024x1024 PNG24:assets/android-icon.png
magick assets/icon.png -colorspace Gray -negate -alpha copy -channel RGB -evaluate set 0 +channel -trim +repage -resize 424x424 -gravity center -background none -extent 1024x1024 PNG32:assets/android-icon-foreground.png
bunx expo prebuild --platform android --no-install --no-clean
```

Run Expo prebuild before rebuilding after icon changes. `--no-clean` updates the existing native project while preserving its build cache. The foreground retains room for Android's launcher masks and animation; do not use the fully opaque legacy artwork as the adaptive foreground.

The mark widths are 610 pixels for legacy and 424 pixels for adaptive/themed icons on their 1024-pixel canvases. This increases the average horizontal/vertical white margin by another 30% from the preceding 718/492-pixel artwork (about 69% above the original 800/544-pixel artwork), accounting for the adaptive icon's central visible viewport. Preserve the mark's proportions and centered placement.

Pixel Launcher adds a colored ring to suggested apps in empty dock slots. If Social's icon has a turquoise border and its accessibility label starts with `Predicted app`, hold the icon and choose **Pin Prediction**. This pins it in place and removes the launcher decoration. The packaged artwork is grayscale with a white adaptive background; changing its assets does not control the prediction ring. See [Pixel's suggested-app documentation](https://support.google.com/pixelphone/answer/2781850?hl=en).

## Local development

Requirements: Bun, Java 17, Android SDK/API 36, an ARM64 Android emulator or device, and sufficient disk space for Gradle/NDK caches.

```sh
cd android-app
bun install
export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
bunx expo prebuild --platform android
bun run start
```

In another terminal:

```sh
cd android-app
bun run android
```

For USB/emulator development, reverse port 8081 with ADB. `bun run start` sets IPv4-first resolution so the localhost Metro listener is reachable through that reverse connection.

The custom native modules require a development build; Expo Go is insufficient. Native dependency or module changes require rebuilding the APK. JavaScript-only edits use Metro during development.

The provider clients also run directly under Bun through the [shared TypeScript probes](CLIENTS.md). `src/expoRuntime.ts` supplies the app's native services; the probe runtime supplies in-memory credentials and Bun/Node services. Changes to request construction and parsing therefore apply to both without maintaining a second API implementation.

## Application IDs and credentials

The default development ID is `net.stupidtech.socialvalidation`, retaining accounts from the successful Android validation. On first launch, selected secure credentials migrate from the validation keys to production code's secure-storage keys. Raw cookies are not copied into SQLite or logs.

`APP_VARIANT=production bunx expo prebuild --platform android --clean` selects `net.stupidtech.stupidsocial`. This is a separate installation with separate accounts. Production distribution requires a release signing key; the generated local Gradle configuration uses a development key until release signing is configured.

Android sessions, settings, notification cache, and story progress stay on that device. They do not synchronize with iCloud. Android backup is disabled.

Embedded X, Instagram, GitHub and Spotify sign-in completes automatically when the required session cookies arrive and account validation succeeds. There is no Continue step. Failed validation leaves the browser open with Retry connection; the app also detects a changed session if the user finishes or repeats sign-in. Cookie checks pause in the background and stop when the login page is dismissed. Farcaster handle entry and Bluesky OAuth retain their separate flows.

## Standalone local APK

After prebuilding, build an ARM64 preview that runs without Metro:

```sh
cd android-app
NODE_OPTIONS=--dns-result-order=ipv4first ./android/gradlew -p android :app:assembleRelease -PreactNativeArchitectures=arm64-v8a
```

The output is `android/app/build/outputs/apk/release/app-release.apk`. The verified local artifact is also copied to `dist/stupid-social-preview.apk` (ignored by Git). This approximately 44 MB preview uses the development application ID and local development signing key. It is not a Play Store release.

## Implemented surfaces

| Network | Android functionality |
| --- | --- |
| X | Web login, notifications, grouped actors/targets, search, profiles, post details, following and post-notification controls |
| Farcaster | Username connection, Hypersnap notifications and grouped reactions/follows, search, profiles and cast details |
| Instagram | Web login, activity, unread messages and media-share filtering, stories, video/music, likes/seen, search, profiles and paginated posts, follow/unfollow, photo-story composer, mentions, save/publish/delete |
| Bluesky | Independent browser OAuth using PKCE/PAR/DPoP, notifications and mark-seen, search, profiles and post threads |
| GitHub | Web login, For You story reels, owned-repository star notifications, profile/repository details, exact-username lookup |
| Spotify | Web login capture, cookie-based token renewal, friend listening stories, previews, library controls, search and profiles |

The combined feed loads its SQLite cache first and refreshes on foreground activation or pull-to-refresh. A failed source does not discard other sources' results. X and Bluesky mark their notifications seen after caching; Instagram conversations only become read when opened.

Standard Android screens use native Jetpack Compose Material rows, section headings/dividers, switches, buttons, text fields, and filter menus via Expo UI, with React Navigation's native app bars. Material colors follow the device theme. Notification rows retain the iOS content hierarchy, network badges, avatars, and previews. The feed toolbar provides Search and Settings; the combined feed has no network/category filter menu. Swipe vertically on the custom story bar to switch between All Stories and individual providers.

Stories support left/right taps, holding to pause, horizontal swipes between people, downward swipe to dismiss, Left/Right keys, Shift+Left/Right between people, and Space to pause. Like, mute, and close controls overlay the media. The Instagram composer matches the iOS full-screen canvas and floating toolbar: choose an aspect-fit photo, add/edit text directly, cycle background colors/gradients, and save or post. While editing text, use the bottom background/font/color controls and type `@` for Instagram mention suggestions. Tap a caption to edit, drag to reposition, pinch to resize, or drag onto the bottom trash target to remove it. An independent composition renders a clean 1080×1920 JPEG; publishing requires the explicit Post confirmation. Android retains its native font and system icon rendering.

Search, Settings, provider connection pages, profiles, and notification details preserve the iOS section order, labels, content hierarchy, and media presentation while using Android controls and their native spacing. The existing SwiftUI app remains the unchanged iOS presentation. Search has a keyboard-aware bottom field and a multiple-network filter menu. Profile posts open an in-app image/video carousel. Android Settings omits the iCloud comparison note.

Android form sections follow the Material Settings treatment: rounded tonal groups, inset colored section headings, and native rows/switches. Connection statuses sit below their network names. Section spacing replaces the full-width form dividers; notification feed separators retain their existing layout. Colors follow the system Material palette in light and dark appearance.

Settings → About reveals preview controls after four taps. Preview content keeps real cache/accounts intact and disables social actions. `ValidationApp.tsx` retains the original diagnostic harness but is not the application entry point.

## Checks

```sh
cd android-app
bun run format
bun run check
bun run lint
bun run test
bunx expo export --platform android
```

Parser tests cover X cursor and aggregation behavior, Instagram unread-message and story normalization, GitHub rollups and owned-repository stars, Farcaster aliases/grouping, selected-cookie rotation, Spotify token-code generation, and cache retention.

## Validation status

Implementation and live acceptance are separate. The standalone release APK was built, installed, and launched on the Android 16/API 36 ARM64 emulator. Fresh X login, live X/Instagram feed refresh, cross-network search, X profile and notification detail, Instagram story image/video playback, keyboard pause/navigation, local story JPEG export, preview load/unload, and cached feed after an offline cold launch passed. Public Farcaster user/search/notification responses were checked against its client mappings. The native Material UI was verified for feed and person rows, native navigation/filter menus, account switches (restored after testing), search typing/results, live X reply/parent details, profile sections, light/dark transitions, and preview stories. The full-screen composer passed photo fitting, inline caption editing/styles, hardware/soft keyboard layout, live mention insertion, drag placement/deletion, light/dark appearance, clean 1080×1920 photo/gradient exports, and canceling Post confirmation. Pinch scale limits have regression coverage; physical multi-touch acceptance remains pending. TypeScript, lint, formatting, and all 42 parser/cache/presentation/composer tests (104 assertions) pass.

Instagram bootstrap, Direct inbox, and JPEG upload were validated; no story was publicly posted during testing. Full Spotify/GitHub fresh login and Bluesky token exchange/renewal still need fresh interactive sessions. Spotify's emulator browser behavior remains an open live-validation issue. X notification details now use the verified TweetResultByRestId endpoint; a live Android reply/parent thread loaded successfully after replacing the legacy endpoint that returned HTTP 404. Instagram profile/posts HTTP 400 responses remain unresolved, and the live Instagram grid/media path has not passed acceptance. Physical-device coverage and Play Store release signing/review are not yet complete.
