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
Notifications, stories and messages from all your socials in one calm app. No algorithmic feed.
```

## Description

```
stupid social brings the direct parts of your social apps together — notifications, stories and messages — without the algorithmic feed.

FEATURES
• All your notifications in one calm list: mentions, replies, likes and follows across X, Farcaster, Instagram, Bluesky and GitHub.
• One inbox for your chats on Telegram, X, Instagram, Bluesky, Spotify and Apron, with replies, reactions, photos, voice notes and files.
• A story bar for Instagram stories, Spotify listening activity and GitHub activity.
• Reply, like and repost from the post behind a notification.
• Set reminders on messages and get back to them later.
• Cross-network profile search.
• Accounts synced securely via iCloud Keychain.
```

## Keywords (≤100 chars, comma-separated, no spaces)

```
social,notifications,chat,inbox,messages,dm,telegram,x,farcaster,instagram,bluesky,github,spotify
```

## What's New (this release)

```
- Chats: Telegram, X, Instagram, Bluesky, Spotify and Apron messages in one inbox, swipe right from the feed.
- Replies, reactions, photos, voice notes, files and message reminders.
- Reply, like and repost from a notification's post.
- Multiple accounts per network.
```

## Support URL

https://github.com/stephancill/stupid-social/issues

## Notes / caveats for App Review

- The app shows only notifications/stories chosen by the connected accounts; it has no algorithmic feed and no user-content browsing catalog.
- Account connections require the user's own login to the corresponding provider (X requirements, Instagram, Farcaster handles, Bluesky OAuth, Spotify, GitHub). Credentials are stored in iCloud Keychain.
- Networking fetches provider data over HTTPS only.
- Export compliance: `ITSAppUsesNonExemptEncryption = false` is set in Info.plist.
- No demo data or test content ships in the release build: preview/demo content is compiled out under `#if DEBUG` and is absent from the App Store build.