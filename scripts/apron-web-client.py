#!/usr/bin/env python3
"""Probe an Apron Chat server (https://github.com/shazow/apron) over WebSocket.

Dependency-free: implements the minimal RFC 6455 client framing needed for
Apron's JSON text frames. Never prints bearer tokens; pass --token-file to keep
a guest token between runs.

Examples:
  scripts/apron-web-client.py hello wss://server.apron.chat/
  scripts/apron-web-client.py limits wss://server.apron.chat/ --token-file ""   # docs/limits.md: status probe, pong, retry_after
  scripts/apron-web-client.py rooms wss://server.apron.chat/ --name probe
  scripts/apron-web-client.py history wss://server.apron.chat/ --room general --limit 20
  scripts/apron-web-client.py send wss://server.apron.chat/ --room general --text "hi"
  scripts/apron-web-client.py seed ws://127.0.0.1:8765/ --count 999   # local load-test data
  scripts/apron-web-client.py upload ws://127.0.0.1:8080/ws --file photo.jpg   # needs embed:upload
  scripts/apron-web-client.py email-signup ws://127.0.0.1:8090/ws --email alice@example.com --user-id alice --name Alice --token-file logs/apron-local/tokens/alice
  scripts/apron-web-client.py push-capture --port 8099   # local push endpoint that decrypts what it receives
  scripts/apron-web-client.py push-register ws://127.0.0.1:8080/ws --endpoint http://127.0.0.1:8099/p --wake mentions
  scripts/apron-web-client.py mute ws://127.0.0.1:8080/ws --room general
  scripts/apron-web-client.py emoji wss://server.apron.chat/ --scan "12:30:apron::SideTable:" --images
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import random
import re
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.error
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
        params: dict[str, Any] = {"filter": "all", "members": args.members}
        # One room, joined or not, as a link preview shows it before joining (§4.2.1).
        if args.room_id:
            params["room_id"] = args.room_id
        output["room_list"] = session.request("room_list", params)
    session.drain(args.wait)
    output["notifications"] = session.notifications
    print_json(output)


def connection_status(url: str) -> dict[str, Any]:
    """The server's `?apron_connection_status=1` answer: why an upgrade would be refused, without opening a socket.
    It counts as a connection attempt, so call it after a failure, not before every connect (docs/limits.md)."""
    parsed = urllib.parse.urlparse(url)
    scheme = "https" if parsed.scheme == "wss" else "http"
    query = "apron_connection_status=1" + (f"&{parsed.query}" if parsed.query else "")
    probe = urllib.parse.urlunparse((scheme, parsed.netloc, parsed.path or "/", "", query, ""))
    request = urllib.request.Request(probe, headers={"User-Agent": "apron-probe/1"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            status, headers, body = response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        status, headers, body = error.code, error.headers, error.read()
    return {
        "status": status,
        "retry_after": headers.get("Retry-After"),
        "from_apron": headers.get("Apron-Connection-Status") == "1",
        "body": json.loads(body or b"null"),
    }


def cmd_limits(session: Session, args: argparse.Namespace) -> None:
    """What docs/limits.md says a client should handle: the connection-status probe, the guest's write permission,
    the pong to an exact ping, and the shape of a `retry_after` error (room_list allows 6 a minute per account)."""
    output: dict[str, Any] = {"connection_status": connection_status(args.url)}
    auth = authenticate(session, args)
    output["you_ext"] = (auth.get("you") or {}).get("ext")
    started = time.monotonic()
    session.ws.send_text('{"method":"ping"}')
    while True:
        frame = session.next_frame()
        if frame.get("method") == "pong":
            output["pong"] = {"frame": frame, "elapsed_s": round(time.monotonic() - started, 3)}
            break
        session.notifications.append(frame)
    for attempt in range(1, args.room_list_count + 1):
        session.counter += 1
        request_id = f"rl{session.counter}"
        session.ws.send_text(json.dumps({"method": "room_list", "id": request_id, "params": {"filter": "all"}}))
        reply = session.next_frame()
        while reply.get("id") != request_id:
            session.notifications.append(reply)
            reply = session.next_frame()
        if "error" in reply:
            output["room_list_refused"] = {"attempt": attempt, "error": reply["error"]}
            break
    print_json(output)


def cmd_history(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    params: dict[str, Any] = {"room_id": args.room, "limit": args.limit}
    if args.after:
        params["after"] = args.after
    if args.before:
        params["before"] = args.before
    started = time.time()
    result = session.request("history", params)
    # How long the server took, for diagnosing slow reply-target fetches (`--after X --before X --limit 1`).
    result["_elapsed_s"] = round(time.time() - started, 3)
    print_json(result)


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
    if args.mention:
        params["body"]["mentions"] = args.mention
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
            kind = live_message_kind(frame)
            if kind:
                # The app updates a Chats row from a new message alone, and reads history for the rest.
                print(json.dumps({"live_message": kind}))
        session.notifications.clear()


def live_message_kind(frame: dict) -> str | None:
    """A live `message` frame is new when its log_id is its message_id (§4.3.1); edits and moves carry a later one."""
    if frame.get("method") != "message":
        return None
    params = frame.get("params") or {}
    if not params.get("message_id"):
        return "transient"
    if params.get("deleted"):
        return "delete"
    return "new" if params.get("log_id") in (None, params["message_id"]) else "edit"


# --- Push (§4.9): dependency-free P-256, HKDF and AES-128-GCM for Web Push payloads (RFC 8291) ---

P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_A = P256_P - 3
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
P256_G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)


def ec_add(p: tuple[int, int] | None, q: tuple[int, int] | None) -> tuple[int, int] | None:
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % P256_P == 0:
        return None
    if p == q:
        slope = (3 * p[0] * p[0] + P256_A) * pow(2 * p[1], -1, P256_P) % P256_P
    else:
        slope = (q[1] - p[1]) * pow(q[0] - p[0], -1, P256_P) % P256_P
    x = (slope * slope - p[0] - q[0]) % P256_P
    return x, (slope * (p[0] - x) - p[1]) % P256_P


def ec_mul(k: int, point: tuple[int, int]) -> tuple[int, int]:
    result = None
    while k:
        if k & 1:
            result = ec_add(result, point)
        point = ec_add(point, point)
        k >>= 1
    assert result is not None
    return result


def ec_encode(point: tuple[int, int]) -> bytes:
    return b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")


def ec_decode(data: bytes) -> tuple[int, int]:
    if len(data) != 65 or data[0] != 4:
        raise SystemExit("expected an uncompressed P-256 point")
    x, y = int.from_bytes(data[1:33], "big"), int.from_bytes(data[33:], "big")
    if (y * y - (x * x * x + P256_A * x + P256_B)) % P256_P:
        raise SystemExit("point is not on P-256")
    return x, y


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hkdf(salt: bytes, ikm: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


AES_SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)


def aes128_encrypt_block(key: bytes, block: bytes) -> bytes:
    def xtime(b: int) -> int:
        return ((b << 1) ^ 0x1B) & 0xFF if b & 0x80 else b << 1

    words = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        word = list(words[i - 1])
        if i % 4 == 0:
            word = [AES_SBOX[b] for b in word[1:] + word[:1]]
            word[0] ^= rcon
            rcon = xtime(rcon)
        words.append([a ^ b for a, b in zip(words[i - 4], word)])
    state = [b ^ k for b, k in zip(block, sum(words[0:4], []))]
    for round_ in range(1, 11):
        state = [AES_SBOX[b] for b in state]
        state = [state[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if round_ < 10:
            mixed = []
            for c in range(4):
                a = state[4 * c:4 * c + 4]
                mixed += [
                    xtime(a[0]) ^ xtime(a[1]) ^ a[1] ^ a[2] ^ a[3],
                    a[0] ^ xtime(a[1]) ^ xtime(a[2]) ^ a[2] ^ a[3],
                    a[0] ^ a[1] ^ xtime(a[2]) ^ xtime(a[3]) ^ a[3],
                    xtime(a[0]) ^ a[0] ^ a[1] ^ a[2] ^ xtime(a[3]),
                ]
            state = mixed
        state = [b ^ k for b, k in zip(state, sum(words[4 * round_:4 * round_ + 4], []))]
    return bytes(state)


def gcm_multiply(x: int, y: int) -> int:
    result = 0
    for i in range(127, -1, -1):
        if (y >> i) & 1:
            result ^= x
        x = (x >> 1) ^ (0xE1 << 120) if x & 1 else x >> 1
    return result


def aes128_gcm_decrypt(key: bytes, nonce: bytes, data: bytes) -> bytes:
    ciphertext, tag = data[:-16], data[-16:]
    h = int.from_bytes(aes128_encrypt_block(key, bytes(16)), "big")
    counter = int.from_bytes(nonce + b"\x00\x00\x00\x01", "big")
    plaintext = bytearray()
    for offset in range(0, len(ciphertext), 16):
        keystream = aes128_encrypt_block(key, (counter + 1 + offset // 16).to_bytes(16, "big"))
        plaintext += bytes(a ^ b for a, b in zip(ciphertext[offset:offset + 16], keystream))
    ghash = 0
    padded = ciphertext + bytes(-len(ciphertext) % 16)
    for offset in range(0, len(padded), 16):
        ghash = gcm_multiply(ghash ^ int.from_bytes(padded[offset:offset + 16], "big"), h)
    ghash = gcm_multiply(ghash ^ (len(ciphertext) * 8), h)
    expected = (ghash ^ int.from_bytes(aes128_encrypt_block(key, counter.to_bytes(16, "big")), "big")).to_bytes(16, "big")
    if not hmac.compare_digest(expected, tag):
        raise SystemExit("aes128gcm tag mismatch: wrong keys or a corrupted body")
    return bytes(plaintext)


def push_keys(path: Path) -> dict[str, str]:
    """The client half of a registration: a P-256 key pair, the auth secret, and a push_id (kept in logs/)."""
    if path.exists():
        return json.loads(path.read_text())
    private = secrets.randbelow(P256_N - 1) + 1
    keys = {
        "private": b64url(private.to_bytes(32, "big")),
        "p256dh": b64url(ec_encode(ec_mul(private, P256_G))),
        "auth": b64url(secrets.token_bytes(16)),
        "push_id": b64url(secrets.token_bytes(12)),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(keys))
    os.chmod(path, 0o600)
    return keys


def webpush_decrypt(body: bytes, keys: dict[str, str]) -> bytes:
    """Decrypts one aes128gcm record (RFC 8188) with the RFC 8291 Web Push key schedule."""
    salt, record_size, key_id_length = body[:16], int.from_bytes(body[16:20], "big"), body[20]
    sender_public = body[21:21 + key_id_length]
    record = body[21 + key_id_length:]
    if len(record) > record_size:
        raise SystemExit("more than one record; Apron payloads fit one")
    private = int.from_bytes(b64url_decode(keys["private"]), "big")
    shared = ec_mul(private, ec_decode(sender_public))[0].to_bytes(32, "big")
    receiver_public = b64url_decode(keys["p256dh"])
    ikm = hkdf(b64url_decode(keys["auth"]), shared, b"WebPush: info\x00" + receiver_public + sender_public, 32)
    cek = hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)
    padded = aes128_gcm_decrypt(cek, nonce, record).rstrip(b"\x00")
    if not padded.endswith(b"\x02"):
        raise SystemExit("missing last-record delimiter")
    return padded[:-1]


def cmd_email_signup(session: Session, args: argparse.Namespace) -> None:
    """Signs in by email (§4.11) against a local server run with `--email.sender log`, reading the code from
    --code-log, and keeps the account's bearer token in --token-file. A new address creates the account with
    --user-id and --name; a known one signs in to it."""
    session.wait_server()
    if "email" not in session.server.get("auth", []):
        raise SystemExit("this server has no email sign-in; run it with --email.enable --email.sender log")
    log = Path(args.code_log)
    offset = log.stat().st_size if log.exists() else 0
    session.request("auth", {"scheme": "email", "email": args.email})
    code = None
    deadline = time.time() + 15
    while code is None and time.time() < deadline:
        time.sleep(0.3)
        with log.open() as f:
            f.seek(offset)
            for line in f:
                if "email sign-in code" in line and f"to={args.email}" in line:
                    code = line.split(" code=", 1)[1].split()[0]
    if code is None:
        raise SystemExit(f"no sign-in code for {args.email} in {log}")
    params: dict[str, Any] = {"scheme": "email", "token": code, "agent": "apron-probe/1"}
    if args.user_id:
        params["user_id"] = args.user_id
    if args.name:
        params["name"] = args.name
    result = session.request("auth", params)
    token_path = Path(args.token_file)
    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(result["token"])
    os.chmod(token_path, 0o600)
    output: dict[str, Any] = {"you": result.get("you"), "token_file": str(token_path)}
    if args.print_token:
        output["token"] = result["token"]
    print(json.dumps(output, indent=2, ensure_ascii=False))


def cmd_me(session: Session, args: argparse.Namespace) -> None:
    """Updates the caller's profile with `me` (§3.3.2): --avatar sets the avatar URL ("" removes it)."""
    authenticate(session, args)
    params: dict[str, Any] = {}
    if args.avatar is not None:
        params["avatar"] = args.avatar
    if args.display_name is not None:
        params["name"] = args.display_name
    print_json(session.request("me", params))


def cmd_room_create(session: Session, args: argparse.Namespace) -> None:
    """Creates a room with `room_set` (§4.2.4) and adds --add users with `room_join`. A private room without a
    title, with one other member, is a DM."""
    authenticate(session, args)
    params: dict[str, Any] = {}
    if args.title:
        params["title"] = args.title
    if args.private:
        params["private"] = True
    room_id = session.request("room_set", params)["room_id"]
    for user_id in args.add:
        session.request("room_join", {"room_id": room_id, "user_id": user_id})
    print_json({"room_id": room_id})


def direct_room_with(rooms: list[dict[str, Any]], you: str, user_id: str) -> dict[str, Any] | None:
    """apron-web's `directRoomWith`: a joined top-level untitled private room whose complete member list is
    exactly you and `user_id`."""
    for room in rooms:
        if not room.get("private") or room.get("parent_room_id") or (room.get("title") or "").strip():
            continue
        if room.get("members") is None or room.get("member_count") is not None:
            continue
        if {member["user_id"] for member in room["members"]} == {you, user_id}:
            return room
    return None


def cmd_dm(session: Session, args: argparse.Namespace) -> None:
    """Opens the DM with --user: the existing direct room from `room_list` (§4.2.1), else a new untitled private
    room (`room_set` with `private: true`, §4.2.4), checked for `private: true` in its `room_update` `joined`
    record before `room_join` adds the user (§4.2.2)."""
    you = authenticate(session, args)["you"]["user_id"]
    listing = session.request("room_list", {"filter": "joined", "members": True})
    existing = direct_room_with(listing.get("joined") or [], you, args.user)
    if existing:
        print_json({"room_id": existing["room_id"], "created": False})
        return
    room_id = session.request("room_set", {"private": True})["room_id"]

    def joined_record() -> dict[str, Any] | None:
        for frame in session.notifications:
            if frame.get("method") == "room_update":
                for room in frame["params"].get("joined") or []:
                    if room["room_id"] == room_id:
                        return room
        return None

    # The record usually arrives before the result; otherwise wait for it.
    if joined_record() is None:
        session.drain(2)
    joined = joined_record()
    if not joined or not joined.get("private"):
        raise SystemExit(f"room {room_id} came back without private: true: {joined}")
    session.request("room_join", {"room_id": room_id, "user_id": args.user})
    print_json({"room_id": room_id, "created": True, "joined_record": joined})


def cmd_push_register(session: Session, args: argparse.Namespace) -> None:
    """Registers --endpoint for push (§4.9.1) with the client keys in --keys-file; prints server.push first."""
    authenticate(session, args)
    print_json({"server.push": session.server.get("push")})
    keys = push_keys(Path(args.keys_file))
    params: dict[str, Any] = {
        "kind": args.kind, "url": args.endpoint, "push_id": keys["push_id"],
        "keys": {"p256dh": keys["p256dh"], "auth": keys["auth"]},
    }
    if args.wake is not None:
        params["wake"] = args.wake
    print_json(session.request("push_register", params))


def cmd_push_unregister(session: Session, args: argparse.Namespace) -> None:
    authenticate(session, args)
    print_json(session.request("push_unregister", {"url": args.endpoint}))


def cmd_mute(session: Session, args: argparse.Namespace) -> None:
    """Sets a room mute (or a mute everywhere without --room) with `status` (§4.5.3), and prints the mutes after."""
    authenticate(session, args)
    params: dict[str, Any] = {"mute": False if args.off else True}
    if args.room:
        params["room_id"] = args.room
    print_json(session.request("status", params))
    session.drain(args.wait)
    print_json({"status": [n for n in session.notifications if n.get("method") == "status"]})


EMOJI_KEY = re.compile(r"^:[A-Za-z0-9_+-]+:$")


def emoji_keys(text: str, catalog: dict[str, Any]) -> list[tuple[int, str]]:
    """Custom emoji keys in text, scanning as EXTENSIONS.md ext:emoji § Text says: at each `:`, a key the catalog
    has up to the next `:` renders and the scan continues after it, otherwise it continues at that next `:`."""
    found = []
    start = text.find(":")
    while start != -1:
        end = text.find(":", start + 1)
        if end == -1:
            break
        key = text[start : end + 1]
        if key in catalog:
            found.append((start, key))
            start = text.find(":", end + 1)
        else:
            start = end
    return found


def cmd_emoji(session: Session, args: argparse.Namespace) -> None:
    """The ext:emoji catalog: fetched from `catalog_url`, each key checked, and each image's type and size."""
    server = session.wait_server()
    if args.sign_in:
        authenticate(session, args)
        session.drain(args.wait)
        server = next((n["params"] for n in reversed(session.notifications) if n.get("method") == "server"), server)
    if "ext:emoji" not in server.get("capabilities", []):
        raise SystemExit("server does not list ext:emoji")
    catalog_url = server.get("ext", {}).get("emoji", {}).get("catalog_url")
    if not isinstance(catalog_url, str):
        raise SystemExit("no ext.emoji.catalog_url")
    with urllib.request.urlopen(urllib.request.Request(catalog_url, headers={"User-Agent": "apron-probe/1"}), timeout=15) as response:
        headers = {k: response.headers.get(k) for k in ("Content-Type", "Cache-Control", "ETag")}
        catalog = json.load(response)
    output: dict[str, Any] = {"catalog_url": catalog_url, "headers": headers, "count": len(catalog), "emoji": {}}
    for key, emoji in catalog.items():
        entry: dict[str, Any] = {"valid_key": bool(EMOJI_KEY.match(key)), **emoji}
        if args.images and isinstance(emoji, dict) and isinstance(emoji.get("url"), str):
            with urllib.request.urlopen(urllib.request.Request(emoji["url"], method="HEAD", headers={"User-Agent": "apron-probe/1"}), timeout=15) as image:
                entry["image"] = {k: image.headers.get(k) for k in ("Content-Type", "Content-Length", "Cache-Control")}
        output["emoji"][key] = entry
    if args.scan is not None:
        output["scan"] = {"text": args.scan, "keys": emoji_keys(args.scan, catalog)}
    print_json(output)


def cmd_push_capture(args: argparse.Namespace) -> None:
    """Serves a local push endpoint (with a server run with --push.allow-insecure), logging each POST's headers
    and decrypting its body with --keys-file."""
    import http.server

    keys = json.loads(Path(args.keys_file).read_text())
    out = Path("logs/apron-push-capture")
    out.mkdir(parents=True, exist_ok=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            stamp = int(time.time() * 1000)
            (out / f"{stamp}.bin").write_bytes(body)
            headers = {k: ("<redacted>" if k.lower() == "authorization" else v) for k, v in self.headers.items()}
            entry: dict[str, Any] = {"path": self.path, "headers": headers, "bytes": len(body)}
            if self.headers.get("Content-Encoding") == "aes128gcm":
                entry["payload"] = json.loads(webpush_decrypt(body, keys))
            else:
                entry["payload"] = json.loads(body or b"null")
            entry["vapid"] = vapid_claims(self.headers.get("Authorization", ""))
            print(json.dumps(entry, ensure_ascii=False), flush=True)
            self.send_response(201)
            self.end_headers()

        def log_message(self, *_: Any) -> None:
            pass

    print(f"listening on http://127.0.0.1:{args.port}/", file=sys.stderr, flush=True)
    http.server.HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


def vapid_claims(authorization: str) -> dict[str, Any] | None:
    """The JWT claims of a `vapid t=…, k=…` header (RFC 8292), unverified, to check `aud` and `exp`."""
    if not authorization.startswith("vapid "):
        return None
    fields = dict(part.strip().split("=", 1) for part in authorization[6:].split(","))
    claims = json.loads(b64url_decode(fields["t"].split(".")[1]))
    claims.pop("sub", None)
    return claims


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
    add("limits", cmd_limits).add_argument("--room-list-count", type=int, default=8)
    rooms = add("rooms", cmd_rooms)
    rooms.add_argument("--members", action="store_true")
    rooms.add_argument("--room-id")
    history = add("history", cmd_history)
    history.add_argument("--room", required=True)
    history.add_argument("--limit", type=int, default=20)
    history.add_argument("--after")
    history.add_argument("--before")
    join = add("join", cmd_join)
    join.add_argument("--room", required=True)
    join.add_argument("--leave", action="store_true")
    send = add("send", cmd_send)
    send.add_argument("--room")
    send.add_argument("--text", required=True)
    send.add_argument("--format", choices=["plain", "markdown"], default="plain")
    send.add_argument("--reply-to")
    send.add_argument("--mention", action="append", help="user_id listed in body.mentions (repeatable)")
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
    signup = add("email-signup", cmd_email_signup)
    signup.add_argument("--email", required=True)
    signup.add_argument("--user-id")
    signup.add_argument("--code-log", default="logs/apron-local/aprond.log")
    signup.add_argument("--print-token", action="store_true", help="print the token, for pasting into the app")
    me = add("me", cmd_me)
    me.add_argument("--avatar")
    me.add_argument("--display-name")
    room = add("room-create", cmd_room_create)
    room.add_argument("--title")
    room.add_argument("--private", action="store_true")
    room.add_argument("--add", action="append", default=[], help="user_id to add (repeatable)")
    add("dm", cmd_dm).add_argument("--user", required=True, help="user_id to message")
    register = add("push-register", cmd_push_register)
    register.add_argument("--endpoint", required=True)
    register.add_argument("--kind", choices=["webpush", "relay"], default="webpush")
    register.add_argument("--wake", nargs="*", help="wake scopes; omit for the server default, pass none for []")
    register.add_argument("--keys-file", default="logs/apron-push-keys.json")
    add("push-unregister", cmd_push_unregister).add_argument("--endpoint", required=True)
    mute = add("mute", cmd_mute)
    mute.add_argument("--room")
    mute.add_argument("--off", action="store_true")
    emoji = add("emoji", cmd_emoji)
    emoji.add_argument("--sign-in", action="store_true", help="read the catalog from the server frame sent after auth")
    emoji.add_argument("--images", action="store_true", help="HEAD each image")
    emoji.add_argument("--scan", help="text to find catalog keys in")
    capture = sub.add_parser("push-capture")
    capture.add_argument("--port", type=int, default=8099)
    capture.add_argument("--keys-file", default="logs/apron-push-keys.json")

    args = parser.parse_args()
    if args.command == "push-capture":
        cmd_push_capture(args)
        return
    session = Session(args.url, args.verbose)
    try:
        args.handler(session, args)
    finally:
        session.ws.close()


if __name__ == "__main__":
    main()
