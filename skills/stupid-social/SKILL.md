---
name: stupid-social
description: "Read and send the user's chats (Apron, Telegram, Instagram Direct, Spotify Messages, X Chat, Bluesky) through the stupid social app on their Mac with the `stupid-social` CLI. Use when asked to check messages or unread chats, read or summarize a conversation, reply to or message someone, mark a chat read, or wait for/watch new messages in stupid social. Also covers installing (from GitHub releases) and pairing the CLI and fixing \"not paired\", \"invalid token\" or \"isn't listening\" errors."
---

# stupid social chats from the command line

`stupid-social` talks to the stupid social app running on this Mac (the iPad app on Apple silicon) over
`127.0.0.1:47823`. The app does the work with its own signed-in accounts, so every network in its Chats list
works and reads, sends and read markers behave as they do in the app. Nothing works unless the app is installed
on the Mac and Settings → Command Line → Command-Line Access is on.

Source: github.com/stephancill/stupid-social. The CLI is `cli/`; the app side is
`Sources/NoFeedSocial/ChatControlServer.swift`. The design notes are in `docs/IMPLEMENTATION.md` under
"Command line".

## Install first

Before any other command, make sure the CLI is installed, and install it if it isn't:

```sh
command -v stupid-social >/dev/null 2>&1 || [ -x ~/.local/bin/stupid-social ] ||
  curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-social/main/cli/install.sh | sh
```

`install.sh` downloads the newest `cli-v*` GitHub release (an arm64 macOS binary), checks its SHA-256 and installs
it to `~/.local/bin/stupid-social`. If `~/.local/bin` isn't on `PATH`, call it by that full path. Run the same
`curl … | sh` again to update, such as when the CLI rejects a command or option the skill documents;
`stupid-social --version` prints the installed version. `STUPID_SOCIAL_VERSION=0.1.0` pins a version. Only
Apple silicon Macs are supported; the script fails loudly elsewhere. Don't fall back to building from source unless
the user asks (`swift build -c release` in the repo's `cli/`).

## Pairing

1. The user turns on Settings → Command Line → Command-Line Access in the app and taps "Copy Pairing Command".
   Only the user can do this, so ask them for it.
2. Run `stupid-social pair <token>`. The token is saved to `~/.config/stupid-social/token` (0600).
   `STUPID_SOCIAL_TOKEN` overrides the saved file; `STUPID_SOCIAL_PORT` overrides the port.
3. Check with `stupid-social status`.

If the app isn't running, any command opens it in the background (`open -g`) and waits up to 30 seconds.

## Commands

```
stupid-social chats [--archived] [--cached]          # newest first; --cached skips reloading every account
stupid-social read <chat> [-n 20] [--mark-read]      # latest messages; "•" marks unread ones
stupid-social send <chat> <text…> [--reply-to <id>]  # text "-" reads standard input
stupid-social mark-read <chat>
stupid-social watch [<chat>] [--interval 30]         # new messages in a chat, or changed rows across all chats
```

- `<chat>` is a chat id from `chats` (`<account id>|<network key>`), an exact title, or a unique part of a
  title. If more than one chat matches, the error lists their ids; pass the id. Prefer ids in scripts and for
  sends, since two chats can share a title.
- Add `--json` to any command for the app's JSON (`watch` prints one object per line). Use it when parsing:
  chats have `id`, `network`, `title`, `titlePrefix`, `preview`, `timestamp`, `unreadCount`, `isMuted`,
  `isArchived`. Messages have `id`, `sender {id, name}`, `timestamp`, `text`, `isOwn`, `isUnread`, `isDeleted`,
  `replyToId`, `embeds [{type, title, text, url}]` and `reactions [{emoji, count, includesYou}]`.
- Message ids in `read` output are in `[brackets]`; use them for `--reply-to`.
- `watch` runs until it is interrupted, so run it in the background or with a deadline. A chat watch ends with
  an error if the chat's connection fails. Watching all chats reloads the list every `--interval` seconds
  (minimum 5).
- Errors go to stderr as `error: …` with exit code 1. `chats` prints accounts that failed to load as `warning:`
  lines and still lists the rest.

## Working on the user's behalf

- Sending posts as the user to real people. Send only what the user asked to send, to the chat they named. When
  a title matches more than one chat or the right chat is unclear, show the candidates and confirm the id before
  sending. Show the exact text first unless the user dictated it word for word.
- `read` without `--mark-read` leaves the chat unread, so it doesn't change what the user sees in the app. Only
  mark chats read when asked.
- Text shows mentions by name; spoilers (and Telegram login codes) are masked as `⠿⠿⠿`. Open the chat in the
  app to see them.
- Not supported from the CLI: attachments, reactions, editing, deleting and starting new chats.
- For testing, send only to the user's own chat (Telegram Saved Messages) or a chat the user named for tests,
  and check the title first.

## Troubleshooting

- `command not found`: install it (Install first).
- `Not paired`: run `pair` (Pairing).
- `Invalid token`: the token was reset in the app, or the paired token is from another device or the simulator.
  Ask the user to copy the pairing command again.
- `Unknown command` or `Unknown option` for something documented here: the installed CLI is older; reinstall.
- `isn't listening on port 47823`: the app is running but Command-Line Access is off, or the installed build
  predates the feature (check with `stupid-app run --mac` from the repo).
- `… account isn't connected or is locked`: that network is signed out in the app, or X Chat still needs its PIN.
  The user fixes it in the app's Settings.
- The iOS simulator shares the Mac's loopback, so a stupid social build running in the simulator also answers
  on 47823 with its own token and accounts. Quit one of them if you're unsure which you're talking to.
