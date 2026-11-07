# No Feed Social Plan

## Product Goal

Build an iOS app with xtool that shows a combined social network notifications feed without requiring users to open algorithmic feeds. The app started as a universal macOS and iOS app but is now iOS-only. The app started with X and Farcaster notifications and now includes Instagram stories, Spotify listening stories, Instagram story posting, and Bluesky notifications.

## MVP Scope

- Universal iOS app using xtool (previous macOS support was removed).
- Combined notifications feed for X and Farcaster.
- Multiple accounts per network: Settings → Add Account → pick the network, then sign in. Accounts and their preferences sync across the user's devices through iCloud (Key-Value storage for the list, iCloud Keychain for credentials); Telegram sign-ins stay per device.
- Manual account setup through a minimal settings form.
- Credentials sync across Apple devices through iCloud Keychain.
- Notification item cache is local-only in the MVP.
- Background polling targets roughly 15 minutes where Apple permits it.
- Manual refresh is supported.
- Instagram story posting is supported from the in-app story composer.
- Unread Instagram direct message threads are shown in the main notification feed when Instagram is connected.
- Instagram messaging settings allow users to suppress DM notifications whose latest item is a shared post or reel.
- Bluesky notifications are supported through the AT Protocol OAuth flow.
- GitHub's authenticated For You activity is shown in the stories bar, grouped into one story reel per actor.
- GitHub "starred your repository" events are notifications about the viewer's own repos, so they appear in the main notifications feed instead of the stories bar.
- Spotify and GitHub story seen state syncs across the user's devices through iCloud Key-Value storage (new capability, see `App.entitlements`). Full notification items remain local-only.

## Out Of Scope For MVP

- Cross-posting.
- Syncing full notification items across devices.
- Backend service for polling or normalization. The exceptions are the stateless Apron push relay (see Apron) and anonymous usage metrics (see Usage Metrics).
- App lock, Face ID lock, hidden previews, or custom privacy overlay.
- Cross-network identity merging.

## Platform

- iOS only. The previous macOS target was removed. The iPad app also runs on Apple silicon Macs, where the chat command line is available (see Command Line).
- Use xtool for project build and run workflows.

## Account Setup

### X

- User manually pastes a full browser `Cookie` header.
- App extracts the required cookie values, especially `auth_token` and `ct0`.
- App discards the raw cookie header after extraction.
- App stores only selected required cookie values in iCloud Keychain.
- X integration should be implemented as a native Swift client.
- X's own web client (its GraphQL operations, query ids and feature switches) is the reference for endpoint behavior, validated in `scripts/x-web-client.py`. Third-party clients such as `twitter-cli` are not references.

### Farcaster

- User enters a Farcaster username.
- App resolves the username to an FID using Hypersnap `GET /v2/farcaster/user/by-username`.
- App fetches notifications using Hypersnap's read API at `https://haatz.quilibrium.com`.
- No Farcaster token is required for the MVP notification flow.

### Bluesky

- User signs in through AT Protocol OAuth using a native app redirect URI.
- The app uses PKCE, PAR, and DPoP as required by the atproto OAuth profile.
- Access and refresh tokens are stored in Keychain with the same local-only fallback behavior as other credentials.

### GitHub

- User signs in through an embedded GitHub web login.
- Store only the selected `user_session` and `__Host-user_session_same_site` cookies in Keychain.
- Fetch the authenticated HTML `GET /conduit/for_you_feed` endpoint and parse its machine-readable Hydro metadata.
- Show GitHub activity in the stories bar, grouped by actor.
- "Starred your repository" events (target repo owner equals the viewer username) route to the main notifications feed, not the stories bar. GitHub aggregates several people who starred the same owned repo into one card with `NAME</a> starred` rows; every such actor row surfaces as its own notification.
- The OAuth `client_id` is `https://stupidtech.net/stupid-social/oauth/client-metadata.json`; login requires that exact public client metadata document to be hosted before authorization can complete.

### Discord

- User signs in through Discord's web login in an embedded WebView; the app keeps the user token the web client uses (Discord sessions are a token, not cookies). Dev mode can also take a token by hand.
- Discord has no API for user clients, so the app sends what discord.com's web client sends. Discord's terms forbid automating user accounts; the user accepts that risk by connecting.

## Credential Storage

- Store credentials in iCloud Keychain so they sync across the user's Apple devices.
- If iCloud sync is unavailable, fall back to local-only credential storage silently; Settings does not show a sync status note.
- Do not log raw credentials, cookie headers, tokens, or derived auth values.
- Show inline reconnect/update controls when credentials are invalid or expired.
- Security posture for MVP is pragmatic: correct Keychain usage, no secret logging, and clear account status.

## Notification Sources

### X

- Use X unread notification count only for future background polling paths that run while the app is not foregrounded.
- Foreground activation and manual refresh should full-fetch X notifications so the feed stays current when the app is opened.
- Each foreground/manual refresh should make only one X full-notifications request.
- Opening the feed first shows cached X items, then foreground activation refresh updates the cache when credentials are available.

Observed X behavior:

- The unread count endpoint reads the count and does not mark notifications read.
- Fetching the notifications timeline does not itself clear X's unread badge.
- After a successful foreground/manual full fetch, advance X's server-side last-seen cursor to the fetched timeline's opaque top cursor.

### Farcaster

- Use Hypersnap base URL `https://haatz.quilibrium.com`.
- Resolve usernames with `GET /v2/farcaster/user/by-username`.
- Fetch notifications with `GET /v2/farcaster/notifications`.
- Manual refresh should make only this single Farcaster notifications request; do not enrich each notification with extra cast/feed requests during refresh.
- Query by resolved `fid`.
- Supported notification types include:
  - `cast-mention`
  - `cast-reply`
  - `reaction`
  - `follow`
- Hypersnap returns aggregated notification entries.
- Hypersnap seen/write endpoints are not available for this use case because `POST /v2/farcaster/notifications/seen` and `POST /v2/farcaster/notifications/mark_seen` return `501 Not Implemented`.
- The app does not track separate Farcaster read state.

### Bluesky

- Fetch notifications with `GET /xrpc/app.bsky.notification.listNotifications` using DPoP-bound OAuth access tokens.
- Supported notification reasons include mentions, replies, likes, reposts, quotes, and follows.
- After a successful notification fetch, mark Bluesky notifications seen through the standard `app.bsky.notification.updateSeen` API.

### Apron

- Users can add any number of [Apron Chat Protocol](https://github.com/shazow/apron) servers by WebSocket URL (for example `wss://server.apron.chat/`), with an optional bearer token and display name.
- A server is shown by the name and icon it gives itself (its host without one), and its server settings show its description. Where a server is picked or signed in to, its address shows too.
- Without a token the app joins as a guest when the server offers it. Tokens are stored in Keychain like other credentials.
- Apron rooms appear on the Chats screen, not in the notifications feed: every joined room, with its latest message and unread count, updated live while the app is open. Each row is titled "<server name> / <room name>", with the server name muted.
- Opening an Apron room shows a live chat for that room, where the user can read recent history and send messages.
- A member's profile has a Message button that opens the user's DM with that person (an untitled private room of just the two of them). When there is none, it opens an empty chat with them, and the room is started only when the first message is sent, so looking and leaving creates nothing. It isn't offered on the user's own profile, inside that DM, or on servers without rooms.
- A DM shows the other person's picture, or their initials on their chat color as on their profile, both on its Chats row and beside the title in the chat. Telegram chats do the same, and Telegram groups without a photo show their initials on their own color.
- New reactions from others to the user's messages are badged on the room's Chats row and in the chat until the user has seen those messages, for reactions from the last 3 days on the user's newest 1000 messages across all Apron rooms (older reactions, and reactions to older messages, aren't shown as new). Apron keeps no such state, so the app does, and seeing them on one of the user's devices clears them on the others (through iCloud).
- The chat opens at the first unread message when there is one, shows who is typing (and shares the user's own typing) on servers with `activity`, and opens links in messages.
- Push notifications: on servers that offer Web Push (`server.push.webpush`), signed-in accounts (not guests) get notifications for mentions, replies and messages in private rooms such as DMs, while the app is closed. The app asks for notification permission the first time such a server connects.
- Each room has a notification level in its member list (opened from the chat title): All Messages, Mentions Only, or None. Rooms default to Mentions Only and private rooms to All Messages. None is a server-side room mute, so it applies to all of the user's devices. All Messages in a public room, and Mentions Only in a private room, appear only on servers that support per-room wake scopes (proposed protocol extension, see `docs/TECHNICAL_DESIGN.md`).
- Each server's notifications can be turned off on this device in its server settings.
- A notification is titled with the sender in a DM and "<sender> in <room>" in a room, shows the sender's avatar, has the server as its subtitle, and shows the message as plain text (Markdown removed, `@user_id` mentions shown as `@Name`).
- Tapping a notification opens that room, from either side of the home pager or from another open chat. Notifications for the open room aren't shown, and opening a room clears its delivered notifications.
- A notification's Reply action sends a message to the room without opening the app: in rooms it replies to the notified message, in DMs it is a plain message. A reply that fails is reported with a notification.
- Push goes through the Stupid Tech relay at `push.stupidtech.net`, which forwards end-to-end encrypted payloads to APNs and keeps no state; only the device can read message contents.

### Telegram

- Users sign in to their own Telegram account in Settings with their phone number, the login code Telegram sends (normally to their other Telegram app), and their two-step verification password when they have one.
- Telegram chats appear on the Chats screen, not in the notifications feed: private chats, basic groups and supergroups from the main chat list, with the latest message and unread count. Broadcast channels are left out, since they are feeds rather than conversations.
- Chats archived in Telegram stay archived: they are not in the main list but behind an Archived Chats row at the top of the Chats screen (as in Telegram), which shows their names and how many have unread messages, and opens a list of them. Search on the Chats screen includes archived chats.
- A chat muted in Telegram (or an Apron room set to None) shows its unread count on a gray badge rather than blue.
- Opening a chat shows its history (older pages load on scroll), and the user can send text messages, replies, photos and files. Reading moves Telegram's read cursor, so the chat is read on the user's other Telegram apps too.
- New messages appear while the chat is open. Photos and GIF thumbnails show in the bubble; stickers show without a bubble, animated (TGS) ones playing in a loop and video (WebM) ones too on iOS 26.2 and later (earlier systems have no VP9 decoder for apps, so those show a still); videos, voice messages, music, files, locations, contacts, polls and link previews show as cards (with a thumbnail where there is one). Media the app can't draw shows a label, and service messages show as captions worded like Telegram's, with the people they name ("Ashiq joined the group via invite link", "Stephan added Mat"). Quoted messages in replies show with the chat, even when the original is older than the loaded messages.
- Chats and senders show their Telegram profile photos.
- The chat shows when others are typing, and Telegram shows the user's own typing to the people in the chat.
- In groups, tapping the chat title opens the member list: online members first, then by last seen ("last seen 10 minutes ago", or "recently" when Telegram keeps the time private), with owner, admin, bot and "you" tags. Groups whose admins hide their members say so.
- Reactions show under messages and can be added or changed (one per person, as without Premium).
- A sticker button in the composer swaps the keyboard for a sticker panel, as in Telegram: the user's recent and favourite stickers and every installed set in one scrolling grid, with a tab per set that follows the scroll, a row of emoji that shows the stickers for one (the user's own first, then Telegram's suggestions), and press-and-hold for a large animated preview with Send. A tap sends the sticker (as a reply when one is being written), keeps the panel open and leaves the draft as it was; tapping the text brings the keyboard back. On a Mac the panel opens as a sheet.
- Telegram's notifications reach the app through APNs for unmuted chats, worded like Telegram's own ("Name @ Group: text"), and tapping one opens the chat. The app asks for notification permission when the user signs in to Telegram.
- Each device signs in as its own Telegram session; the session stays on the device and is not synced through iCloud. Signing out ends that session on Telegram.
- The app connects to Telegram directly with MTProto; there is no backend. Telegram is available only in builds that include the app's Telegram API credentials.
- Not supported: secret chats, starting new chats, playing videos and voice messages, and Premium reactions.

### X Chat

- X's chats (X Chat, which replaced X DMs and is end-to-end encrypted) appear on the Chats screen when X is connected and the user has entered their X Chat PIN in Settings → X. The PIN recovers the account's chat keys from X's key backup once; the keys sync to the user's other devices through iCloud Keychain, so the PIN is needed once per Apple account. A wrong PIN uses one of X's limited tries, and the app says how many are left. "Forget Keys" removes them, and disconnecting X does too.
- Every inbox conversation (not message requests) is listed with its latest message, time and unread count; archived ones sit behind the Archived Chats row and muted ones show a gray badge. Group chats are named for their members.
- Opening a chat shows its decrypted history (older pages load on scroll), new messages and reactions as they happen (the Chats list updates live too), edits, deletions, reactions and quoted replies. The user can send text messages, replies, and photos or files (with an optional caption), and add or remove reactions. Reading moves the user's X read marker, so the chat is read on X too. Unread counts, like X's badge, count messages, not reactions.
- Messages that don't decrypt show as "Couldn't decrypt this message." rather than disappearing. Shared posts and links show as cards; photos, videos and files show in the bubble, decrypted on the device.
- Not supported yet: group titles, message requests, starting chats, and old (pre-X Chat) DM conversations that weren't migrated.

### Bluesky Chat

- Bluesky chats (DMs) appear on the Chats screen when Bluesky is connected: the newest 50 accepted chats with their latest message, time and unread count. Message requests are left out, and chats muted in Bluesky show a gray badge.
- Opening a chat shows its history (older pages load on scroll) and new messages polled while it is open. The user can send text messages and add or remove reactions. Reading moves Bluesky's read state, so the chat is read in Bluesky's own apps too. Shared posts show as cards that open the post.
- Chat needs the `transition:chat.bsky` OAuth scope, so accounts connected before chat support must sign in to Bluesky again; until then the Chats screen says so.
- Not supported: message requests, starting chats, and sending posts or links as embeds (Bluesky chat has no replies or attachments).

### Discord Chat

- Discord chats appear on the Chats screen when Discord is connected: DMs and group DMs, and every text and announcement channel the user can see in each server, shown as Apron shows rooms ("Server / channel", with the server's icon). Threads the user has joined and each forum's 10 most recently active posts are chats too, named under their channel ("Server / channel" before the thread's name). Message requests, spam and voice channels are left out. Channels and servers muted in Discord show a gray badge.
- Each row has its latest message, time and unread count for the 25 most recent chats; older rows show their time until a message arrives. Discord reports only mention counts, so unread counts come from the newest page of messages (or one, for a row without a loaded page).
- Opening a chat shows its history (older pages load on scroll) and live messages, edits, deletions, reactions and typing while it is open. The user can send text, photos and files, and stickers (Discord's standard packs and the server's own; any server's with Nitro), reply, edit and delete their own messages, react (including with custom emoji already on messages), and @mention people. Reading moves Discord's read state, so the chat is read in Discord's own apps too. Attachments, embeds, stickers and custom emoji display; channel links, role mentions and timestamps read as text.
- Tapping someone's picture or mention, or a DM's title, opens their profile (picture, name, username, pronouns, bio, mutual servers) with a Message button that opens your DM with them, starting one if there is none.
- Not supported: message requests, voice messages, and voice.

### Chat Title

- Every chat's title shows its network's icon before the subtitle.

### Command Line

- On a Mac (the iPad app on Apple silicon), and in the simulator, the `stupid-social` command in `cli/` reads and sends chats through the running app: list chats, read a chat's latest messages, send text (optionally as a reply), mark a chat read, and watch a chat's new messages or every chat's row changes. It works for every network the Chats list shows and behaves as the chat screen does (drafts kept, read markers, the Chats row kept current).
- Off by default: the user turns it on in Settings → Advanced → Command-Line Access, which shows the token the command pairs with and resets it. Attachments and reactions aren't supported from the command line.

### Sending

- In every chat (Apron, Spotify, Instagram, Telegram, X, Bluesky), a sent message shows at once with a clock beside its time while it is sending, and the network's copy then takes its place without moving it. A photo shows from the picked image straight away. If sending fails, the message goes and its text and attachment return to the composer. Apron commands are the exception: they may not post a message, so the composer waits for them.
- In chats whose network allows it (Telegram, Apron on servers with `edit`, X), the user can edit the text of their own messages from the long-press menu. The composer then holds the message's text under an "Edit Message" bar (what was being written, and a reply, wait until the edit is saved or cancelled), and sending saves it. The message shows the new text at once; if saving fails, it shows as it was and the edit returns to the composer. Telegram allows editing for 48 hours (always in Saved Messages) and not for messages whose formatting an edit would lose; X allows it for its encrypted messages. Edited messages show "edited" before their time where the network says so (Telegram, X); Apron gives no reliable sign, so its messages don't. Instagram, Bluesky and Spotify chats can't edit.
- Where the network reports when others read the user's messages (Telegram, Instagram, X), the user's messages show one check after the time once sent and two once someone else has read them, as in Telegram. Chats on networks without read state (Apron, Bluesky, Spotify) show neither.

## Combined Feed

- Default layout is a single combined chronological list.
- A horizontal stories bar appears above the list for story-like activity.
- The stories bar currently shows Spotify listening activity; Instagram stories are planned for the bar later.
- The story viewer supports hardware-keyboard navigation (external/iPad keyboards and the Mac-compatibility path): Left/Right for prev/next slide, Shift+Left/Shift+Right for prev/next user, and Space to pause the slide timer.
- Instagram story likes remain in the main notifications feed.
- Unread Instagram DMs remain in the main notifications feed.
- Spotify listening activity is not shown in the main notifications list.
- Spotify Messages chats appear on the Chats screen, not in the notifications feed.
- Opening a Spotify Messages chat shows the full chat in the same chat screen as Apron: paged history, new messages polled while open, sending text, and the chat marked seen in Spotify once its newest incoming message is shown. Shared tracks show their artwork, artists, album, year and length, and play their 30-second preview inline; other shares open in Spotify.
- Swiping right from the feed shows a Chats screen to the left of the feed listing every chat: all joined Apron rooms on every server, the latest 50 Spotify Messages chats, the latest 35 Instagram Direct threads, Telegram chats, X chats, the latest 50 Bluesky chats and Discord DMs and channels, newest first, each with its latest message, time and unread count. Small page dots at the bottom centre show which side is visible. The app reopens on whichever side it was left on. A search bar under the Chats title filters chats by name and latest message. Swiping between them is disabled while a screen is pushed on either side, and the dots are hidden then.
- In every chat, messages are grouped by day under a date chip ("Today", "Yesterday", "October 12", with the year when it isn't this one), as in Telegram. While scrolling, the current day's chip stays pinned at the top until the next day's pushes it away, and fades out a moment after scrolling stops.
- Long-pressing a chat's title searches the chat, in every network: the app's search field opens focused, matches are highlighted in the messages, and a bar in place of the composer shows "N of M" with arrows to the previous and next match. Search covers the loaded messages and loads earlier history as the user goes back past the oldest match, or presses Search with nothing found (up to 10 pages at a time); "+" after the count means earlier history may hold more.
- Instagram Direct threads appear on the Chats screen (newest 35). Opening one shows the same chat screen: paged history, new messages polled while open, sending text and replies, reacting to messages (one reaction per person, as in Instagram), and the thread marked read once its newest incoming message is shown. Photos open full screen; shared posts, reels and stories open in Instagram.
- GitHub For You activity is not shown in the main notifications list, except "starred your repository" events, which route to the notifications feed.
- GitHub story tiles group stars, follows, created repositories, and repository forks by actor, with each activity represented as a slide.
- Spotify listening story tiles show the album/track artwork as the thumbnail with the listener's avatar overlaid in the bottom-right corner.
- Tapping a Spotify listening story opens the Listening detail screen.
- Each item shows a network badge.
- A row of pills above the notifications filters the feed: a Reminders pill for every chat reminder, then one per account with notifications (network icon and account name), ordered by its number of notifications. Any number can be selected and the feed shows what any of them match; a clear button at the row's right edge removes the filter.
- The feed shows newly discovered notification items plus known recent cached items.
- Successful refreshes insert fetched notifications directly into the visible chronological feed.
- Recent notification cache retention is 24 hours.
- Notification items are normalized into one app model for display.
- The normalized notification schema should be a minimal display model.
- Notification item cache remains local per device in the MVP.
- No cross-network identity merging in the MVP.

## Profile Details

From a notification or search result, the user should be able to view an account detail screen.

The account detail should show:

- Name
- Profile picture
- Follower count
- Following count
- Follow/Unfollow button for networks that support it (X and Instagram in current scope).
- For X, a post-notifications (bell) toggle. Turning it on/off is independent of follow state.

The MVP should not attempt to merge or link X and Farcaster actors.

## Post Engagement

- On X, the post shown in a notification's detail (a new post from someone the user gets post notifications for, a mention, a like of the user's post, and so on; not the two-post reply thread) looks like a post on X: avatar, name, handle and age on one line, the text and media, then an action bar with reply, repost and like counts and Share.
- The user can like and unlike, reply, quote, and undo a repost from the action bar. Replying and quoting open a composer sheet. Reposting opens X's own repost page, because X turns away reposts from this app; the counts refresh on return.
- Tapping the post's content opens it on X.
- On X, post details show the post's thread, loaded when the screen opens: every earlier post in the thread joined by a line, then the notification's post, whose row is tinted edge to edge when there are posts above it. Replies to the post aren't shown. Until the thread arrives, the post shows, with the post it replies to when the notification has it. New-post notifications, which list several posts, keep their list.

## Automatic And Refresh Behavior

- Manual refresh is always available.
- The app refreshes automatically when entering the foreground.
- X foreground automatic refresh should full-fetch X notifications, then explicitly advance the server-side last-seen cursor.
- Successful foreground/manual loads mark fetched X, Instagram activity, and Bluesky notifications read on their providers. Instagram DMs remain unread until the user opens the conversation.
- Farcaster foreground automatic refresh may fetch notifications because Hypersnap does not alter server-side notification state.
- Foreground automatic refresh should update the visible feed immediately after caching fetched items.

## Future Posting Scope

Posting is now in current scope for Instagram stories. Other posting surfaces remain future scope.

Current posting requirements:

- Render a local story composition into a 1080x1920 image.
- Post image stories to the connected Instagram account.
- Show the user's own Instagram story entry first in the stories bar with their profile picture and a `+` affordance that opens the composer.
- In the combined All Stories bar, the `+` affordance first asks for the story destination; Instagram is the only current destination. In the Instagram-only stories bar, Instagram is implied and the `+` opens the composer directly.

Future posting requirements:

- Text posts.
- Media attachments.
- Posting to selected supported channels beyond Instagram stories.
- Account/profile preview in the composer.
- Eventually support X, Farcaster, and Bluesky posting.

For notification-related profile preview, the app should support viewing actor account details from notification items.

## Normalized Notification Schema

Use a minimal display model first. Suggested fields:

- `id`: stable app-level notification id
- `network`: supported social network, such as `x`, `farcaster`, or `bluesky`
- `accountId`: stable account identifier for the viewer account
- `sourceId`: source notification or event id when available
- `type`: normalized notification type
- `timestamp`: source event timestamp used for sorting
- `text`: display text or summary
- `actors`: people/accounts responsible for the notification
- `target`: referenced post, cast, profile, or other object needed for display/navigation

Do not persist raw source payloads for the MVP unless needed during development diagnostics, and never log or store secrets with notification data.

## Usage Metrics

- The app reports anonymous usage and errors to stupid metrics (`metrics.stupidtech.net`, a separate Stupid Tech service): sessions, feed refreshes per network (duration, outcome), chat opens, message sends, notification opens and replies, account connects and removals, story opens and posts, connected-account counts per network, errors by type and case, and MetricKit crash, hang and exit reports.
- Only networks, triggers and outcomes are sent, with the app version, OS version, device model and a random install id. Never account names, handles, message or notification text, URLs or ids.
- On by default. Settings → Advanced → Share Usage Data turns it off, which also deletes anything queued and the install id.
- The App Store privacy answers must declare Diagnostics and Usage Data, not linked to the user and not used for tracking, before a build with metrics is submitted.

## App Review Preview Access

- Include the existing sample notifications and stories in release builds.
- Keep preview controls hidden behind four taps on the Settings About heading; do not add a public Try Demo button.
- Reviewers explicitly turn on Preview content after revealing developer settings. Document these steps in App Review Information.
- Preserve real notification cache and credentials when loading/unloading sample content.
