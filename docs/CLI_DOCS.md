# CLI Docs

This app can use the locally patched `twitter-cli` executable for X/Twitter notification data.

## Source

Local patched source:

```text
/Users/stephan/.config/opencode/skills/twitter-cli
```

Upstream repository:

```text
https://github.com/jackwener/twitter-cli
```

The installed `twitter` executable is managed by `uv tool` and currently points at the local patched source.

## Authentication

`twitter-cli` authenticates with either:

1. Browser cookies from a logged-in X session in Arc, Chrome, Edge, Firefox, or Brave.
2. Environment variables: `TWITTER_AUTH_TOKEN` and `TWITTER_CT0`.

Check auth:

```bash
twitter status --json
```

## Unread Notification Count

Use this for app polling. It does not fetch the full notifications timeline and should not mark notifications as read.

```bash
twitter notifications-count --json
```

Response shape:

```json
{
  "ok": true,
  "schema_version": "1",
  "data": {
    "type": "all",
    "id": "AAAA...",
    "unreadCount": 0
  }
}
```

Read `data.unreadCount`.

Supported timelines:

```bash
twitter notifications-count --type all --json
twitter notifications-count --type mentions --json
twitter notifications-count --type verified --json
```

## Fetch Notifications

Fetch structured notification objects:

```bash
twitter notifications --max 50 --json
```

Supported timelines:

```bash
twitter notifications --type all --max 50 --json
twitter notifications --type mentions --max 50 --json
twitter notifications --type verified --max 50 --json
```

Response data includes:

```json
{
  "notifications": [],
  "unreadCount": 0,
  "unreadCountComplete": true,
  "unreadSortIndex": "1777273512737"
}
```

Each notification includes `type`, `message`, `isUnread`, `actors`, `targetTweets`, and sometimes `tweet`.

If `unreadCountComplete` is `false`, the fetched page did not reach X's read boundary. Increase `--max` or continue with `pagination.nextCursor`.

## Marking Read

Fetching the notifications timeline appears to behave like opening the Notifications tab in X and can clear unread state for fetched entries:

```bash
twitter notifications --max 50
```

Use `notifications-count` for polling when you do not want to mark notifications as read.
