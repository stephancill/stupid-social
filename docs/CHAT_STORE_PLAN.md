# Chat Store Plan

Status: proposal, not yet implemented. Replaces the per-chat snapshot (`ChatSnapshotCache`) and the 5-chat prefetch
with a local-first message store, following how Telegram's iOS client (Postbox) and the Matrix Rust SDK (event
cache) work. When implemented, the design moves into `stupid-chatkit/docs/DESIGN.md` and `docs/TECHNICAL_DESIGN.md`
§ Chat Framework, and this file is deleted.

## Goal

- Tapping a chat draws its messages, positioned at the first unread, in the first frame. A spinner shows only when
  nothing of that part of the chat has ever been seen.
- What opens is already current: messages that arrived while the app was open, or in the background, are on disk.
- Scrolling back reads from disk; missing history loads before the user reaches it.
- The composer works at once and offline; sends survive the app being killed.
- Opening from a notification lands on the message.

## Principle

The screen reads only from the store; the network only writes to it. An adapter no longer keeps a message list:
it fetches pages and live events and translates them into records the kit stores. Telegram works this way, which is
why it never waits.

## Store (kit: `ChatStore`)

One SQLite database (the system `sqlite3`, no dependency), in the App Group container so the notification
extension can write to it, WAL mode, file protection `completeUntilFirstUserAuthentication`. History is kept
indefinitely; Settings shows its size and can clear it. Removing an account deletes its rows.

Tables:

- `chat`: chat key, account id, network; the adapter's chat state (opaque `Data`: title, names, avatars, read
  positions, access hashes, whatever the adapter needs to render and act); when it was last opened.
- `chunk`: a run of history known to have no gaps. Its earlier edge has a cursor (or "start of history"); its later
  edge either reaches the newest message, verified at a sync epoch (below), or has a cursor.
- `record`: chat key, id, chunk, sort key (`Int64` plus the id as tie-break), the id it relates to (`nil` for a
  message; set for an event about another message, such as an X Chat reaction or edit), and the adapter's own record
  (`Data`: `TelegramMessage`, `DiscordMessage`, an encrypted X Chat event, …).
- `outbox`: messages the user sent that the network hasn't confirmed (see Sending).

Why the adapter's own record rather than `ChatMessage`: rendering depends on chat state that changes (Apron's
current user names, Discord channel and role names), X Chat must stay encrypted at rest and decrypt on read, and
actions need native fields (Telegram albums, LinkedIn's quoted original). Rendering 60 records on open is cheap.

Sort keys per network: Telegram message id, Apron `message_id`, Discord snowflake, X Chat sequence id, Instagram
`timestampMs`, Spotify `occurred_at`, Bluesky `sentAt`, LinkedIn `deliveredAtMs`. Pages overlap-check by id.

## Gaps (linked chunks)

Telegram describes gaps as message-id ranges, which needs dense integer ids. Most of our networks page with opaque
cursors (Instagram, Spotify, Bluesky) or timestamps (LinkedIn), so gaps follow the Matrix model: a chat is a list of
chunks, and between two chunks is a gap holding the cursor that fills it.

- A fetched page that overlaps a stored chunk merges into it (records upsert through the adapter's `merge`, so
  Apron's greater `log_id` wins and Discord's partial edits apply).
- A newest page that doesn't overlap the newest chunk becomes the new newest chunk, with a gap below it.
- Filling a gap fetches pages before the newer chunk's earlier cursor until a page overlaps the older chunk, then the
  two merge.
- Live records that start a new chunk have no page cursor; the adapter derives one from the oldest record where the
  network allows (`before:` a Telegram id, Discord snowflake, X sequence id, LinkedIn timestamp). Networks with only
  opaque cursors don't push, so their chunks always come from pages.

## Freshness: sync epochs

Each account has a sync epoch, raised whenever its live connection may have missed events. A chat's newest chunk
records the epoch at which it was last known to reach the newest message.

- A live event in the current epoch appends to the newest chunk. In a later epoch it starts a new chunk with a gap.
- A Chats list row carries its latest message id (new `ChatSummary.latestMessageId`; every network's list has it:
  Telegram `top_message`, Discord `last_message_id`, the inbox queries of the others). When the newest chunk holds
  that id, the chat is current and re-stamped with the epoch, without fetching.
- Telegram keeps its epoch across reconnects by catching up with `updates.getDifference` (and
  `updates.getChannelDifference` for open and preloaded channels), so it rarely needs any fetch.

## Sync engine (kit: `ChatSyncEngine`, one per account)

The app gives each account a sync source; the engine writes everything into the store, for every chat, open or not.

- **Live events** (Telegram updates, Apron WebSocket, Discord gateway, X Chat WebSocket, LinkedIn SSE): records,
  deletes, reactions, read positions and chat state go straight into the store. Today these are used only for the
  open chat, and Telegram refetches 30 messages instead of using the message each update carries.
- **Preloading**, after Telegram's policy: the top 30 rows, ordered pinned, unmuted, unread, newest. For each,
  ensure the newest chunk is current and the ~50 records around the first unread are stored with no gap. 3 at a
  time, only when online; skipped when the row's latest message is already stored. Also loads the first 3 images after
  the anchor into the image cache. Per-network limits apply (Apron servers allow few history pages a day, so Apron
  preloads only rows whose latest message changed).
- **Polling networks** (Instagram, Spotify, Bluesky): the list refresh is the account-wide change feed; the engine
  fetches the newest page only for rows whose latest message isn't stored. An open chat still polls at the adapter's
  interval.

## Opening a chat

1. The chat view model reads a window of ~60 records from the store when it is created, anchored at the first
   unread (from the chat state's read position) or the newest. Drawn in the first frame.
2. If the newest chunk is current for this epoch and holds the row's latest message, nothing is fetched. Otherwise
   the newest page loads in the background and merges without moving the scroll position.
3. Scrolling reads further chunks from disk; a gap within ~20 records of the edge starts filling.
4. Jumping to a message (a quote, a notification, search) reads it from disk if stored, else fetches a page around
   it where the network can (Discord `around`, Apron `before`/`after`, LinkedIn anchor timestamp, Telegram
   `offset_id` with a negative `add_offset`), else pages back as today.

`ChatViewModel` observes the store for its chat key, so a write from the engine, a poll or the notification
extension redraws it. The connection state no longer gates the composer.

## Sending (outbox)

Every send is an outbox row first (text, reply, attachments copied into the store's directory, sticker, voice note,
native forward reference), shown at once as sending. The engine delivers it when the account is connected, in
order per chat, and the confirmed record replaces it (matched by the id the network returns, as today). Pending
sends survive a relaunch. A send the network refuses stays in the chat marked failed, with Retry and Delete,
as in Telegram; today it is taken out and put back in the composer.

## Background

- `BGAppRefreshTask` (about every 15 minutes where iOS allows): refresh the Chats lists and preload the top unread
  rows within the task's time.
- Notification extension: an Apron push carries the message id, room, sender and text, so the extension writes a
  provisional record (a new chunk with a gap below it) and the chat opens on it; the full record replaces it. A
  Telegram push's `msg_id` (to be confirmed against a live push) marks the chat stale and names the message to
  open at.
- `docs/PLAN.md` (background polling) and `docs/TECHNICAL_DESIGN.md` ("no `BGTaskScheduler`") change with this.

## Adapter API (breaking; kit minor version bump)

Removed from `ChatAdapter`: `messages`, `reactions`, `hasEarlierMessages`, `loadNewest`, `loadEarlier`,
`snapshot`, `restore`, and `ChatWindowing`. Added:

- `fetch(_ request: .newest | .before(cursor) | .after(cursor) | .around(messageId)) -> ChatPage` (records,
  cursors at each edge, whether it reaches the newest message or the start, and updated chat state).
- `render(records:related:state:) -> [ChatMessage]` with reaction totals.
- `merge(existing:incoming:) -> ChatRecord` (default: incoming), `cursor(before:) -> ChatCursor?`.
- `isAfterReadPosition` and `markRead` read the read position from chat state.

Optional abilities (editing, reactions, typing, mentions, stickers, …) keep their protocols; after acting, an
adapter writes the result to the store instead of to its own state.

An account-level `ChatSyncSource` (one per network client) delivers live events as store writes for any chat, plus
`catchUp` when the epoch must rise.

## Per-network work

- **Telegram:** `getDifference`/`getChannelDifference` with persisted `pts`/`qts`/`date`/`seq`; use update payloads
  instead of refetching; around-message fetch; read `msg_id` from pushes.
- **Apron:** already one socket with full snapshots; records keyed by `message_id`, merged by `log_id`; respect
  history rate limits.
- **Discord:** gateway events into the store for all channels (large guilds only after subscribing); `around` and
  `after` fetches; `READY`'s `last_message_id` for freshness.
- **X Chat:** store encrypted events, decrypt in `render` with the cached conversation keys; reactions, edits and
  deletes are related records.
- **LinkedIn:** SSE events into the store for all conversations; anchor-timestamp fetches for around and later.
- **Instagram, Spotify, Bluesky:** pages into the store; the list refresh drives freshness.
- **Demo:** an in-memory source.

## Rollout

All networks at once, in a worktree branch of each repo (the main checkout is shared with other agents): the kit
first (store, chunks, engine, chat view model, outbox, tests with fake adapters), then the eight adapters and sync
sources, then the extension, background task and Settings storage. Existing snapshots are dropped, not migrated:
each chat loads from the network once after updating.
