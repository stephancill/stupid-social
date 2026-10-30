#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["cryptography>=45", "pynacl>=1.5", "websockets>=13"]
# ///

"""Probe X Chat (XChat), X's end-to-end encrypted DMs, with the cookies the X probe uses.

Unlike the other probes this one has dependencies, run through uv: Python's standard library has no
P-256 or libsodium. Juicebox key recovery runs through the official JS SDK under bun
(scripts/xchat-juicebox-recover.ts).

Recovered private keys are written to logs/xchat-keys.json (0600, gitignored) so decryption can be
iterated without spending PIN guesses. Message contents are never printed unless --show-text is passed.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS_PATH = os.path.join(ROOT, "logs", "xchat-keys.json")
GRAPHQL_URL = "https://x.com/i/api/graphql"
# Every received event uses signature version 7: "MessageCreateEvent,<message_id>,<sender_id>,<conversation_id>,
# <key_version>,<unpadded base64 contents>", with no "signature_version=" suffix below version 9.
SIGNATURE_VERSION = "7"
# MessageSentFrom.ConversationScreenComposer, as the web composer sends.
SENT_FROM_COMPOSER = 1
# GetConversationPageQuery returns events older than min_local_sequence_id, so the newest page starts above every id.
NEWEST_SEQUENCE_ID = str(2**63 - 1)

OPS = {
    "GetInitialXChatPageQuery": "Q4Mw0C6YcnjJac21wq-5NA",
    "GetInboxPageRequestQuery": "txrXftx8RcSvw9jCjwRZWA",
    "GetConversationPageQuery": "GX9ZijkxG8AqRMQVD7hMnQ",
    "GetMessageEventsPageQuery": "8ds29Y40jrxh_MZDbqWy0A",
    "GetPublicKeysQuery": "C-YphxeIcPLOGtFNGhkuOw",
    "SendMessageCreateMutation": "TWRPP7gnKwV_R8-tE-Dd3Q",
    "SendMessageEventMutation": "G7WwJGKvTBVb-BXhZNSVMw",
    "GenerateXChatTokenMutation": "Qh3fZRjPPtPoHYR_2sCZsA",
}
SOCKET_URL = "wss://chat-ws.x.com/ws?token="
# Message{2: MessageInstruction{2: KeepAliveInstruction{}}}, which X's client sends every 30 s.
KEEP_ALIVE = bytes([12, 0, 2, 12, 0, 2, 0, 0, 0])
INSTRUCTIONS = {
    1: "pullMessages",
    2: "keepAlive",
    3: "pullMessagesFinished",
    4: "pinReminder",
    5: "switchToHybridPull",
    6: "displayTemporaryPasscode",
    7: "deviceEnrollment",
    8: "migrateUserMetadata",
    9: "messageRequestInfo",
    10: "xNumberPrompt",
    11: "openInbox",
}


def load_x_probe() -> Any:
    spec = importlib.util.spec_from_file_location("x_web_client", os.path.join(ROOT, "scripts", "x-web-client.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


x_probe = load_x_probe()


class XChatClient:
    def __init__(self, credentials: dict[str, Any]) -> None:
        self.x = x_probe.XWebClient(credentials)

    def query(self, name: str, variables: dict[str, Any]) -> Any:
        query = urllib.parse.urlencode({"variables": json.dumps(variables, separators=(",", ":"))})
        return self.x.request_json("GET", f"{GRAPHQL_URL}/{OPS[name]}/{name}?{query}")

    def mutation(self, name: str, variables: dict[str, Any]) -> Any:
        body = json.dumps({"queryId": OPS[name], "variables": variables}, separators=(",", ":")).encode()
        headers = self.x.headers()
        headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{GRAPHQL_URL}/{OPS[name]}/{name}", data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            raise SystemExit(f"HTTP {exc.code} {name}\n{exc.read().decode('utf-8', 'replace')[:1200]}") from exc

    def conversation_state(self, conversation_id: str, keys: dict[str, Any]) -> dict[str, Any]:
        """Participants, token and conversation keys for one conversation, from the initial page."""
        page = self.initial_page()["data"]["get_initial_chat_page"]
        item = next((i for i in page["items"] if i["conversation_detail"]["conversation_id"] == conversation_id), None)
        if item is None:
            raise SystemExit("Conversation is not in the first inbox page")
        events = [thrift(base64.b64decode(e)) for e in item.get("latest_message_events") or []]
        key_events = [thrift(base64.b64decode(e)) for e in item.get("latest_conversation_key_change_events") or []]
        conversation_keys = self.conversation_keys(key_events, keys)
        tokens = [e[5] for e in sorted(events, key=lambda e: int(text(e.get(1)) or 0)) if 5 in e]
        participants = [
            {
                "id": (pr.get("result") or {}).get("rest_id"),
                "screen_name": ((pr.get("result") or {}).get("core") or {}).get("screen_name"),
            }
            for pr in item["conversation_detail"].get("participants_results") or []
        ]
        return {"item": item, "events": events, "keys": conversation_keys, "token": tokens[-1] if tokens else None, "participants": participants}

    @staticmethod
    def conversation_keys(key_events: list[dict[int, Any]], keys: dict[str, Any]) -> dict[str, bytes]:
        me = keys["user_id"].encode()
        found: dict[str, bytes] = {}
        for event in key_events:
            change = event.get(7, {}).get(3)
            for participant in (change or {}).get(2, []):
                if participant.get(1) == me:
                    found[text(change[1])] = unwrap_conversation_key(keys["identity_private"], participant[2])
        return found

    def conversation_page(self, conversation_id: str, min_sequence_id: str = NEWEST_SEQUENCE_ID) -> Any:
        return self.query(
            "GetConversationPageQuery",
            {"conversation_id": conversation_id, "min_local_sequence_id": min_sequence_id, "min_conversation_key_version": "0"},
        )

    def signature(self, keys: dict[str, Any], payload: str) -> bytes:
        public_key = keys["public_key"]
        return encode_struct(
            [
                (1, 11, sign(keys["signing_private"], payload)),
                (2, 11, keys["version"]),
                (3, 11, SIGNATURE_VERSION),
                (4, 11, public_key["signing_public_key"]),
                (5, 15, (12, [[(1, 11, keys["user_id"]), (2, 11, keys["version"]), (3, 11, public_key["signing_public_key"])]])),
            ]
        )

    def send_entry(self, conversation_id: str, expect_participant: str, entry: list[tuple[int, int, Any]]) -> dict[str, Any]:
        """Encrypts, franks, signs and sends one MessageEntryContents as a MessageCreateEvent."""
        import uuid

        import nacl.utils

        keys = load_keys()
        state = self.conversation_state(conversation_id, keys)
        names = [p["screen_name"] for p in state["participants"]]
        if expect_participant.lower() not in [n.lower() for n in names if n]:
            raise SystemExit(f"Refusing to send: participants are {names}, expected {expect_participant}")
        version = max(state["keys"], key=int)
        conversation_key = state["keys"][version]
        message_id = str(uuid.uuid4())
        plaintext = encode_struct([(1, 12, entry)])
        contents = seal(conversation_key, plaintext)
        nonce = nacl.utils.random(32)
        franking = [(1, 11, franking_tag(plaintext, nonce, message_id, conversation_id, [])), (2, 11, seal(conversation_key, nonce))]
        create_event = encode_struct(
            [
                (100, 11, contents),
                (101, 11, version),
                (102, 2, True),
                (105, 2, False),
                (106, 8, 1),
                (108, 12, franking),
                (109, 2, False),
            ]
        )
        payload = ",".join(["MessageCreateEvent", message_id, keys["user_id"], conversation_id, version, b64_unpadded(contents)])
        response = self.mutation(
            "SendMessageCreateMutation",
            {
                "conversation_id": conversation_id,
                "message_id": message_id,
                "conversation_token": text(state["token"]),
                "encoded_message_create_event": base64.b64encode(create_event).decode(),
                "encoded_message_event_signature": base64.b64encode(self.signature(keys, payload)).decode(),
            },
        )
        result = (response.get("data") or {}).get("xchat_send_create_message_event") or {}
        encoded = result.get("encoded_message_event")
        event = thrift(base64.b64decode(encoded)) if encoded else None
        return {
            "message_id": message_id,
            "errors": response.get("errors"),
            "sequence_id": text(event.get(1)) if event else None,
            "event_fields": sorted(event.keys()) if event else None,
        }

    def send_message(self, conversation_id: str, expect_participant: str, message_text: str) -> dict[str, Any]:
        return self.send_entry(
            conversation_id,
            expect_participant,
            [(1, 12, [(1, 11, message_text), (2, 15, (12, [])), (3, 15, (12, [])), (7, 8, SENT_FROM_COMPOSER)])],
        )

    def react(self, conversation_id: str, expect_participant: str, sequence_id: str, emoji: str, remove: bool) -> dict[str, Any]:
        return self.send_entry(conversation_id, expect_participant, [(3 if remove else 2, 12, [(1, 11, sequence_id), (2, 11, emoji)])])

    def mark_read(self, conversation_id: str, sequence_id: str) -> dict[str, Any]:
        import time
        import uuid

        keys = load_keys()
        message_id = str(uuid.uuid4())
        seen_at = int(time.time() * 1000)
        payload = ",".join(["MarkConversationReadEvent", message_id, keys["user_id"], conversation_id, sequence_id, str(seen_at)])
        event = encode_struct(
            [
                (2, 11, message_id),
                (3, 11, keys["user_id"]),
                (4, 11, conversation_id),
                (6, 11, str(seen_at)),
                (7, 12, [(12, 12, [(1, 11, sequence_id), (2, 10, seen_at)])]),
                (9, 12, self.signature(keys, payload)),
            ]
        )
        response = self.mutation("SendMessageEventMutation", {"encoded_message_event": base64.b64encode(event).decode()})
        result = (response.get("data") or {}).get("xchat_send_message_event") or {}
        return {"errors": response.get("errors"), "error_code": result.get("error_code"), "returned_event": bool(result.get("encoded_message_event"))}

    def viewer_id(self) -> str:
        users = self.x.request_json("GET", x_probe.BASE_URL + "/i/api/1.1/account/multi/list.json").get("users") or []
        if not users:
            raise SystemExit("account/multi/list.json returned no users")
        return str(users[0]["user_id"] if "user_id" in users[0] else users[0]["id_str"])

    def public_keys(self, user_ids: list[str], juicebox: bool) -> list[dict[str, Any]]:
        """Each user's key versions, newest first, with Juicebox tokens when asked."""
        response = self.query("GetPublicKeysQuery", {"ids": user_ids, "include_juicebox_tokens": juicebox})
        users = []
        for entry in response["data"]["user_results_by_rest_ids"]:
            result = entry.get("result") or {}
            versions = ((result.get("get_public_keys") or {}).get("public_keys_with_token_map")) or []
            users.append({"user_id": entry.get("rest_id"), "chat_permissions": result.get("chat_permissions"), "versions": versions})
        return users

    def initial_page(self) -> Any:
        return self.query(
            "GetInitialXChatPageQuery",
            {"include_user_public_keys": True, "include_juicebox_tokens": False, "message_pull_version": 1},
        )

    def socket_token(self) -> str:
        result = self.mutation("GenerateXChatTokenMutation", {})["data"]["user_get_x_chat_auth_token"]
        if not result.get("token"):
            raise SystemExit(f"No XChat socket token: {result.get('error_code')}")
        return result["token"]

    def listen(self, seconds: int, send_to: str | None, expect_participant: str | None) -> dict[str, Any]:
        """Connects X's chat WebSocket, heartbeats like the web client, and summarizes every frame.
        With `send_to`, sends one test message a few seconds in to see how it arrives."""
        import asyncio

        import websockets

        token = self.socket_token()
        frames: list[dict[str, Any]] = []

        async def run() -> dict[str, Any]:
            headers = {"Origin": "https://x.com", "User-Agent": x_probe.APP_USER_AGENT}
            async with websockets.connect(SOCKET_URL + token, additional_headers=headers, max_size=None) as socket:
                loop = asyncio.get_running_loop()
                started = loop.time()
                last_beat = started
                sent = None
                while loop.time() - started < seconds:
                    if loop.time() - last_beat >= 30:
                        await socket.send(KEEP_ALIVE)
                        last_beat = loop.time()
                        frames.append({"t": round(loop.time() - started, 1), "sent": "keepAlive"})
                    if send_to and sent is None and loop.time() - started > 3:
                        sent = await loop.run_in_executor(
                            None, lambda: self.send_message(send_to, expect_participant or "", "Socket test from the No Feed Social probe")
                        )
                        frames.append({"t": round(loop.time() - started, 1), "sent": "message", "sequence_id": sent["sequence_id"]})
                    try:
                        frame = await asyncio.wait_for(socket.recv(), timeout=1)
                    except asyncio.TimeoutError:
                        continue
                    frames.append({"t": round(loop.time() - started, 1), **summarize_frame(frame)})
                return {"close": None}

        try:
            outcome = asyncio.run(run())
        except websockets.exceptions.ConnectionClosed as closed:
            outcome = {"close": {"code": closed.code, "reason": closed.reason}}
        return {"frames": frames, **outcome}

    def inbox_items(self) -> list[dict[str, Any]]:
        """Every inbox conversation: the initial page, then GetInboxPageRequestQuery until the end cursor."""
        page = self.initial_page()["data"]["get_initial_chat_page"]
        items = list(page.get("items") or [])
        cursor = page.get("inboxCursor") or {}
        while cursor.get("__typename") == "XChatGetInboxPageContinueCursor":
            response = self.query(
                "GetInboxPageRequestQuery",
                {"continue_cursor": {"cursor_id": cursor["cursor_id"], "graph_snapshot_id": cursor["graph_snapshot_id"]}},
            )
            next_page = response["data"]["get_inbox_page"]
            items += next_page.get("items") or []
            cursor = next_page.get("inboxCursor") or {}
        return items

    def recover_keys(self) -> dict[str, Any]:
        """Recovers the newest key version's secret through Juicebox and saves it to logs/xchat-keys.json."""
        viewer = self.viewer_id()
        [user] = self.public_keys([viewer], juicebox=True)
        versions = sorted(user["versions"], key=lambda v: -int(v["public_key_with_metadata"]["version"]))
        if not versions:
            raise SystemExit("The account has no XChat public keys")
        newest = versions[0]
        token_map = newest.get("token_map") or {}
        config = json.loads(token_map["key_store_token_map_json"])
        tokens = {entry["key"]: entry["value"]["token"] for entry in token_map["token_map"]}
        result = subprocess.run(
            ["bun", os.path.join(ROOT, "scripts", "xchat-juicebox-recover.ts")],
            input=json.dumps({"config": config, "tokens": tokens}),
            text=True,
            capture_output=True,
            cwd=ROOT,
        )
        output = json.loads(result.stdout or "{}") if result.stdout.strip().startswith("{") else {}
        if result.returncode != 0 or "secret_hex" not in output:
            raise SystemExit(f"Juicebox recover failed: {output or result.stderr[-800:]}")
        metadata = newest["public_key_with_metadata"]
        saved = {
            "user_id": viewer,
            "version": metadata["version"],
            "public_key": metadata["public_key"],
            "secret_hex": output["secret_hex"],
        }
        os.makedirs(os.path.dirname(KEYS_PATH), exist_ok=True)
        descriptor = os.open(KEYS_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(saved, handle)
        return {
            "status": "ok",
            "version": metadata["version"],
            "key_versions": len(versions),
            "secret_bytes": len(output["secret_hex"]) // 2,
            "saved_to": os.path.relpath(KEYS_PATH, ROOT),
        }


# MARK: Thrift binary protocol


class ThriftReader:
    """Decodes Thrift binary-protocol structs to {field_id: value}; strings stay bytes."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0

    def take(self, count: int) -> bytes:
        if self.offset + count > len(self.data):
            raise ValueError("truncated thrift data")
        chunk = self.data[self.offset : self.offset + count]
        self.offset += count
        return chunk

    def int(self, size: int) -> int:
        return int.from_bytes(self.take(size), "big", signed=True)

    def value(self, kind: int) -> Any:
        if kind == 2:
            return self.take(1) != b"\x00"
        if kind == 3:
            return self.int(1)
        if kind == 4:
            return self.take(8)
        if kind == 6:
            return self.int(2)
        if kind == 8:
            return self.int(4)
        if kind == 10:
            return self.int(8)
        if kind == 11:
            return self.take(self.int(4))
        if kind == 12:
            return self.struct()
        if kind == 13:
            key_kind, value_kind, size = self.int(1), self.int(1), self.int(4)
            return [(self.value(key_kind), self.value(value_kind)) for _ in range(size)]
        if kind in (14, 15):
            element_kind, size = self.int(1), self.int(4)
            return [self.value(element_kind) for _ in range(size)]
        raise ValueError(f"unknown thrift type {kind}")

    def struct(self) -> dict[int, Any]:
        fields: dict[int, Any] = {}
        while True:
            kind = self.int(1)
            if kind == 0:
                return fields
            field_id = self.int(2)
            fields[field_id] = self.value(kind)


class ThriftWriter:
    """Encodes Thrift binary-protocol structs from [(field_id, type, value)] lists."""

    def __init__(self) -> None:
        self.out = bytearray()

    def value(self, kind: int, value: Any) -> None:
        if kind == 2:
            self.out += b"\x01" if value else b"\x00"
        elif kind == 6:
            self.out += int(value).to_bytes(2, "big", signed=True)
        elif kind == 8:
            self.out += int(value).to_bytes(4, "big", signed=True)
        elif kind == 10:
            self.out += int(value).to_bytes(8, "big", signed=True)
        elif kind == 11:
            data = value.encode() if isinstance(value, str) else value
            self.out += len(data).to_bytes(4, "big", signed=True) + data
        elif kind == 12 and isinstance(value, bytes):
            self.out += value  # an already-encoded struct
        elif kind == 12:
            self.struct(value)
        elif kind == 15:
            element_kind, items = value
            self.out += bytes([element_kind]) + len(items).to_bytes(4, "big", signed=True)
            for item in items:
                self.value(element_kind, item)
        else:
            raise ValueError(f"unsupported thrift type {kind}")

    def struct(self, fields: list[tuple[int, int, Any]]) -> None:
        for field_id, kind, value in fields:
            if value is None:
                continue
            self.out += bytes([kind]) + field_id.to_bytes(2, "big", signed=True)
            self.value(kind, value)
        self.out += b"\x00"


def encode_struct(fields: list[tuple[int, int, Any]]) -> bytes:
    writer = ThriftWriter()
    writer.struct(fields)
    return bytes(writer.out)


def thrift(data: bytes) -> dict[int, Any]:
    return ThriftReader(data).struct()


def text(value: Any) -> str | None:
    return value.decode("utf-8") if isinstance(value, bytes) else None


# MARK: Crypto


def hkdf_sha256(key: bytes, salt: str, length: int, info: bytes) -> bytes:
    """dm-core's X7r.c12p: RFC 5869 HKDF with the context string as salt (32 zero bytes when empty)."""
    import hashlib
    import hmac

    prk = hmac.new(salt.encode() if salt else bytes(32), key, hashlib.sha256).digest()
    output, block, counter = b"", b"", 1
    while len(output) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        output += block
        counter += 1
    return output[:length]


def unwrap_conversation_key(identity_private: bytes, wrapped_b64: bytes | str) -> bytes:
    """ECIES over P-256: ephemeral pub (65) || AES-128-GCM ciphertext, key and IV from SHA-256(shared || 00000001 || ephemeral pub)."""
    import hashlib

    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    blob = base64.b64decode(wrapped_b64)
    ephemeral, ciphertext = blob[:65], blob[65:]
    private_key = ec.derive_private_key(int.from_bytes(identity_private, "big"), ec.SECP256R1())
    shared = private_key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ephemeral))
    derived = hashlib.sha256(shared + b"\x00\x00\x00\x01" + ephemeral).digest()
    return AESGCM(derived[:16]).decrypt(derived[16:32], ciphertext, None)


def open_message(conversation_key: bytes, info: str, contents: bytes) -> bytes:
    import nacl.secret

    message_key = hkdf_sha256(conversation_key, "xchat-message-key", 32, info.encode())
    return nacl.secret.SecretBox(message_key).decrypt(contents[24:], contents[:24])


def b64_unpadded(data: bytes) -> str:
    return base64.b64encode(data).decode().rstrip("=")


def b64_lenient(value: bytes | str) -> bytes:
    text_value = value.decode() if isinstance(value, bytes) else value
    return base64.b64decode(text_value + "=" * (-len(text_value) % 4))


def seal(conversation_key: bytes, plaintext: bytes) -> bytes:
    """Contents encryption version 0: secretbox under the conversation key, stored as nonce (24) || ciphertext."""
    import nacl.secret
    import nacl.utils

    nonce = nacl.utils.random(24)
    return nonce + nacl.secret.SecretBox(conversation_key).encrypt(plaintext, nonce).ciphertext


def open_sealed(conversation_key: bytes, contents: bytes) -> bytes:
    import nacl.secret

    return nacl.secret.SecretBox(conversation_key).decrypt(contents[24:], contents[:24])


def franking_tag(plaintext: bytes, nonce: bytes, message_id: str, conversation_id: str, media_hashes: list[bytes]) -> bytes:
    """dm-core's MessageFranking.t13n, verified against received text messages."""
    import hashlib

    data = (
        b"xchat-franking"
        + hashlib.sha256(plaintext).digest()
        + len(media_hashes).to_bytes(4, "big")
        + b"".join(media_hashes)
        + nonce
        + message_id.encode()
        + len(conversation_id.encode()).to_bytes(4, "big")
        + conversation_id.encode()
    )
    return hashlib.sha256(data).digest()


def sign(signing_private: bytes, payload: str) -> str:
    """ECDSA P-256/SHA-256 over the comma-joined payload, as raw r || s in unpadded base64."""
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key = ec.derive_private_key(int.from_bytes(signing_private, "big"), ec.SECP256R1())
    r, s_value = utils.decode_dss_signature(key.sign(payload.encode(), ec.ECDSA(hashes.SHA256())))
    return b64_unpadded(r.to_bytes(32, "big") + s_value.to_bytes(32, "big"))


def load_keys() -> dict[str, Any]:
    if not os.path.exists(KEYS_PATH):
        raise SystemExit("Run recover-keys first")
    with open(KEYS_PATH, encoding="utf-8") as handle:
        keys = json.load(handle)
    secret = bytes.fromhex(keys["secret_hex"])
    keys["identity_private"], keys["signing_private"] = secret[:32], secret[32:]
    return keys


def summarize_events(events: list[dict[int, Any]], keys_by_version: dict[str, bytes], viewer_id: str, show_text: bool) -> list[dict[str, Any]]:
    """Each event's kind and, for messages, what decrypting it gave; text only with --show-text."""
    rows = []
    for event in sorted(events, key=lambda e: int(text(e.get(1)) or 0)):
        detail = event.get(7, {})
        row: dict[str, Any] = {"sequence_id": text(event.get(1)), "own": text(event.get(3)) == viewer_id, "detail": sorted(detail)}
        create = detail.get(1)
        if create:
            # Without a key version (101) the message was sent unencrypted (109 true): contents are the plain
            # `MessageEntryHolder`.
            plain = 101 not in create
            key = keys_by_version.get(text(create.get(101)) or "")
            if plain:
                row["encrypted"] = False
            if not plain and key is None:
                row["decrypt"] = "missing conversation key"
            else:
                contents = thrift(create[100] if plain else open_sealed(key, create[100])).get(1, {})
                row["entry"] = sorted(contents)
                message = contents.get(1)
                if message and show_text:
                    row["text"] = text(message.get(1))
                elif message:
                    row["text_length"] = len(message.get(1) or b"")
                reaction = contents.get(2) or contents.get(3)
                if reaction:
                    row["reaction_on"] = text(reaction.get(1))
                    row["emoji"] = text(reaction.get(2))
        rows.append(row)
    return rows


def summarize_frame(frame: bytes | str) -> dict[str, Any]:
    """A socket frame's kind and ids, never its contents."""
    if isinstance(frame, str):
        return {"text_frame_length": len(frame)}
    message = thrift(frame)
    if 1 in message:
        return {"event": event_summary(message[1])}
    if 2 in message:
        instruction = message[2]
        kind = next(iter(instruction), None)
        body = instruction.get(kind) or {}
        return {"instruction": INSTRUCTIONS.get(kind, kind), "fields": {k: (text(v) if isinstance(v, bytes) else v) for k, v in body.items() if not isinstance(v, dict)}}
    if 3 in message:
        return {"batch": [event_summary(e) for e in message[3].get(1, [])]}
    return {"unknown_fields": sorted(message)}


def event_summary(event: dict[int, Any]) -> dict[str, Any]:
    return {"sequence_id": text(event.get(1)), "conversation_id_length": len(event.get(4) or b""), "detail": sorted(event.get(7, {}))}


def unread_count(item: dict[str, Any], keys: dict[str, Any]) -> int:
    """Others' messages after the viewer's newest read marker, among the inbox's latest events. Reactions and
    other entries are create events too, but X's badge doesn't count them, so each is decrypted to check."""
    viewer_id = keys["user_id"]
    read_until = 0
    for entry in item.get("latest_read_events_per_participant") or []:
        event = thrift(base64.b64decode(entry["latest_mark_conversation_read_event"]))
        marker = event.get(7, {}).get(12)
        if marker and text(event.get(3)) == viewer_id:
            read_until = max(read_until, int(text(marker.get(1)) or 0))
    conversation_keys = XChatClient.conversation_keys(
        [thrift(base64.b64decode(e)) for e in item.get("latest_conversation_key_change_events") or []], keys
    )
    count = 0
    for blob in item.get("latest_message_events") or []:
        event = thrift(base64.b64decode(blob))
        create = event.get(7, {}).get(1)
        if not create or text(event.get(3)) == viewer_id or int(text(event.get(1)) or 0) <= read_until:
            continue
        key = conversation_keys.get(text(create.get(101)) or "")
        if key is None or 1 in thrift(open_sealed(key, create[100])).get(1, {}):
            count += 1
    return count

def group_names_summary(items: list[dict[str, Any]], keys: dict[str, Any], show_names: bool) -> list[dict[str, Any]]:
    """Each group's `group_metadata.group_name`: sealed (version 0) under one of the conversation keys, which it
    doesn't name, so each is tried. Names only with --show-names."""
    rows = []
    for item in items:
        detail = item["conversation_detail"]
        if detail.get("__typename") != "XChatGroupConversationDetail":
            continue
        sealed = (detail.get("group_metadata") or {}).get("group_name")
        row: dict[str, Any] = {"members": len(detail.get("group_members_results") or []), "named": sealed is not None}
        if sealed:
            conversation_keys = XChatClient.conversation_keys(
                [thrift(base64.b64decode(e)) for e in item.get("latest_conversation_key_change_events") or []], keys
            )
            for version, key in sorted(conversation_keys.items(), reverse=True):
                try:
                    name = open_sealed(key, b64_lenient(sealed)).decode()
                except Exception:
                    continue
                row["key_version"] = version
                row["name" if show_names else "name_length"] = name if show_names else len(name)
                break
            else:
                row["decrypt"] = "no conversation key opens it"
        rows.append(row)
    return rows


def plain_holder_shape(contents: Any) -> Any:
    """Whether create-event contents parse as an unencrypted Thrift `MessageEntryHolder`, by field numbers only."""
    if not isinstance(contents, bytes):
        return None
    try:
        holder = thrift(contents)
    except Exception as error:  # noqa: BLE001 - the failure kind is the finding
        return {"parses": type(error).__name__}

    def shape(value: Any) -> Any:
        if isinstance(value, dict):
            return {field: shape(inner) for field, inner in value.items()}
        if isinstance(value, list):
            return [shape(inner) for inner in value[:3]]
        return type(value).__name__

    return {"parses": True, "shape": shape(holder)}


def key_changes_summary(client: "XChatClient", conversation_id: str, keys: dict[str, Any], pages: int) -> dict[str, Any]:
    """Where a conversation's keys could come from, without contents: the inbox item's latest key changes, each
    page's missing ones, and key-change events among the messages, paging back."""
    me = keys["user_id"].encode()

    def describe(source: str, event: dict[int, Any]) -> dict[str, Any]:
        change = event.get(7, {}).get(3) or {}
        participants = change.get(2) or []
        mine = [p for p in participants if p.get(1) == me]
        row: dict[str, Any] = {
            "source": source,
            "sequence_id": text(event.get(1)),
            "key_version": text(change.get(1)),
            "participants": len(participants),
            "participant_fields": sorted({field for p in participants for field in p}),
            "wraps_for_viewer": bool(mine),
            "change_fields": sorted(change),
        }
        if mine:
            try:
                unwrap_conversation_key(keys["identity_private"], mine[0][2])
                row["unwraps"] = True
            except Exception as error:  # noqa: BLE001 - the failure kind is the finding
                row["unwraps"] = type(error).__name__
            # Any field beside the user id and wrapped key, such as the public key version it was wrapped for.
            row["viewer_entry_extra"] = {field: text(value) if isinstance(value, bytes) else value for field, value in mine[0].items() if field not in (1, 2)}
        return row

    state = client.conversation_state(conversation_id, keys)
    rows = [describe("inbox latest", thrift(base64.b64decode(e))) for e in state["item"].get("latest_conversation_key_change_events") or []]
    min_sequence = NEWEST_SEQUENCE_ID
    message_events = 0
    message_key_versions: set[str] = set()
    message_shapes: list[dict[str, Any]] = []
    for page_number in range(pages):
        conversation = client.conversation_page(conversation_id, min_sequence)["data"]["get_conversation_page"]
        events = [thrift(base64.b64decode(e)) for e in conversation.get("encoded_message_events") or []]
        rows += [describe(f"page {page_number} missing", thrift(base64.b64decode(e))) for e in conversation.get("missing_conversation_key_change_events") or []]
        rows += [describe(f"page {page_number} event", e) for e in events if 3 in e.get(7, {})]
        for event in events:
            create = event.get(7, {}).get(1)
            if create is not None:
                message_events += 1
                message_key_versions.add(text(create.get(101)) or "none")
                message_shapes.append({
                    "event_fields": sorted(event),
                    "detail_fields": sorted(event.get(7, {})),
                    "create_fields": sorted(create) if isinstance(create, dict) else type(create).__name__,
                    "field_types": {field: type(value).__name__ for field, value in create.items()} if isinstance(create, dict) else None,
                    # Values of the small fields only; contents (100) stay out.
                    "flags": {field: value for field, value in create.items() if isinstance(value, (bool, int))},
                    "event_extra": {field: type(event[field]).__name__ for field in (8, 9, 11) if field in event},
                    "contents_as_plain_holder": plain_holder_shape(create.get(100)),
                })
        if not conversation.get("has_more") or not events:
            break
        min_sequence = min((text(e.get(1)) for e in events), key=int)
    return {
        "viewer_key_version": keys["version"],
        "message_events_read": message_events,
        "message_key_versions": sorted(message_key_versions),
        "message_shapes": message_shapes,
        "key_changes": rows,
    }


MEDIA_URL = "https://ton.x.com/i/ton/data/xchat_media/"
MEDIA_TYPES = {1: "image", 2: "gif", 3: "video", 4: "audio", 5: "file", 6: "svg"}
# dm-core's LibsodiumStreamConfig: 1024-byte plaintext chunks, each pushed with the 17-byte secretstream overhead.
MEDIA_CHUNK = 1024 + 17


def media_key(conversation_key: bytes, attachment_id: str | None) -> bytes:
    """dm-core: the message key (the conversation key for contents version 0), then, when the attachment has an
    id, HKDF-SHA256 with salt "xchat-attachment-key" and the attachment id as info."""
    return hkdf_sha256(conversation_key, "xchat-attachment-key", 32, attachment_id.encode()) if attachment_id else conversation_key


def decrypt_media(key: bytes, blob: bytes) -> bytes:
    """crypto_secretstream_xchacha20poly1305: 24-byte header, then chunks of 1024 plaintext bytes + 17."""
    from nacl.bindings import (
        crypto_secretstream_xchacha20poly1305_init_pull,
        crypto_secretstream_xchacha20poly1305_pull,
        crypto_secretstream_xchacha20poly1305_state,
        crypto_secretstream_xchacha20poly1305_TAG_FINAL,
    )

    state = crypto_secretstream_xchacha20poly1305_state()
    crypto_secretstream_xchacha20poly1305_init_pull(state, blob[:24], key)
    output, tag, offset = b"", None, 24
    while offset < len(blob):
        chunk, tag = crypto_secretstream_xchacha20poly1305_pull(state, blob[offset : offset + MEDIA_CHUNK])
        output += chunk
        offset += MEDIA_CHUNK
    if tag != crypto_secretstream_xchacha20poly1305_TAG_FINAL:
        raise ValueError(f"stream ended without the final tag (last tag {tag})")
    return output


def media_attachments(client: "XChatClient", item: dict[str, Any], keys: dict[str, Any], pages: int) -> list[dict[str, Any]]:
    """Each media attachment in an inbox conversation's newest pages: parsed fields, never message text."""
    conversation_id = item["conversation_detail"]["conversation_id"]
    conversation_keys = client.conversation_keys(
        [thrift(base64.b64decode(e)) for e in item.get("latest_conversation_key_change_events") or []], keys
    )
    found = []
    min_sequence = NEWEST_SEQUENCE_ID
    for _ in range(pages):
        conversation = client.conversation_page(conversation_id, min_sequence)["data"]["get_conversation_page"]
        events = [thrift(base64.b64decode(e)) for e in conversation.get("encoded_message_events") or []]
        missing = [thrift(base64.b64decode(e)) for e in conversation.get("missing_conversation_key_change_events") or []]
        conversation_keys.update(client.conversation_keys(missing + [e for e in events if 3 in e.get(7, {})], keys))
        for event in events:
            create = event.get(7, {}).get(1)
            if not create:
                continue
            plain = 101 not in create
            version = text(create.get(101))
            key = conversation_keys.get(version or "")
            if not plain and key is None:
                continue
            entry = thrift(create[100] if plain else open_sealed(key, create[100])).get(1)
            message = entry.get(1) if isinstance(entry, dict) else None
            if not isinstance(message, dict):
                continue
            for attachment in message.get(3) or []:
                media = attachment.get(1)
                if not media:
                    continue
                size = media.get(2) or {}
                filename = text(media.get(6)) or ""
                found.append({
                    "conversation_id": conversation_id,
                    "sequence_id": text(event.get(1)),
                    "message_id": text(event.get(2)),
                    "key_version": version,
                    "conversation_key": key,
                    "fields": sorted(media),
                    "media_hash_key": text(media.get(1)),
                    "type": MEDIA_TYPES.get(media.get(3), media.get(3)),
                    "width": size.get(1),
                    "height": size.get(2),
                    "duration_millis": media.get(4),
                    "filesize_bytes": media.get(5),
                    "extension": os.path.splitext(filename)[1].lower(),
                    "attachment_id": text(media.get(7)),
                    "legacy_url": bool(media.get(8)),
                    "legacy_preview_url": bool(media.get(9)),
                    "plaintext_sha256": media.get(11),
                })
        if not conversation.get("has_more") or not events:
            break
        min_sequence = min((text(e.get(1)) for e in events), key=int)
    return found


def public_media_row(row: dict[str, Any]) -> dict[str, Any]:
    """A media row without keys, ids or hashes."""
    hidden = {"conversation_key", "conversation_id", "message_id", "media_hash_key", "attachment_id", "plaintext_sha256"}
    return {
        **{k: v for k, v in row.items() if k not in hidden},
        "media_hash_key_length": len(row["media_hash_key"] or ""),
        "has_attachment_id": row["attachment_id"] is not None,
        "has_plaintext_sha256": row["plaintext_sha256"] is not None,
    }


def download_media(client: "XChatClient", row: dict[str, Any]) -> dict[str, Any]:
    """Downloads one encrypted attachment from ton.x.com, decrypts it and writes it under logs/xchat-media/."""
    import hashlib

    url = MEDIA_URL + row["conversation_id"] + "/" + row["media_hash_key"]
    request = urllib.request.Request(url, headers=client.x.headers())
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            blob = response.read()
            content_type = response.headers.get("Content-Type")
    except urllib.error.HTTPError as exc:
        return {"http_status": exc.code, "body": exc.read()[:200].decode("utf-8", "replace")}
    result: dict[str, Any] = {"http_status": 200, "content_type": content_type, "encrypted_bytes": len(blob)}
    # Whether ton.x.com needs the X cookies for this media.
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": x_probe.APP_USER_AGENT}), timeout=60) as response:
            result["without_cookies"] = response.status
    except urllib.error.HTTPError as exc:
        result["without_cookies"] = exc.code
    attempts = [("attachment_key", row["attachment_id"]), ("conversation_key", None)] if row["attachment_id"] else [("conversation_key", None)]
    for name, attachment_id in attempts:
        try:
            plaintext = decrypt_media(media_key(row["conversation_key"], attachment_id), blob)
        except Exception as error:  # noqa: BLE001 - the failure kind is the finding
            result[name] = type(error).__name__ + ": " + str(error)[:120]
            continue
        result["key"] = name
        result["plaintext_bytes"] = len(plaintext)
        result["matches_filesize"] = row["filesize_bytes"] in (None, len(plaintext))
        if row["plaintext_sha256"] is not None:
            result["matches_plaintext_sha256"] = hashlib.sha256(plaintext).digest() == row["plaintext_sha256"]
        directory = os.path.join(ROOT, "logs", "xchat-media")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, f"{row['sequence_id']}{row['extension'] or '.bin'}")
        with open(path, "wb") as handle:
            handle.write(plaintext)
        result["file_type"] = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout.strip()
        result["saved_to"] = os.path.relpath(path, ROOT)
        break
    return result


def key_versions_summary(users: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "user_id_length": len(user["user_id"] or ""),
            "chat_permissions": user["chat_permissions"],
            "versions": [
                {
                    "version": v["public_key_with_metadata"]["version"],
                    "registration_method": v["public_key_with_metadata"]["public_key"].get("registration_method"),
                    "public_key_b64_length": len(v["public_key_with_metadata"]["public_key"].get("public_key") or ""),
                    "has_token_map": bool(v.get("token_map")),
                }
                for v in user["versions"]
            ],
        }
        for user in users
    ]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Probe X Chat (encrypted DMs) with captured X cookies.")
    parser.add_argument("--simulator", action="store_true", help="Read X credentials from the booted simulator fallback store.")
    parser.add_argument("--env-local", action="store_true", help="Read X credentials JSON from DIAGNOSE_X_CREDS in .env.local.")
    parser.add_argument("--credentials-file", help="Path to credentials JSON, or '-' for stdin.")
    parser.add_argument("--credentials-json", help="Credentials JSON string.")
    parser.add_argument("--output", help="Write the full JSON response to this path (under logs/).")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("viewer", help="Print the signed-in user's id length (not the id).")
    keys = subparsers.add_parser("public-keys", help="Summarize XChat key versions for users (default: the viewer).")
    keys.add_argument("user_ids", nargs="*")
    subparsers.add_parser("inbox", help="Fetch every inbox page; print the conversation count and unread counts.")
    subparsers.add_parser(
        "recover-keys",
        help="Recover the viewer's private keys through Juicebox with X_CHAT_PIN. Uses a PIN guess if the PIN is wrong.",
    )
    names = subparsers.add_parser("group-names", help="Decrypt each group's sealed name (lengths; names with --show-names).")
    names.add_argument("--show-names", action="store_true")
    conversation = subparsers.add_parser("conversation", help="Decrypt the newest events of one conversation (shapes; text with --show-text).")
    conversation.add_argument("conversation_id")
    conversation.add_argument("--show-text", action="store_true")
    key_changes = subparsers.add_parser(
        "key-changes",
        help="Summarize a conversation's key-change events from the inbox and its pages: versions, and whether each wraps a key for the viewer.",
    )
    key_changes.add_argument("conversation_id")
    key_changes.add_argument("--pages", type=int, default=5, help="Older pages to read looking for key changes.")
    media = subparsers.add_parser(
        "media",
        help="List media attachments' fields (no text, ids or keys) in one conversation, or every inbox conversation; "
        "--download N decrypts the Nth to logs/xchat-media/.",
    )
    media.add_argument("conversation_id", nargs="?", help="Omit to scan every inbox conversation.")
    media.add_argument("--pages", type=int, default=3)
    media.add_argument("--download", type=int, action="append", default=[], help="Index of an attachment to download and decrypt.")
    send = subparsers.add_parser("send-message", help="Send an encrypted text message. Only to a conversation agreed for testing.")
    send.add_argument("conversation_id")
    send.add_argument("text")
    send.add_argument("--expect-participant", required=True, help="Screen name the conversation must be with.")
    react = subparsers.add_parser("react", help="Add (or with --remove, remove) a reaction to a message by sequence id.")
    react.add_argument("conversation_id")
    react.add_argument("sequence_id")
    react.add_argument("emoji")
    react.add_argument("--remove", action="store_true")
    react.add_argument("--expect-participant", required=True)
    listen = subparsers.add_parser("listen", help="Connect X's chat WebSocket and summarize frames (no contents).")
    listen.add_argument("--seconds", type=int, default=45)
    listen.add_argument("--send-to", help="Conversation id to send one test message to while listening.")
    listen.add_argument("--expect-participant", help="Screen name the --send-to conversation must be with.")
    mark = subparsers.add_parser("mark-read", help="Mark a conversation read up to a sequence id.")
    mark.add_argument("conversation_id")
    mark.add_argument("sequence_id")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    client = XChatClient(x_probe.load_credentials(args))
    if args.command == "viewer":
        result: Any = {"user_id_length": len(client.viewer_id())}
    elif args.command == "public-keys":
        users = client.public_keys(args.user_ids or [client.viewer_id()], juicebox=False)
        result = key_versions_summary(users)
    elif args.command == "group-names":
        result = group_names_summary(client.inbox_items(), load_keys(), args.show_names)
    elif args.command == "inbox":
        items = client.inbox_items()
        x_probe.write_output(args.output, items)
        keys = load_keys()
        result = {"conversations": len(items), "unread": [unread_count(item, keys) for item in items]}
    elif args.command == "recover-keys":
        result = client.recover_keys()
    elif args.command == "conversation":
        keys = load_keys()
        state = client.conversation_state(args.conversation_id, keys)
        page = client.conversation_page(args.conversation_id)
        x_probe.write_output(args.output, page)
        conversation = page["data"]["get_conversation_page"]
        events = [thrift(base64.b64decode(e)) for e in conversation.get("encoded_message_events") or []]
        missing = [thrift(base64.b64decode(e)) for e in conversation.get("missing_conversation_key_change_events") or []]
        all_keys = {**state["keys"], **client.conversation_keys(missing + [e for e in events if 3 in e.get(7, {})], keys)}
        result = {
            "participants": [p["screen_name"] for p in state["participants"]],
            "has_more": conversation.get("has_more"),
            "key_versions": sorted(all_keys),
            "events": summarize_events(events, all_keys, keys["user_id"], args.show_text),
        }
    elif args.command == "key-changes":
        result = key_changes_summary(client, args.conversation_id, load_keys(), args.pages)
    elif args.command == "media":
        keys = load_keys()
        items = [i for i in client.inbox_items() if args.conversation_id in (None, i["conversation_detail"]["conversation_id"])]
        rows = [row for item in items for row in media_attachments(client, item, keys, args.pages)]
        result = {
            "attachments": [{"index": index, **public_media_row(row)} for index, row in enumerate(rows)],
            "downloads": {str(index): download_media(client, rows[index]) for index in args.download},
        }
    elif args.command == "send-message":
        result = client.send_message(args.conversation_id, args.expect_participant, args.text)
    elif args.command == "react":
        result = client.react(args.conversation_id, args.expect_participant, args.sequence_id, args.emoji, args.remove)
    elif args.command == "listen":
        if args.send_to and not args.expect_participant:
            raise SystemExit("--send-to needs --expect-participant")
        result = client.listen(args.seconds, args.send_to, args.expect_participant)
    elif args.command == "mark-read":
        result = client.mark_read(args.conversation_id, args.sequence_id)
    else:
        raise SystemExit(f"Unknown command: {args.command}")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
