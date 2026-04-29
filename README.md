# stupid social

A notifications-only social app. See what matters without the algorithmic feed.

iOS &bull; macOS

## Screenshots

<p align="center">
  <img src="screenshots/settings.png" width="200" alt="Settings">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="screenshots/feed.png" width="200" alt="Feed">
</p>

## Features

- Combined feed for X and Farcaster notifications
- Engagement-only X filtering (mentions, replies, quotes, likes, retweets)
- Unread/read sections with compact timestamps
- Pull-to-refresh
- Liquid Glass design on iOS 26
- Runs on macOS too

## Setup

Built with [xtool](https://github.com/xtool-org/xtool).

### Prerequisites

- macOS with Xcode 26
- [xtool](https://github.com/xtool-org/xtool) installed and authenticated (`xtool auth status`)
- For TestFlight: Apple Developer Program membership and App Store Connect app record

### Clone and configure

```bash
git clone git@github.com:stephancill/stupid-social.git
cd stupid-social
```

Add your Apple Developer Team ID to `xtool.yml`:
```yaml
teamID: YOUR_TEAM_ID
```

### Run on iOS Simulator

```bash
xtool dev run --simulator
```

### Run on iPhone over Wi-Fi

```bash
xtool devices --all --no-wait        # find your device UDID
xtool dev run --network -u <udid>
```

### Run on macOS

```bash
# Build and launch via SwiftPM
swift build
.xcode-derived/Build/Products/Debug/NoFeedSocialMac

# Or via xcodebuild
xcodebuild -scheme NoFeedSocialMac -destination 'platform=macOS' -derivedDataPath .xcode-derived build 2>&1 | xcpretty
open .xcode-derived/Build/Products/Debug/NoFeedSocialMac
```

### Regenerate Xcode workspace (after changing Info.plist or xtool.yml)

```bash
xtool dev run --simulator --no-attach --no-logs
open xtool/NoFeedSocial.xcworkspace
```

## Release

### Prerequisites

- Apple Developer Program membership
- App Store Connect app record with bundle ID `tech.stupid.StupidSocial`
- xtool installed and authenticated (`xtool auth status`)

### Build and Submit

1. **Edit `Info.plist`** for any metadata changes (display name, supported devices, etc.)

2. **Regenerate the Xcode workspace:**
   ```bash
   xtool dev run --simulator --no-attach --no-logs
   ```

3. **Open the workspace in Xcode:**
   ```bash
   open xtool/NoFeedSocial.xcworkspace
   ```

4. **Archive:**
   - Select the `NoFeedSocial` scheme
   - Destination: **Any iOS Device (arm64)**
   - **Product → Archive**

5. **Distribute:**
   - In the Organizer, select the archive
   - Click **Distribute App**
   - Choose **App Store Connect** → **Upload**
   - Xcode handles signing and provisioning automatically

6. **App Store Connect:**
   - Uploaded build appears in **TestFlight** within a few minutes
   - Add internal/external testers under **TestFlight** → **Internal Testing** or **External Testing**
   - Set category to **Social Networking** under **App Information**
   - First external build requires Beta App Review approval
   - When ready: **App Store** tab → select build → fill in metadata → **Submit for Review**

