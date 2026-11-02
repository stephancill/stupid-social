# App Store Submission — Handover

This doc lets another engineer/agent take over the App Store submission of **stupid
social** (iOS). It records exact identifiers, what's done, what's blocked, the tools
involved, and the precise remaining steps.

---

## 1. Object facts

| Field | Value |
|---|---|
| App name | **stupid social** |
| Bundle ID | `tech.stupid.StupidSocial` |
| App Store app Apple ID | **6764539627** |
| Team | Stephan Cilliers (User team) |
| Live version | iOS **1.0** (`READY_FOR_SALE`, version id `55dfe68e-f3fb-4289-acc3-45b41dce46f2`) |
| Target version | iOS **1.0.1** (`PREPARE_FOR_SUBMISSION`, version id `3d6e9911-91a0-4f50-87e2-2ba2741f19e1`) |
| Current build attached | **182** (build id `eecff0c5-7938-4092-a775-b024679d578e`) — VALID |
| Primary language | en-GB |
| ASC API identities | app=6764539627 · 1.0.1 en-GB localization=**8a5de7e9-e261-4a52-8f5e-fceb2ac771a4** (1.0: `3e4507c0-6ecf-4461-8e78-a1f43066f004`) |

### ASC credentials / API
- ASC API key used by automation: `~/.stupid-app/credentials/` (`asc.key-id`,
  `asc.issuer-id`, `asc.key.pem`).
- Client scripts live in the **`app-store-submission`** skill:
  `python3 scripts/asc.py`, `populate_listing.py`, `upload_screenshots.py`,
  `ratioize.py`.
- Listing copy source of truth: **`docs/app-store-copy.md`** (parseable by
  `populate_listing.py --desc-file`).

---

## 2. Current submission state in App Store Connect

### 1.0.1 (in preparation)
Created via API with build 182 attached; description, keywords, promotional text and
What's New (settable via API on a fresh version) from `docs/app-store-copy.md`; new
screenshots (table below); App Review notes rewritten for the Preview content toggle and
demo chats. Not yet added for review. Before adding it, update App Privacy for the usage
metrics (§6) in the web UI.

The sections below record the 1.0 submission.

### Done (persisted in ASC)
- **Primary category** → **Social Networking** (`SOCIAL_NETWORKING` via API on `appInfos`,
  was previously reported set but had actually not persisted — corrected via API).
- **Subtitle** → **"only the best parts of social"** (set via API on `appInfoLocalizations`
  `abe6e3fc-…`; source-of-truth copy in `docs/app-store-copy.md` updated to match).
- **Privacy Policy URL** → `https://stupidtech.net/privacy` (set via API on
  `appInfoLocalizations`, not blocked as previously assumed).
- **Content rights** → **No third-party content** (`contentRightsDeclaration =
  DOES_NOT_USE_THIRD_PARTY_CONTENT`, set via API on `/v1/apps` — was actually unset).
- **Pricing** → **Free** ($0.00) set in web UI (Pricing & Availability → Add Pricing
  → $0.00/Free across all territories → Confirm). App was missing required pricing.
- **App Privacy practices questionnaire** → **"Data Not Collected"** answered and
  **Publish App Privacy Responses** confirmed (web UI).
- **Reviewer sign-in** → **"Sign-in required" turned OFF** (app requires real
  user-supplied provider credentials, so no generic reviewer account; web UI).
- **Age rating** → questionnaire answered mildest → saved at **4+**.
- **Screenshots** uploaded & `COMPLETE`:

| Display set | Size | Files |
|---|---|---|
| `APP_IPHONE_67` (1.0.1 set `36fd406c-…`) | 1320×2868 (iPhone 16 Pro Max) | feed, chats, chat-apron, chat-photos, story, detail |
| `APP_IPAD_PRO_3GEN_129` (1.0.1 set `4780b72f-…`) | 2048×2732 (iPad Pro 12.9" 6th gen) | feed, chats, chat-apron, chat-photos, story |

For 1.0.1 the 6.1" and 6.5" sets copied from 1.0 were deleted, so smaller iPhones use the scaled 6.9" set.

- **Description / keywords / promotional text** — set (from `docs/app-store-copy.md`).
- **Support URL** = `https://stupidtech.net`, **Marketing URL** = `https://stupidtech.net`.
- **App Review Info** — contact filled; notes present.

### Final status — SUBMITTED
Version **1.0 is now "Ready for Review"** (review submission `a8ea02c2-d847-4999-a043-2f369bd8fd00`,
state `READY_FOR_REVIEW`/`READY_FOR_SUBMISSION`, platform iOS). Header reads *"This app
version has been added for review."* Version state `READY_FOR_REVIEW`, release type
`AFTER_APPROVAL` (automatically release this version after approval).

All previously-blocked items are **resolved**:
1. **App Privacy** → Privacy Policy URL set, practices questionnaire answered **"Data
   Not Collected"** and **Publish App Privacy Responses** confirmed.
2. **Reviewer "Sign-in required"** → turned **off**.
3. **Pricing** → **Free** ($0.00) price tier set (was "missing required pricing").
4. **Primary category** → **Social Networking** set via API (had not actually persisted).
5. **Content-rights declaration** → set via API (was unset).

### Remaining optional
- **What's New** — still **API state-locked** (409 `STATE_ERROR`); edit via web UI on
  Version 1.0 if release notes must change (draft in `docs/app-store-copy.md`). Not
  required for the current submission.
- Release will happen **automatically after approval** (`AFTER_APPROVAL`) — switch to
  Manual in the web UI (App Store Version Release) if you prefer to release it yourself.

---

## 3. Caveats / gotchas for the next person
- **App Store Connect web UI was flaky under automation**: content panes stopped
  rendering (React/JS errors, `date-fns-locale-de…404`, "array is needed to render
  meta tags"). Continue manually in the browser, or retry a fresh pane.
- `whatsNew` (release notes) is **API state-locked** (would return `409 STATE_ERROR`);
  it must be set in the web UI near submission. Draft text lives in
  `docs/app-store-copy.md` → "What's No".
- `subtitle`/`name`/age/privacy live on **App-Info/App-Privacy resources** that the API
  PATCH returns `409` for.
- Do not re-upload duplicate screenshots; each set caps ~10.

---

## 4. Regenerating the screenshots (optional, if you re-capture)

The screenshots come from a **demo-data mode** baked into the app (Debug-only):

- `DemoData` (`Sources/StupidSocialCore/Sources/DemoData.swift`) seeds a realistic fake
  feed/story bar (Debug-only `#if DEBUG`; never compiled into release).
- Enable: launch with `-demoData` (`xcrun simctl launch <udid> tech.stupid.StupidSocial -demoData`),
  or Settings → tap the About heading four times → Demo Data → **Preview content** toggle.
  Demo mode works in release builds and persists, so capture on a temporary simulator.
- Chats: swipe right from the feed. On the iPad simulator the pager only takes a slow drag
  (`stupidsim swipe … --steps 20 --step-milliseconds 15`), and after backing out of a
  notification detail its page dots disappeared and it stopped paging until relaunch
  (observed 2026-11-01).
- Capturing: on a temporary simulator, launch with demo and screenshot with
  `xcrun simctl io <udid> screenshot` into `screenshots/<set>/raw/{iphone,ipad}/`, overriding the
  status bar time with the real time so it agrees with the chats' message times. On iPhone, tap
  rows by their accessibility labels (`stupidsim ui-tree`); the app reopens on the last pager
  page. On the iPad simulator the tree came back empty and taps didn't register, but a 2-point
  `stupidsim swipe` in place acts as a tap (observed 2026-11-01).
- Framing: `bun scripts/appstore-screenshots.ts <set>` turns the raw captures into the
  stupid-style set (white, plain lowercase headline, black mouse-drawn doodles via rough.js, like
  the stupid app icons) at native size in `screenshots/<set>/{iphone,ipad}/`; slide headlines live
  in the script and in `docs/app-store-copy.md`. Upload with `upload_screenshots.py <loc> <set> <file>`.
- Device → set: iPhone 16 Pro Max (1320×2868) → `APP_IPHONE_67`; iPad Pro 12.9" 6th gen
  (2048×2732, no resize needed) → `APP_IPAD_PRO_3GEN_129`.
- Alternated captures for avatar/no feed (jules/maya/torres use `randomuser.me`),
  stories IG/Spotify/GitHub.

---

## 5. Release method
Version 1.0 **release type = Manual** (AFTER_APPROVAL era). Decide whether to Keep
Manual release (you hit "Release") or set Auto.

---

## 6. Privacy expectations
App stores: HTTPS-only, user credentials in iCloud Keychain. Export compliance:
`ITSAppUsesNonExemptEncryption = false` in `Info.plist` (no non-exempt encryption).

The app sends anonymous usage metrics (see `docs/PLAN.md` § Usage Metrics). Before
submitting a build with them, change the App Privacy answers from "Data Not Collected"
to: **Diagnostics** (Crash Data, Performance Data, Other Diagnostic Data) and **Usage
Data** (Product Interaction), all *not linked to the user* and *not used for tracking*,
for App Functionality and Analytics. Then republish the responses, and check that the
privacy policy at `https://stupidtech.net/privacy` covers it.

---

## 7. Whoever picks this up
**Current state: Version 1.0 has been submitted and is "Ready for Review".** The tasks
below are already completed:
1. Privacy policy URL live (`https://stupidtech.net/privacy`) and set in ASC. Done.
2. App Privacy practices questionnaire = **"Data Not Collected"**, published. Done.
3. Reviewer **Sign-in required** turned **off**. Done.
4. **Add for Review** clicked — app is **Ready for Review**. Done.

If any further change is needed:
- **Change release notes (What's New)**: edit via the **App Store** pane of Version 1.0
  in the web UI (API is state-locked). Draft text lives in `docs/app-store-copy.md`.
- **Change expansion method**: Version 1.0 → "App Store Version Release" → choose
  Manual vs. Automatic. Currently `AFTER_APPROVAL` (auto-release after approval).

Referenced by: `docs/app-store-copy.md`, this file, and the `app-store-submission` skill.