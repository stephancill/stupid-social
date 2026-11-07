#!/usr/bin/env python3
"""Probe Discord's web client API (REST v9 and the gateway) with a user token.

Dependency-free. Sends what discord.com's web client sends: the Authorization
header, a Chrome user agent and X-Super-Properties (observed 2026-11-07,
client_build_number 667580). The token comes from DISCORD_TOKEN in the
environment or .env.local; it is never printed.

Message text from other people is never printed: messages show their author
id, length and attachment/embed counts. --show-text prints text only for
messages the token's own user wrote.

Mutations (send, react, ack, typing) run only in the channel passed with
--channel, and send/react/typing also need --expect-name to match the
channel's name (or the DM recipient's username), so a typo can't post in the
wrong chat.

Examples:
  scripts/discord-web-client.py me
  scripts/discord-web-client.py guilds
  scripts/discord-web-client.py channels --guild 123
  scripts/discord-web-client.py dms
  scripts/discord-web-client.py history --channel 456 --limit 20 [--before 789]
  scripts/discord-web-client.py around --channel 456 --message 789
  scripts/discord-web-client.py send --channel 456 --expect-name probe --text "hi" [--reply-to 789]
  scripts/discord-web-client.py edit --channel 456 --expect-name probe --message 789 --text "hi again"
  scripts/discord-web-client.py delete --channel 456 --expect-name probe --message 789
  scripts/discord-web-client.py react --channel 456 --expect-name probe --message 789 --emoji 👍 [--remove]
  scripts/discord-web-client.py ack --channel 456 --message 789
  scripts/discord-web-client.py typing --channel 456 --expect-name probe
  scripts/discord-web-client.py ready                       # gateway READY summary: guilds, channels, read states
  scripts/discord-web-client.py follow --seconds 60         # gateway dispatch event names and channel ids
  scripts/discord-web-client.py raw GET /users/@me/guilds   # any GET, JSON shape only (keys and types)
  scripts/discord-web-client.py threads                     # channel types, forums and READY threads per guild
  scripts/discord-web-client.py forum-threads --channel 456 # a forum's newest posts
  scripts/discord-web-client.py stickers                    # standard packs and guild stickers by format
  scripts/discord-web-client.py profile --user 123 [--shape]
  scripts/discord-web-client.py upload --channel 456 --expect-name probe --file photo.png [--text "hi"]
  scripts/discord-web-client.py send-sticker --channel 456 --expect-name probe --sticker 789
  scripts/discord-web-client.py open-dm --user 123           # the DM with a user, created if needed (no message)
"""

from __future__ import annotations

import argparse
import base64
import collections
import json
import mimetypes
import os
import secrets
import select
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
API = "https://discord.com/api/v9"
GATEWAY = "wss://gateway.discord.gg/?encoding=json&v=9"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
)
BUILD_NUMBER = 667580

# Channel types (https://discord.com/developers/docs/resources/channel#channel-object-channel-types)
CHANNEL_TYPES = {
    0: "text",
    1: "dm",
    2: "voice",
    3: "group_dm",
    4: "category",
    5: "announcement",
    10: "announcement_thread",
    11: "public_thread",
    12: "private_thread",
    13: "stage",
    15: "forum",
    16: "media",
}
TEXT_TYPES = {0, 1, 3, 5}


def env(name: str) -> str | None:
    if os.environ.get(name):
        return os.environ[name]
    local = ROOT / ".env.local"
    if local.exists():
        for line in local.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name:
                return value.strip().strip('"')
    return None


def token() -> str:
    value = env("DISCORD_TOKEN")
    if not value:
        raise SystemExit("Set DISCORD_TOKEN in the environment or .env.local")
    return value


def super_properties() -> dict[str, Any]:
    return {
        "os": "Mac OS X",
        "browser": "Chrome",
        "device": "",
        "system_locale": "en-US",
        "has_client_mods": False,
        "browser_user_agent": USER_AGENT,
        "browser_version": "156.0.0.0",
        "os_version": "10.15.7",
        "referrer": "",
        "referring_domain": "",
        "referrer_current": "",
        "referring_domain_current": "",
        "release_channel": "stable",
        "client_build_number": BUILD_NUMBER,
        "client_event_source": None,
    }


def headers() -> dict[str, str]:
    return {
        "Authorization": token(),
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "X-Discord-Locale": "en-US",
        "X-Discord-Timezone": "Africa/Johannesburg",
        "X-Debug-Options": "bugReporterEnabled",
        "X-Super-Properties": base64.b64encode(json.dumps(super_properties(), separators=(",", ":")).encode()).decode(),
        "Origin": "https://discord.com",
        "Referer": "https://discord.com/channels/@me",
    }


def api(method: str, path: str, body: Any = None) -> Any:
    data = None
    hdrs = headers()
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    request = urllib.request.Request(API + path, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            if not raw:
                return {"status": response.status}
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise SystemExit(f"{method} {path} -> {error.code}: {detail}")


def shape(value: Any, depth: int = 0) -> Any:
    """Keys and value types, so responses can be inspected without their content."""
    if depth > 4:
        return "…"
    if isinstance(value, dict):
        return {k: shape(v, depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0], depth + 1), f"×{len(value)}"] if value else []
    return type(value).__name__


def summarize_message(message: dict[str, Any], me: str | None, show_text: bool) -> dict[str, Any]:
    author = message.get("author") or {}
    mine = author.get("id") == me
    summary: dict[str, Any] = {
        "id": message["id"],
        "type": message.get("type"),
        "author": author.get("id"),
        "mine": mine,
        "timestamp": message.get("timestamp"),
        "edited": message.get("edited_timestamp") is not None,
        "length": len(message.get("content") or ""),
        "attachments": [a.get("content_type") for a in message.get("attachments", [])],
        "embeds": [e.get("type") for e in message.get("embeds", [])],
        "stickers": len(message.get("sticker_items", [])),
        "reactions": [
            {"emoji": (r.get("emoji") or {}).get("name") if not (r.get("emoji") or {}).get("id") else "custom", "count": r.get("count"), "me": r.get("me")}
            for r in message.get("reactions", [])
        ],
        "mentions": len(message.get("mentions", [])),
    }
    if message.get("message_reference"):
        summary["reply_to"] = message["message_reference"].get("message_id")
    if show_text and mine:
        summary["text"] = message.get("content")
    return summary


def channel_name(channel: dict[str, Any]) -> str:
    if channel.get("name"):
        return channel["name"]
    recipients = channel.get("recipients") or []
    return ", ".join(r.get("username", "?") for r in recipients)


def guard(channel_id: str, expect: str | None) -> dict[str, Any]:
    channel = api("GET", f"/channels/{channel_id}")
    name = channel_name(channel)
    if not expect or expect != name:
        raise SystemExit(f"refusing: channel {channel_id} is named {name!r}; pass --expect-name with that exact name")
    return channel


# Gateway ---------------------------------------------------------------------


class WebSocket:
    def __init__(self, url: str, timeout: float = 20) -> None:
        parsed = urllib.parse.urlparse(url)
        host = parsed.hostname or ""
        raw = socket.create_connection((host, parsed.port or 443), timeout=timeout)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        self.buffer = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        path = (parsed.path or "/") + ("?" + parsed.query if parsed.query else "")
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: https://discord.com\r\n"
                f"User-Agent: {USER_AGENT}\r\n\r\n"
            ).encode()
        )
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SystemExit("connection closed during handshake")
            self.buffer += chunk
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0].decode()
        if " 101 " not in status:
            raise SystemExit(f"handshake failed: {status}")

    def _read(self, count: int) -> bytes:
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send_text(self, text: str) -> None:
        payload = text.encode()
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = secrets.token_bytes(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv_text(self) -> str:
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode = b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(length)
            if opcode == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
                raise SystemExit(f"gateway closed: {code} {payload[2:].decode(errors='replace')}")
            if opcode == 0x9:
                self.sock.sendall(bytes([0x8A, 0x80]) + secrets.token_bytes(4))
                continue
            if opcode in (0x1, 0x0):
                message += payload
                if b0 & 0x80:
                    return message.decode()


class Gateway:
    """Identify, then hand out dispatch events while keeping the heartbeat."""

    def __init__(self, capabilities: int) -> None:
        self.ws = WebSocket(GATEWAY)
        hello = json.loads(self.ws.recv_text())
        assert hello["op"] == 10, hello
        self.interval = hello["d"]["heartbeat_interval"] / 1000
        self.sequence: int | None = None
        self.next_beat = time.monotonic() + self.interval * 0.5
        identify = {
            "op": 2,
            "d": {
                "token": token(),
                "capabilities": capabilities,
                "properties": {**super_properties(), "client_app_state": "focused"},
                "presence": {"status": "unknown", "since": 0, "activities": [], "afk": False},
                "compress": False,
                "client_state": {"guild_versions": {}},
            },
        }
        self.ws.send_text(json.dumps(identify))

    def events(self, seconds: float):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            wait = max(0.1, min(self.next_beat, deadline) - time.monotonic())
            ready = self.ws.buffer or self.ws.sock.pending() or select.select([self.ws.sock], [], [], wait)[0]
            if not ready:
                if time.monotonic() >= self.next_beat:
                    self.ws.send_text(json.dumps({"op": 1, "d": self.sequence}))
                    self.next_beat = time.monotonic() + self.interval
                continue
            # A frame has started: read all of it (READY can be megabytes).
            self.ws.sock.settimeout(30)
            frame = json.loads(self.ws.recv_text())
            if frame.get("s") is not None:
                self.sequence = frame["s"]
            if frame["op"] == 0:
                yield frame["t"], frame["d"]
            elif frame["op"] == 1:
                self.ws.send_text(json.dumps({"op": 1, "d": self.sequence}))
            elif frame["op"] == 9:
                raise SystemExit("gateway: invalid session")


# Commands --------------------------------------------------------------------


def cmd_me(args: argparse.Namespace) -> Any:
    me = api("GET", "/users/@me")
    return {k: me.get(k) for k in ("id", "username", "global_name", "avatar", "premium_type", "mfa_enabled")}


def cmd_guilds(args: argparse.Namespace) -> Any:
    guilds = api("GET", "/users/@me/guilds?with_counts=true")
    return [{"id": g["id"], "name": g["name"], "icon": g.get("icon"), "owner": g.get("owner"), "members": g.get("approximate_member_count")} for g in guilds]


def cmd_channels(args: argparse.Namespace) -> Any:
    channels = api("GET", f"/guilds/{args.guild}/channels")
    return [
        {
            "id": c["id"],
            "type": CHANNEL_TYPES.get(c["type"], c["type"]),
            "name": c.get("name"),
            "parent": c.get("parent_id"),
            "position": c.get("position"),
            "last_message_id": c.get("last_message_id"),
            "overwrites": len(c.get("permission_overwrites", [])),
        }
        for c in sorted(channels, key=lambda c: (c.get("position", 0), c["id"]))
    ]


def cmd_dms(args: argparse.Namespace) -> Any:
    channels = api("GET", "/users/@me/channels")
    channels.sort(key=lambda c: int(c.get("last_message_id") or 0), reverse=True)
    return [
        {
            "id": c["id"],
            "type": CHANNEL_TYPES.get(c["type"], c["type"]),
            "name": c.get("name"),
            "recipients": [r.get("username") for r in c.get("recipients", [])],
            "last_message_id": c.get("last_message_id"),
        }
        for c in channels[: args.limit]
    ]


def cmd_history(args: argparse.Namespace) -> Any:
    me = api("GET", "/users/@me")["id"]
    query = {"limit": args.limit}
    if args.before:
        query["before"] = args.before
    if args.after:
        query["after"] = args.after
    messages = api("GET", f"/channels/{args.channel}/messages?{urllib.parse.urlencode(query)}")
    return [summarize_message(m, me, args.show_text) for m in messages]


def cmd_around(args: argparse.Namespace) -> Any:
    me = api("GET", "/users/@me")["id"]
    messages = api("GET", f"/channels/{args.channel}/messages?around={args.message}&limit={args.limit}")
    return [summarize_message(m, me, args.show_text) for m in messages]


def cmd_send(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    body: dict[str, Any] = {"content": args.text, "nonce": str((int(time.time() * 1000) - 1420070400000) << 22), "tts": False, "flags": 0}
    if args.reply_to:
        body["message_reference"] = {"channel_id": args.channel, "message_id": args.reply_to}
    message = api("POST", f"/channels/{args.channel}/messages", body)
    return {"id": message["id"], "nonce": message.get("nonce"), "timestamp": message.get("timestamp")}


def cmd_edit(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    message = api("PATCH", f"/channels/{args.channel}/messages/{args.message}", {"content": args.text})
    return {"id": message["id"], "edited_timestamp": message.get("edited_timestamp")}


def cmd_delete(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    return api("DELETE", f"/channels/{args.channel}/messages/{args.message}")


def cmd_react(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    emoji = urllib.parse.quote(args.emoji)
    method = "DELETE" if args.remove else "PUT"
    return api(method, f"/channels/{args.channel}/messages/{args.message}/reactions/{emoji}/@me?location=Message%20Reaction%20Picker&type=0")


def cmd_ack(args: argparse.Namespace) -> Any:
    return api("POST", f"/channels/{args.channel}/messages/{args.message}/ack", {"token": None})


def cmd_typing(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    return api("POST", f"/channels/{args.channel}/typing")


def cmd_ready(args: argparse.Namespace) -> Any:
    gateway = Gateway(args.capabilities)
    for name, data in gateway.events(30):
        if name != "READY":
            continue
        if args.shape:
            return shape(data)
        read_state = data.get("read_state")
        entries = read_state.get("entries", []) if isinstance(read_state, dict) else (read_state or [])
        guilds = data.get("guilds", [])
        return {
            "keys": sorted(data.keys()),
            "user": data["user"]["id"],
            "session_id_present": bool(data.get("session_id")),
            "resume_gateway_url": data.get("resume_gateway_url"),
            "guilds": [
                {
                    "id": g["id"],
                    "name": (g.get("properties") or g).get("name"),
                    "keys": sorted(g.keys())[:40],
                    "channels": len(g.get("channels", [])),
                    "text_channels": sum(1 for c in g.get("channels", []) if c["type"] in TEXT_TYPES),
                }
                for g in guilds[: args.limit]
            ],
            "private_channels": len(data.get("private_channels", [])),
            "read_state_entries": len(entries),
            "read_state_sample": entries[:3],
            "user_guild_settings": shape(data.get("user_guild_settings")),
        }
    raise SystemExit("no READY within 30 s")


def cmd_follow(args: argparse.Namespace) -> Any:
    gateway = Gateway(args.capabilities)
    for name, data in gateway.events(args.seconds):
        detail: dict[str, Any] = {"t": name}
        if isinstance(data, dict):
            for key in ("channel_id", "guild_id", "id", "message_id", "user_id"):
                if key in data:
                    detail[key] = data[key]
            if name == "MESSAGE_CREATE":
                detail["author"] = (data.get("author") or {}).get("id")
                detail["length"] = len(data.get("content") or "")
                detail["nonce"] = data.get("nonce")
            if args.shape and name != "READY":
                detail["shape"] = shape(data)
        print(json.dumps(detail, ensure_ascii=False), flush=True)
    return None


def ready_payload() -> dict[str, Any]:
    gateway = Gateway(0)
    for name, data in gateway.events(30):
        if name == "READY":
            return data
    raise SystemExit("no READY within 30 s")


def cmd_threads(args: argparse.Namespace) -> Any:
    """Threads READY lists per guild (active ones the user joined), and each guild's channel types."""
    data = ready_payload()
    result = []
    for guild in data.get("guilds", []):
        threads = guild.get("threads", [])
        result.append({
            "guild": guild["id"],
            "channel_types": dict(sorted(collections.Counter(CHANNEL_TYPES.get(c["type"], c["type"]) for c in guild.get("channels", [])).items())),
            "threads": [
                {"id": t["id"], "type": CHANNEL_TYPES.get(t["type"], t["type"]), "parent": t.get("parent_id"), "joined": bool(t.get("member")), "archived": (t.get("thread_metadata") or {}).get("archived"), "last_message_id": t.get("last_message_id")}
                for t in threads
            ],
            "forums": [c["id"] for c in guild.get("channels", []) if c["type"] in (15, 16)],
            "thread_shape": shape(threads[0]) if threads and args.shape else None,
        })
    return result


def cmd_forum_threads(args: argparse.Namespace) -> Any:
    """A forum's posts as its web client lists them: newest activity first."""
    query = urllib.parse.urlencode({"archived": "true", "sort_by": "last_message_time", "sort_order": "desc", "limit": args.limit, "tag_setting": "match_some", "offset": 0})
    page = api("GET", f"/channels/{args.channel}/threads/search?{query}")
    if args.shape:
        return shape(page)
    return {
        "total": page.get("total_results"),
        "has_more": page.get("has_more"),
        "threads": [{"id": t["id"], "type": t["type"], "name_length": len(t.get("name") or ""), "joined": any(m.get("id") == t["id"] for m in page.get("members", [])), "last_message_id": t.get("last_message_id"), "archived": (t.get("thread_metadata") or {}).get("archived")} for t in page.get("threads", [])],
    }


def cmd_stickers(args: argparse.Namespace) -> Any:
    """Standard sticker packs and each guild's stickers, by format (1 PNG, 2 APNG, 3 Lottie, 4 GIF)."""
    packs = api("GET", "/sticker-packs").get("sticker_packs", [])
    data = ready_payload()
    return {
        "standard_packs": [{"id": p["id"], "name": p["name"], "count": len(p["stickers"]), "formats": dict(collections.Counter(s["format_type"] for s in p["stickers"]))} for p in packs],
        "guild_stickers": {g["id"]: dict(collections.Counter(s["format_type"] for s in g.get("stickers", []))) for g in data.get("guilds", [])},
        "sticker_shape": shape(packs[0]["stickers"][0]) if packs and args.shape else None,
    }


def cmd_upload(args: argparse.Namespace) -> Any:
    """The web client's upload: reserve an upload URL, PUT the bytes there, then post a message naming it."""
    guard(args.channel, args.expect_name)
    path = Path(args.file)
    data = path.read_bytes()
    reserved = api("POST", f"/channels/{args.channel}/attachments", {"files": [{"filename": path.name, "file_size": len(data), "id": "0", "is_clip": False}]})
    attachment = reserved["attachments"][0]
    put = urllib.request.Request(attachment["upload_url"], data=data, method="PUT", headers={"Content-Type": mimetypes.guess_type(path.name)[0] or "application/octet-stream", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(put, timeout=60) as response:
        put_status = response.status
    body = {
        "content": args.text or "",
        "nonce": str((int(time.time() * 1000) - 1420070400000) << 22),
        "channel_id": args.channel,
        "type": 0,
        "sticker_ids": [],
        "attachments": [{"id": "0", "filename": path.name, "uploaded_filename": attachment["upload_filename"]}],
    }
    message = api("POST", f"/channels/{args.channel}/messages", body)
    return {"reserve_keys": sorted(attachment.keys()), "put_status": put_status, "id": message["id"], "attachments": [a.get("content_type") for a in message.get("attachments", [])]}


def cmd_send_sticker(args: argparse.Namespace) -> Any:
    guard(args.channel, args.expect_name)
    body = {"content": "", "nonce": str((int(time.time() * 1000) - 1420070400000) << 22), "tts": False, "flags": 0, "sticker_ids": [args.sticker]}
    message = api("POST", f"/channels/{args.channel}/messages", body)
    return {"id": message["id"], "stickers": [s.get("format_type") for s in message.get("sticker_items", [])]}


def cmd_open_dm(args: argparse.Namespace) -> Any:
    """The DM channel with a user, created if there is none (sends no message)."""
    channel = api("POST", "/users/@me/channels", {"recipients": [args.user]})
    return {"id": channel["id"], "type": channel["type"], "recipients": [r.get("username") for r in channel.get("recipients", [])], "last_message_id": channel.get("last_message_id")}


def cmd_profile(args: argparse.Namespace) -> Any:
    """A user's profile as the web client's profile popout loads it."""
    profile = api("GET", f"/users/{args.user}/profile?with_mutual_guilds=true&with_mutual_friends=true")
    return shape(profile) if args.shape else {"user": {k: profile.get("user", {}).get(k) for k in ("id", "username", "global_name")}, "mutual_guilds": len(profile.get("mutual_guilds", [])), "bio_length": len((profile.get("user_profile") or {}).get("bio") or "")}


def cmd_raw(args: argparse.Namespace) -> Any:
    if args.method != "GET":
        raise SystemExit("raw is GET only")
    return shape(api("GET", args.path))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("me")
    sub.add_parser("guilds")
    p = sub.add_parser("channels")
    p.add_argument("--guild", required=True)
    p = sub.add_parser("dms")
    p.add_argument("--limit", type=int, default=30)
    for name in ("history", "around"):
        p = sub.add_parser(name)
        p.add_argument("--channel", required=True)
        p.add_argument("--limit", type=int, default=20)
        p.add_argument("--show-text", action="store_true", help="Print text of the token user's own messages")
        if name == "history":
            p.add_argument("--before")
            p.add_argument("--after")
        else:
            p.add_argument("--message", required=True)
    for name in ("send", "edit", "delete", "react", "typing"):
        p = sub.add_parser(name)
        p.add_argument("--channel", required=True)
        p.add_argument("--expect-name", required=True)
        if name in ("send", "edit"):
            p.add_argument("--text", required=True)
        if name in ("edit", "delete", "react"):
            p.add_argument("--message", required=True)
        if name == "send":
            p.add_argument("--reply-to")
        if name == "react":
            p.add_argument("--emoji", required=True)
            p.add_argument("--remove", action="store_true")
    p = sub.add_parser("ack")
    p.add_argument("--channel", required=True)
    p.add_argument("--message", required=True)
    p = sub.add_parser("ready")
    p.add_argument("--capabilities", type=int, default=0)
    p.add_argument("--limit", type=int, default=5)
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("follow")
    p.add_argument("--capabilities", type=int, default=0)
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("threads")
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("forum-threads")
    p.add_argument("--channel", required=True)
    p.add_argument("--limit", type=int, default=25)
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("stickers")
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("upload")
    p.add_argument("--channel", required=True)
    p.add_argument("--expect-name", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--text")
    p = sub.add_parser("send-sticker")
    p.add_argument("--channel", required=True)
    p.add_argument("--expect-name", required=True)
    p.add_argument("--sticker", required=True)
    p = sub.add_parser("open-dm")
    p.add_argument("--user", required=True)
    p = sub.add_parser("profile")
    p.add_argument("--user", required=True)
    p.add_argument("--shape", action="store_true")
    p = sub.add_parser("raw")
    p.add_argument("method")
    p.add_argument("path")

    args = parser.parse_args()
    result = globals()[f"cmd_{args.command.replace('-', '_')}"](args)
    if result is not None:
        print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
