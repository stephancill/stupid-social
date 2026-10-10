# Expo iOS simulator comparison

## Result

The Expo app builds, installs and runs on iOS under **Social Expo** (`net.stupidtech.socialexpo`). The visual and caption-editing differences found in the first comparison have been corrected. The Swift app remains the supported iOS implementation and reference; simulator visual checks do not establish full live-provider or production iOS parity.

## Run

Requires Bun, Xcode, CocoaPods and xcpretty. From `android-app/`:

```sh
bun install
bun run ios
```

The command prebuilds iOS, installs pods, builds a standalone simulator Release app, signs it for local simulator Keychain access, installs it and launches it. No Metro server is required. It defaults to the project's preferred simulator; set `IOS_SIMULATOR_UDID` to choose another simulator. Generated projects, logs, entitlements and products remain under ignored `ios/` and `.expo/` paths.

The simulator ad-hoc signature uses `com.apple.application-identifier`. An unsigned build launched but SecureStore reads failed with `errSecMissingEntitlement`; a simulator signature using the iOS `application-identifier` key was rejected at launch in this environment. The host-platform identifier allowed both launch and startup Keychain reads. This is a **simulator-only** signing workflow; device provisioning and release entitlements have not been validated. Credentials have no plaintext fallback.

Accounts and storage are separate from the Swift app. Four taps on Settings → About reveal Load preview content. This preserves real account data. Composer access is disabled in preview mode; this comparison used temporary non-secret account metadata in the otherwise empty Expo database, then removed it. No social login was imported and no story was posted.

## Visual corrections — 2026-09-18

Compared on the same 402 × 874 point simulator at the same text size. The Swift app's source is unchanged. Preview notifications and story fixtures now follow the Swift sample data, including post authors and images. Relative timestamps, image loading and animated progress can still differ between captures; this is a visual review, not a claim of pixel identity.

| Screen | Correction |
| --- | --- |
| Feed | Large Social title, neutral SF toolbar symbols, body/subheadline typography, reference vertical padding, disclosure chevrons and inset separators. |
| Story bar | Native caption-sized labels on iOS, no own-story bubble in preview, matching sample reels, and only the active pager page exposed to accessibility. |
| Notification detail | Direct SwiftUI form rows, matching 52-point standard row height, corrected first-section top margin, raw Activity copy, minimal back button, hydrated sample author/photo and native post symbols. |
| Search | Native List empty state without a gray card, corrected top margin, native navigation search capsule and SF filter control. |
| Settings | Native rows, separators and section layout; corrected disclosure/link symbols, connection-value typography and back button. The previously requested removal of the iCloud note remains intentional. |
| Instagram viewer | Matched header text metrics and SF control symbols; hidden preview like action; retained reference image framing and progress tracks. |
| Composer | SF symbols, matching empty state and caption placement, public iOS system font families, persistent editing when the software keyboard hides, and a native UIKit caption toolbar for font/color/background/Done. |
| Profiles | Native form sections, reference header padding and symbols; native scroll geometry now forwards pagination events to the shared profile screen. |

Original paired captures remain in ignored `logs/compare-*.png` and `logs/expo-ios-comparison.html`. Updated captures are `logs/parity-*.png`; the updated gallery is `logs/expo-ios-parity.html`. These are local review artifacts: the native Settings reference includes existing account labels.

## Implementation and validation boundary

- Platform-specific `.ios` modules provide SwiftUI forms, sections, rows, switches, fields and symbols. React Navigation owns the native navigation/search bars. Shared custom story screens use React Native. Android retains its Compose controls and existing text sizes.
- The caption toolbar attaches directly to the active UITextView through a narrow Expo UIKit adapter. The React Native InputAccessoryView wrapper did not attach reliably in the tested modal. Native default/rounded/serif/monospaced font families replace unsupported internal font names.
- Native toolbar display was exercised with both software and hardware keyboard states; font cycling, text/background color changes, Done and re-entering editing were exercised. Simulator HID text injection did not insert characters reliably, so hardware typing itself is not accepted by this visual pass.
- The native profile pagination callback is wired; live Instagram pagination, authenticated search results and relationship mutations still require live iOS acceptance.
- Feed, notification detail, Search, Settings and preview profile layouts were checked in light and dark appearance. The sample viewer and composer were also inspected. Account forms require a separate pass with preview mode unloaded.
- Formatting, TypeScript, lint, 42 tests (104 assertions), and standalone iOS/Android builds pass. Both updated apps were installed and launched. Android's existing live feed and saved accounts remain intact.
- No social sessions were copied into Expo iOS and no story was posted. The temporary local composer account was removed by its exact test ID; the Expo iOS account table is empty again. The Swift app's account state was untouched.
- Full account login/OAuth, session renewal, iCloud synchronization, physical-device gestures, Dynamic Type, and iOS media export/publishing remain outside this pass. The retained Android diagnostic harness's image helper is not implemented on Apple.
