#!/usr/bin/env python3
"""Probe an Apron Chat server (https://github.com/shazow/apron) over WebSocket.

Dependency-free: implements the minimal RFC 6455 client framing needed for
Apron's JSON text frames. Never prints bearer tokens; pass --token-file to keep
a guest token between runs.

Examples:
  scripts/apron-web-client.py hello wss://server.apron.chat/
  scripts/apron-web-client.py rooms wss://server.apron.chat/ --name probe
  scripts/apron-web-client.py history wss://server.apron.chat/ --room general --limit 20
  scripts/apron-web-client.py send wss://server.apron.chat/ --room general --text "hi"
  scripts/apron-web-client.py seed ws://127.0.0.1:8765/ --count 999   # local load-test data
  scripts/apron-web-client.py upload ws://127.0.0.1:8080/ws --file photo.jpg   # needs embed:upload
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import random
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class WebSocket:
    def __init__(self, url: str, timeout: float = 15) -> None:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("ws", "wss"):
            raise SystemExit(f"unsupported scheme: {parsed.scheme}")
        host = parsed.hostname or ""
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        raw = socket.create_connection((host, port), timeout=timeout)
        if parsed.scheme == "wss":
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        self.sock = raw
        self.buffer = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: apron-probe/1\r\n\r\n"
        )
        self.sock.sendall(request.encode())
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
                raise EOFError
            if opcode == 0x9:
                self.sock.sendall(bytes([0x8A, 0x80]) + secrets.token_bytes(4))
                continue
            if opcode in (0x1, 0x0):
                message += payload
                if b0 & 0x80:
                    return message.decode()

    def close(self) -> None:
        try:
            self.sock.sendall(bytes([0x88, 0x80]) + secrets.token_bytes(4))
        finally:
            self.sock.close()


class Session:
    def __init__(self, url: str, verbose: bool) -> None:
        self.ws = WebSocket(url)
        self.verbose = verbose
        self.counter = 0
        self.server: dict[str, Any] | None = None
        self.notifications: list[dict[str, Any]] = []

    def log(self, direction: str, frame: dict[str, Any]) -> None:
        if not self.verbose:
            return
        print(direction, json.dumps(redact(frame), ensure_ascii=False), file=sys.stderr)

    def next_frame(self) -> dict[str, Any]:
        frame = json.loads(self.ws.recv_text())
        self.log("<-", frame)
        if frame.get("method") == "server":
            self.server = frame.get("params")
        return frame

    def wait_server(self) -> dict[str, Any]:
        while self.server is None:
            frame = self.next_frame()
            if "id" not in frame:
                self.notifications.append(frame)
        return self.server

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.counter += 1
        request_id = f"p{self.counter}-{secrets.token_hex(3)}"
        frame = {"method": method, "id": request_id, "params": params}
        self.log("->", frame)
        self.ws.send_text(json.dumps(frame))
        while True:
            reply = self.next_frame()
            if reply.get("id") == request_id:
                if "error" in reply:
                    raise SystemExit(f"{method} failed: {reply['error']}")
                return reply.get("result", {})
            self.notifications.append(reply)

    def drain(self, seconds: float) -> None:
        self.ws.sock.settimeout(seconds)
        try:
            while True:
                self.notifications.append(self.next_frame())
        except (TimeoutError, socket.timeout, EOFError):
            pass


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: ("<redacted>" if k == "token" else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def authenticate(session: Session, args: argparse.Namespace) -> dict[str, Any]:
    server = session.wait_server()
    token_path = Path(args.token_file) if args.token_file else None
    token = token_path.read_text().strip() if token_path and token_path.exists() else None
    schemes = set(server.get("auth", [])) | set(server.get("signup", []))
    params: dict[str, Any] = {"agent": "apron-probe/1"}
    if args.name:
        params["name"] = args.name
    if token and "token" in schemes:
        params.update(scheme="token", token=token)
    elif "guest" in schemes:
        params["scheme"] = "guest"
    else:
        raise SystemExit(f"no usable auth scheme in {sorted(schemes)}")
    result = session.request("auth", params)
    if result.get("token") and token_path:
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(result["token"])
        os.chmod(token_path, 0o600)
    return result


def print_json(value: Any) -> None:
    print(json.dumps(redact(value), indent=2, ensure_ascii=False))


def cmd_hello(session: Session, args: argparse.Namespace) -> None:
    print_json(session.wait_server())
    session.drain(args.wait)
    print_json({"notifications": session.notifications})


def cmd_rooms(session: Session, args: argparse.Namespace) -> None:
    auth = authenticate(session, args)
    caps = session.server.get("capabilities", [])
    output: dict[str, Any] = {"server": session.server, "auth": auth}
    if "rooms" in caps:
        output["room_list"] = session.request("room_list", {"filter": "all", "members": args.members})
    session.drain(args.wait)
    output["notifications"] = session.notifications
    print_json(output)


def cmd_history(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    params: dict[str, Any] = {"room_id": args.room, "limit": args.limit}
    if args.after:
        params["after"] = args.after
    print_json(session.request("history", params))


def cmd_join(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    print_json(session.request(args.leave and "room_leave" or "room_join", {"room_id": args.room}))
    session.drain(args.wait)
    print_json({"notifications": session.notifications})


def og_image(url: str, size: str) -> dict[str, Any]:
    """An `og.image`; `--image-size none` leaves out the size, as servers may (§4.8)."""
    if size == "none":
        return {"url": url}
    width, height = (int(v) for v in size.split("x"))
    return {"url": url, "width": width, "height": height}


def cmd_send(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    params: dict[str, Any] = {"body": {"text": args.text, "format": args.format}}
    if args.room:
        params["room_id"] = args.room
    if args.reply_to:
        params["reply_to"] = {"message_id": args.reply_to}
    if args.image_url:
        # A finished upload embed with an image preview (§4.8.4), for testing clients against servers that
        # pass embeds through without storing files, such as the js-minimal reference server.
        params["body"]["embeds"] = [{
            "kind": "upload", "embed_id": f"e{int(time.time() * 1000)}", "title": args.image_url.rsplit("/", 1)[-1],
            "url": args.image_url, "og": {"image": og_image(args.image_url, args.image_size)},
        }]
    if args.link_url:
        # A link preview (§4.8.2): title, description and optionally an image, as a server would unfurl it.
        og: dict[str, Any] = {"title": args.link_title or args.link_url, "description": args.link_description}
        if args.link_image:
            og["image"] = og_image(args.link_image, args.image_size)
        embeds = params["body"].setdefault("embeds", [])
        embeds.append({"kind": "link", "url": args.link_url, "og": {k: v for k, v in og.items() if v}})
    print_json(session.request("message", params))
    print_json({"notifications": session.notifications})


SEED_WORDS = (
    "deploy build cache room thread token server client frame snapshot history reply "
    "the a of and to in is that it for on with as was at by this we you they"
).split()


def seed_text(rng: random.Random, index: int) -> str:
    words = [rng.choice(SEED_WORDS) for _ in range(rng.choice([3, 6, 12, 25, 60]))]
    if index % 5 == 0:
        words[0] = f"**{words[0]}**"
    if index % 7 == 0:
        words[-1] = f"`{words[-1]}`"
    if index % 11 == 0:
        words.append("https://example.com/apron")
    return f"#{index} " + " ".join(words)


def cmd_seed(session: Session, args: argparse.Namespace) -> None:
    """Posts deterministic, varied markdown messages (some replies) for local load testing."""
    authenticate(session, args)
    rng = random.Random(args.random_seed)
    message_ids: list[str] = []
    for index in range(args.count):
        params: dict[str, Any] = {"body": {"text": seed_text(rng, index), "format": "markdown"}}
        if args.room:
            params["room_id"] = args.room
        if message_ids and index % 4 == 0:
            params["reply_to"] = {"message_id": rng.choice(message_ids[-20:])}
        result = session.request("message", params)
        if result.get("message_id"):
            message_ids.append(result["message_id"])
        if args.interval:
            time.sleep(args.interval)
    print_json({"posted": len(message_ids)})


def cmd_react(session: Session, args: argparse.Namespace) -> None:
    """Sets the caller's complete emoji set on one message (§4.7); an empty set clears it."""
    authenticate(session, args)
    print_json(session.request("reactions", {"message_id": args.message, "emojis": args.emoji}))
    session.drain(args.wait)
    print_json({"notifications": [n for n in session.notifications if n.get("method") == "reactions"]})


def cmd_upload(session: Session, args: argparse.Namespace) -> None:
    """Posts a message with one `upload` embed, then PUTs the file to its write_url (§4.8.3)."""
    authenticate(session, args)
    path = Path(args.file)
    params: dict[str, Any] = {
        "body": {"text": args.text, "format": "markdown", "embeds": [{"kind": "upload", "title": path.name}]}
    }
    if args.room:
        params["room_id"] = args.room
    result = session.request("message", params)
    write_url = (result.get("embeds") or [{}])[0].get("write_url")
    if not write_url:
        raise SystemExit(f"no write_url in result: {result}")
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    request = urllib.request.Request(write_url, data=path.read_bytes(), method="PUT", headers={"Content-Type": mime})
    with urllib.request.urlopen(request, timeout=60) as response:
        status = response.status
    session.drain(args.wait)
    print_json({"message_id": result.get("message_id"), "put_status": status, "notifications": session.notifications})


def cmd_typing(session: Session, args: argparse.Namespace) -> None:
    """Sends `activity.typing` (seconds), then `typing: 0` after --hold seconds, and prints any activity frames (§4.6)."""
    authenticate(session, args)
    session.ws.send_text(json.dumps({"method": "activity", "params": {"room_id": args.room, "typing": args.seconds}}))
    session.drain(args.hold)
    session.ws.send_text(json.dumps({"method": "activity", "params": {"room_id": args.room, "typing": 0}}))
    session.drain(args.wait)
    print_json({"notifications": [n for n in session.notifications if n.get("method") == "activity"]})


def cmd_typing_rate(session: Session, args: argparse.Namespace) -> None:
    """Sends --count `activity.typing` frames --interval seconds apart and prints every other frame that comes
    back, tagged with the frame that preceded it, to find a server's typing rate limit and how it reports it
    (§4.6). --stops alternates start and stop frames."""
    authenticate(session, args)
    session.notifications.clear()
    start = time.time()
    replies = []

    def collect(after: int) -> None:
        for frame in session.notifications:
            if frame.get("method") in ("activity", "user"):
                continue
            replies.append({"after_frame": after, "at": round(time.time() - start, 1), "frame": redact(frame)})
        session.notifications.clear()

    for index in range(args.count):
        typing = 0 if args.stops and index % 2 else args.seconds
        session.ws.send_text(json.dumps({"method": "activity", "params": {"room_id": args.room, "typing": typing}}))
        session.drain(args.interval)
        collect(index + 1)
    session.drain(args.wait)
    collect(args.count)
    print_json({"sent": args.count, "interval": args.interval, "stops": args.stops, "replies": replies})


def cmd_listen(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        session.drain(min(5, deadline - time.time()))
        for frame in session.notifications:
            print(json.dumps(redact(frame), ensure_ascii=False))
        session.notifications.clear()


def main() -> None:
    parser = argparse.ArgumentParser(description="Probe an Apron Chat server.")
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name: str, handler: Any) -> argparse.ArgumentParser:
        p = sub.add_parser(name)
        p.add_argument("url")
        p.add_argument("--name", default="apron-probe")
        p.add_argument("--token-file", default="logs/apron-probe-token")
        p.add_argument("--wait", type=float, default=2)
        p.add_argument("-v", "--verbose", action="store_true")
        p.set_defaults(handler=handler)
        return p

    add("hello", cmd_hello)
    add("rooms", cmd_rooms).add_argument("--members", action="store_true")
    history = add("history", cmd_history)
    history.add_argument("--room", required=True)
    history.add_argument("--limit", type=int, default=20)
    history.add_argument("--after")
    join = add("join", cmd_join)
    join.add_argument("--room", required=True)
    join.add_argument("--leave", action="store_true")
    send = add("send", cmd_send)
    send.add_argument("--room")
    send.add_argument("--text", required=True)
    send.add_argument("--format", choices=["plain", "markdown"], default="plain")
    send.add_argument("--reply-to")
    send.add_argument("--image-url")
    send.add_argument("--image-size", default="1200x800", help="WIDTHxHEIGHT of --image-url or --link-image, or none")
    send.add_argument("--link-url", help="attach a link preview embed")
    send.add_argument("--link-title")
    send.add_argument("--link-description")
    send.add_argument("--link-image", help="og.image URL of the link preview")
    react = add("react", cmd_react)
    react.add_argument("--message", required=True)
    react.add_argument("--emoji", action="append", default=[])
    seed = add("seed", cmd_seed)
    seed.add_argument("--room")
    seed.add_argument("--count", type=int, default=100)
    seed.add_argument("--interval", type=float, default=0)
    seed.add_argument("--random-seed", type=int, default=1)
    upload = add("upload", cmd_upload)
    upload.add_argument("--room")
    upload.add_argument("--file", required=True)
    upload.add_argument("--text", default="")
    typing = add("typing", cmd_typing)
    typing.add_argument("--room", required=True)
    typing.add_argument("--seconds", type=int, default=8)
    typing.add_argument("--hold", type=float, default=3)
    rate = add("typing-rate", cmd_typing_rate)
    rate.add_argument("--room", default="general")
    rate.add_argument("--count", type=int, default=12)
    rate.add_argument("--interval", type=float, default=1)
    rate.add_argument("--seconds", type=int, default=8)
    rate.add_argument("--stops", action="store_true")
    add("listen", cmd_listen)

    args = parser.parse_args()
    session = Session(args.url, args.verbose)
    try:
        args.handler(session, args)
    finally:
        session.ws.close()


if __name__ == "__main__":
    main()
