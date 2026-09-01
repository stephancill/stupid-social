# App Store Copy — stupid social

Current, source-of-truth listing copy for the App Store version. Feed back to ASC via
`populate_listing.py</current>. Keep fields current.

## App name

```
stupid social
```

## Subtitle (≤30 chars)

```
only the best parts of social
```

## Promotional text (≤170 chars)

```
The best parts of social — the notifications, stories and profiles that matter — without the feed.
```

## Description

```
stupid social aggregates notifications and stories across your favourite social apps.

FEATURES
• All your notifications in one calm list — mentions, replies, likes and follows across X, Farcaster, Instagram, Bluesky and GitHub.
• A story bar for Instagram stories, Spotify listening activity and GitHub activity.
• Deep-links into the profile behind every notification and story.
• Cross-network profile search.
• Publish stories to Instagram right from the app.
• Credentials synced securely via iCloud Keychain.
```

## Keywords (≤100 chars, comma-separated, no spaces)

```
social,notifications,x,farcaster,instagram,spotify,bluesky,github,mentions,replies,follow
```

## What's New (this release)

```
- X and Farcaster: mentions, replies, likes and follows in one calm list.
- Instagram stories and direct messages.
- Spotify listening activity.
- GitHub activity and "starred your repository" updates.
- Bluesky notifications.
- Publish stories to Instagram.
- Notification-based profile details and follow controls.
```

## Support URL

https://github.com/stephancill/stupid-social/issues

## Notes / caveats for App Review

- The app shows only notifications/stories chosen by the connected accounts; it has no algorithmic feed and no user-content browsing catalog.
- Account connections require the user's own login to the corresponding provider (X requirements, Instagram, Farcaster handles, Bluesky OAuth, Spotify, GitHub). Credentials are stored in iCloud Keychain.
- Networking fetches provider data over HTTPS only.
- Export compliance: `ITSAppUsesNonExemptEncryption = false` is set in Info.plist.
- No demo data or test content ships in the release build: preview/demo content is compiled out under `#if DEBUG` and is absent from the App Store build.