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
| Target version | iOS App Version **1.0** (marketing version string `1.0`) |
| Current build attached | **117** (build id `e793a6a5-cbcc-4b54-9f4a-5ef3c5ff59f6`) — VALID |
| Primary language | en-GB |
| ASC API identities | app=6764539627 · iOS version=**55dfe68e-f3fb-4289-acc3-45b41dce46f2** · en-GB localization=**3e4507c0-6ecf-4461-8e78-a1f43066f004** |

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
| `APP_IPHONE_61` (set `28f8f642-…`) | 1170×2532 / 1206×2622 | feed, detail, settings, story-instagram, story-spotify, story-github |
| `APP_IPHONE_65` (set `6755677d-…`) | 1242×2688 | feed |
| `APP_IPAD_PRO_3GEN_129` (set `93999b53-…`) | 2048×2732 | feed, detail |

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

- `DemoData` (`Sources/NoFeedSocialCore/Sources/DemoData.swift`) seeds a realistic fake
  feed/story bar (Debug-only `#if DEBUG`; never compiled into release).
- Enable: launch with `-demoData` OR env `DEMO_DATA=1`, OR Settings → enable the hidden
  Debug toggle (4-tap "About") → auto-loads; then "Load preview / Redact names /
  Unload" in the Demo Data section.
- Capturing: boot a simulator, install the Debug build, launch with demo, screenshot with
  `xcrun simctl io <udid> screenshot`, then caption with
  `python3 ~/.config/opencode/skills/app-store-submission/scripts/ratioize.py <raw.png>`
  (native canvas, caption band) and upload with
  `upload_screenshots.py <loc> <set> <file>`.
- Watch which devices map to which set: 6.1"=`APP_IPHONE_61` (1206×2622), 6.5"=
  `APP_IPHONE_65` (1242×2688), iPad Pro 13"→resize to 2048×2732 → `APP_IPAD_PRO_3GEN_129`.
- Alternated captures for avatar/no feed (jules/maya/torres use `randomuser.me`),
  stories IG/Spotify/GitHub.

---

## 5. Release method
Version 1.0 **release type = Manual** (AFTER_APPROVAL era). Decide whether to Keep
Manual release (you hit "Release") or set Auto.

---

## 6. Privacy expectations
App stores: HTTPS-only, user credentials in iCloud Keychain, no analytics currently
shipped. Export compliance: `ITSAppUsesNonExemptEncryption = false` in `Info.plist` (no
non-exempt encryption). This aligns with the "Data Not Collected" App Privacy setting.

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