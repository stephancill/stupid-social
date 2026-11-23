#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["cryptography>=45", "protobuf>=5.28", "grpcio-tools>=1.66", "websockets>=14", "qrcode[pil]>=8"]
# ///

"""Probe WhatsApp as a linked device (the multi-device protocol WhatsApp Web uses).

The protocol is ported from whatsmeow (third-party/whatsmeow, its Signal library in third-party/libsignal-go)
and cross-checked against Baileys (third-party/Baileys); nothing here is guessed from traffic. Protobuf
messages come from whatsmeow's .proto files, compiled into logs/whatsapp-proto on first use.

The linked device's keys and Signal state live in logs/whatsapp-session.json (0600, gitignored). Message
text from other people is never printed; --show-text only prints messages the account itself sent.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import copy
import hashlib
import hmac
import importlib
import json
import os
import re
import secrets
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zlib
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.exceptions import InvalidSignature

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSION_PATH = os.path.join(ROOT, "logs", "whatsapp-session.json")
PROTO_SOURCE = os.path.join(ROOT, "third-party", "whatsmeow", "proto")
PROTO_OUT = os.path.join(ROOT, "logs", "whatsapp-proto")
SIGNAL_PROTO_SOURCE = os.path.join(ROOT, "third-party", "libsignal-go", "serialize")
HISTORY_DIR = os.path.join(ROOT, "logs", "whatsapp-history")
TOKENS_PATH = os.path.join(ROOT, "Sources", "StupidSocialCore", "Resources", "WhatsAppTokens.json")

SOCKET_URL = "wss://web.whatsapp.com/ws/chat"
ORIGIN = "https://web.whatsapp.com"
NOISE_PATTERN = b"Noise_XX_25519_AESGCM_SHA256\x00\x00\x00\x00"
# The intermediate certificate's issuer, WhatsApp's root noise key (whatsmeow handshake.go).
WA_CERT_PUBLIC_KEY = bytes.fromhex("142375574d0a587166aae71ebe516437c4a28b73e3695c6ce1f7f9545da8ee6b")
# The web client version whatsmeow ships; `version` fetches the current one from web.whatsapp.com/sw.js.
DEFAULT_WA_VERSION = (2, 3000, 1050728964)
DEVICE_NAME = "stupid social"
# WhatsApp accepts only `Browser (OS)` with a common browser and OS here; anything else is 400 bad-request (observed 2026-11-22).
PAIR_CLIENT_DISPLAY = "Safari (Mac OS)"
# DeviceProps.PlatformType.SAFARI, and the matching pairing client type ("6", whatsmeow pair-code.go).
PLATFORM_TYPE_SAFARI = 5
PAIR_CLIENT_SAFARI = "6"
DJB_TYPE = 5
ADV_ACCOUNT_SIGNATURE_PREFIX = bytes([6, 0])
ADV_DEVICE_SIGNATURE_PREFIX = bytes([6, 1])
LINKING_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTVWXYZ"
INITIAL_PREKEY_COUNT = 812
WANTED_PREKEY_COUNT = 50
MIN_PREKEY_COUNT = 5


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def unb64(text: str) -> bytes:
    return base64.b64decode(text)


def log(*parts: Any) -> None:
    print(*parts, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------------------
# Protobuf (whatsmeow's .proto files, compiled with grpcio-tools)


def compile_protos() -> None:
    marker = os.path.join(PROTO_OUT, ".compiled")
    sources = sorted(
        os.path.relpath(os.path.join(directory, name), PROTO_SOURCE)
        for directory, _, names in os.walk(PROTO_SOURCE)
        for name in names
        if name.endswith(".proto")
    )
    fingerprint = hashlib.sha256(
        b"".join(open(os.path.join(PROTO_SOURCE, source), "rb").read() for source in sources)
        + open(os.path.join(SIGNAL_PROTO_SOURCE, "WhisperTextProtocol.proto"), "rb").read()
    ).hexdigest()
    if os.path.exists(marker) and open(marker).read() == fingerprint:
        return
    from grpc_tools import protoc

    os.makedirs(PROTO_OUT, exist_ok=True)
    result = protoc.main(["protoc", f"-I{PROTO_SOURCE}", f"--python_out={PROTO_OUT}", *sources])
    if result == 0:
        signal_args = ["protoc", f"-I{SIGNAL_PROTO_SOURCE}", f"--python_out={PROTO_OUT}", "WhisperTextProtocol.proto"]
        result = protoc.main(signal_args)
    if result != 0:
        raise SystemExit(f"protoc failed ({result})")
    for directory, _, names in os.walk(PROTO_OUT):
        if "__init__.py" not in names:
            open(os.path.join(directory, "__init__.py"), "w").close()
    with open(marker, "w") as file:
        file.write(fingerprint)


compile_protos()
sys.path.insert(0, PROTO_OUT)
waWa6 = importlib.import_module("waWa6.WAWebProtobufsWa6_pb2")
waCert = importlib.import_module("waCert.WACert_pb2")
waAdv = importlib.import_module("waAdv.WAAdv_pb2")
waCompanionReg = importlib.import_module("waCompanionReg.WACompanionReg_pb2")
waE2E = importlib.import_module("waE2E.WAWebProtobufsE2E_pb2")
waHistorySync = importlib.import_module("waHistorySync.WAWebProtobufsHistorySync_pb2")
waMmsRetry = importlib.import_module("waMmsRetry.WAMmsRetry_pb2")
whisper = importlib.import_module("WhisperTextProtocol_pb2")


# ---------------------------------------------------------------------------------------------------------
# Curve25519 keys and XEdDSA signatures (libsignal-go ecc/SignCurve25519.go)

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, -1, P)) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _recover_x(y: int, sign: int) -> int:
    x2 = (y * y - 1) * pow(D * y * y + 1, -1, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if x & 1 != sign:
        x = P - x
    return x


_BY = 4 * pow(5, -1, P) % P
BASE = (_recover_x(_BY, 0), _BY, 1, _recover_x(_BY, 0) * _BY % P)


def _add(p1: tuple, p2: tuple) -> tuple:
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _scalar_mult(scalar: int, point: tuple = BASE) -> tuple:
    result = (0, 1, 1, 0)
    while scalar:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _encode_point(point: tuple) -> bytes:
    x, y, z, _ = point
    zi = pow(z, -1, P)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _clamp(private: bytes) -> int:
    scalar = bytearray(private)
    scalar[0] &= 248
    scalar[31] &= 127
    scalar[31] |= 64
    return int.from_bytes(scalar, "little")


def xeddsa_sign(private: bytes, message: bytes) -> bytes:
    a = _clamp(private) % L
    public = _encode_point(_scalar_mult(a))
    random = secrets.token_bytes(64)
    r = int.from_bytes(hashlib.sha512(b"\xfe" + b"\xff" * 31 + private + message + random).digest(), "little") % L
    encoded_r = _encode_point(_scalar_mult(r))
    h = int.from_bytes(hashlib.sha512(encoded_r + public + message).digest(), "little") % L
    s = (r + h * a) % L
    signature = bytearray(encoded_r + int.to_bytes(s, 32, "little"))
    signature[63] |= public[31] & 0x80
    return bytes(signature)


def xeddsa_verify(public: bytes, message: bytes, signature: bytes) -> bool:
    if len(public) != 32 or len(signature) != 64:
        return False
    u = int.from_bytes(public, "little") & ((1 << 255) - 1)
    y = (u - 1) * pow(u + 1, -1, P) % P
    edwards = bytearray(int.to_bytes(y, 32, "little"))
    edwards[31] |= signature[63] & 0x80
    signature = bytearray(signature)
    signature[63] &= 0x7F
    try:
        Ed25519PublicKey.from_public_bytes(bytes(edwards)).verify(bytes(signature), message)
        return True
    except (InvalidSignature, ValueError):
        return False


@dataclass
class KeyPair:
    private: bytes
    public: bytes

    @staticmethod
    def generate() -> KeyPair:
        private = bytearray(secrets.token_bytes(32))
        private[0] &= 248
        private[31] &= 127
        private[31] |= 64
        return KeyPair.from_private(bytes(private))

    @staticmethod
    def from_private(private: bytes) -> KeyPair:
        public = X25519PrivateKey.from_private_bytes(private).public_key().public_bytes_raw()
        return KeyPair(private, public)

    def agree(self, public: bytes) -> bytes:
        return X25519PrivateKey.from_private_bytes(self.private).exchange(X25519PublicKey.from_public_bytes(public))

    def sign(self, message: bytes) -> bytes:
        return xeddsa_sign(self.private, message)

    def to_json(self) -> dict:
        return {"private": b64(self.private), "public": b64(self.public)}

    @staticmethod
    def from_json(data: dict) -> KeyPair:
        return KeyPair(unb64(data["private"]), unb64(data["public"]))


def hkdf(key: bytes, length: int, salt: bytes | None = None, info: bytes = b"") -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(key)


def aes_ctr(key: bytes, iv: bytes, data: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    return cipher.update(data) + cipher.finalize()


# ---------------------------------------------------------------------------------------------------------
# JIDs and binary XML nodes (whatsmeow binary/ and types/jid.go)

with open(TOKENS_PATH) as _file:
    _TOKENS = json.load(_file)
DICT_VERSION = _TOKENS["dictVersion"]
SINGLE_TOKENS: list[str] = _TOKENS["single"]
DOUBLE_TOKENS: list[list[str]] = _TOKENS["double"]
SINGLE_INDEX = {token: index for index, token in enumerate(SINGLE_TOKENS) if token}
DOUBLE_INDEX = {token: (dictionary, index) for dictionary, tokens in enumerate(DOUBLE_TOKENS) for index, token in enumerate(tokens)}

LIST_EMPTY, DICTIONARY_0, INTEROP_JID, FB_JID, AD_JID = 0, 236, 245, 246, 247
LIST_8, LIST_16, JID_PAIR, HEX_8, BINARY_8, BINARY_20, BINARY_32, NIBBLE_8 = 248, 249, 250, 251, 252, 253, 254, 255
PACKED_MAX = 127

USER_SERVER = "s.whatsapp.net"
LID_SERVER = "lid"
GROUP_SERVER = "g.us"
# Domain types in AD JIDs (whatsmeow types/jid.go).
DOMAIN_SERVERS = {0: USER_SERVER, 1: LID_SERVER, 128: "hosted", 129: "hosted.lid"}
SERVER_DOMAINS = {server: domain for domain, server in DOMAIN_SERVERS.items()}


@dataclass(frozen=True)
class JID:
    user: str
    server: str
    device: int = 0
    agent: int = 0

    @staticmethod
    def parse(text: str) -> JID:
        if "@" not in text:
            return JID("", text)
        user, server = text.split("@", 1)
        device = agent = 0
        if "." in user:
            user, ad = user.split(".", 1)
            agent_text, _, device_text = ad.partition(":")
            agent, device = int(agent_text), int(device_text or 0)
        elif ":" in user:
            user, device_text = user.split(":", 1)
            device = int(device_text)
        return JID(user, server, device, agent)

    def __str__(self) -> str:
        if not self.server:
            return ""
        if not self.user:
            return self.server
        if self.agent:
            return f"{self.user}.{self.agent}:{self.device}@{self.server}"
        if self.device:
            return f"{self.user}:{self.device}@{self.server}"
        return f"{self.user}@{self.server}"

    def non_ad(self) -> JID:
        return JID(self.user, self.server)

    def signal_address(self) -> str:
        """libsignal's address name.device, with the agent for non-default servers (whatsmeow SignalAddressUser)."""
        user = self.user
        if self.server == LID_SERVER:
            user = f"{user}_1"
        elif self.server == "hosted":
            user = f"{user}_128"
        elif self.server == "hosted.lid":
            user = f"{user}_129"
        elif self.agent:
            user = f"{user}_{self.agent}"
        return f"{user}.{self.device}"


SERVER_JID = JID("", USER_SERVER)


@dataclass
class Node:
    tag: str
    attrs: dict[str, Any]
    content: Any = None  # None, bytes, str or list[Node]

    def children(self) -> list[Node]:
        return self.content if isinstance(self.content, list) else []

    def child(self, *tags: str) -> Node | None:
        node: Node | None = self
        for tag in tags:
            node = next((child for child in node.children() if child.tag == tag), None) if node else None
        return node

    def attr(self, key: str, default: str = "") -> str:
        value = self.attrs.get(key)
        return default if value is None else str(value)

    def bytes(self) -> bytes:
        if isinstance(self.content, bytes):
            return self.content
        if isinstance(self.content, str):
            return self.content.encode()
        return b""

    def describe(self, depth: int = 0, redact: bool = True) -> str:
        """XML-ish rendering; binary contents show as their length so message payloads never print."""
        pad = "  " * depth
        attrs = "".join(f' {key}="{value}"' for key, value in self.attrs.items())
        if isinstance(self.content, list):
            inner = "\n".join(child.describe(depth + 1, redact) for child in self.content)
            return f"{pad}<{self.tag}{attrs}>\n{inner}\n{pad}</{self.tag}>"
        if isinstance(self.content, bytes):
            return f"{pad}<{self.tag}{attrs}>[{len(self.content)} bytes]</{self.tag}>"
        if isinstance(self.content, str):
            text = f"[{len(self.content)} chars]" if redact else self.content
            return f"{pad}<{self.tag}{attrs}>{text}</{self.tag}>"
        return f"{pad}<{self.tag}{attrs}/>"


class NodeEncoder:
    def __init__(self) -> None:
        self.data = bytearray([0])

    def byte_length(self, length: int) -> None:
        if length < 256:
            self.data += bytes([BINARY_8, length])
        elif length < 1 << 20:
            self.data += bytes([BINARY_20, (length >> 16) & 0x0F, (length >> 8) & 0xFF, length & 0xFF])
        else:
            self.data += bytes([BINARY_32]) + struct.pack(">I", length)

    def list_start(self, size: int) -> None:
        if size == 0:
            self.data.append(LIST_EMPTY)
        elif size < 256:
            self.data += bytes([LIST_8, size])
        else:
            self.data += bytes([LIST_16]) + struct.pack(">H", size)

    def node(self, node: Node) -> None:
        attrs = {key: value for key, value in node.attrs.items() if value is not None and value != ""}
        self.list_start(2 * len(attrs) + 1 + (node.content is not None))
        self.string(node.tag)
        for key, value in attrs.items():
            self.string(key)
            self.value(value)
        if node.content is not None:
            self.value(node.content)

    def value(self, value: Any) -> None:
        if value is None:
            self.data.append(LIST_EMPTY)
        elif isinstance(value, JID):
            self.jid(value)
        elif isinstance(value, bool):
            self.string("true" if value else "false")
        elif isinstance(value, int):
            self.string(str(value))
        elif isinstance(value, str):
            self.string(value)
        elif isinstance(value, (bytes, bytearray)):
            self.byte_length(len(value))
            self.data += value
        elif isinstance(value, list):
            self.list_start(len(value))
            for child in value:
                self.node(child)
        else:
            raise TypeError(f"can't encode {type(value)}")

    def string(self, text: str) -> None:
        if text in SINGLE_INDEX:
            self.data.append(SINGLE_INDEX[text])
        elif text in DOUBLE_INDEX:
            dictionary, index = DOUBLE_INDEX[text]
            self.data += bytes([DICTIONARY_0 + dictionary, index])
        elif len(text) <= PACKED_MAX and text and all(c.isdigit() or c in "-." for c in text):
            self.packed(text, NIBBLE_8)
        elif len(text) <= PACKED_MAX and text and all(c.isdigit() or c in "ABCDEF" for c in text):
            self.packed(text, HEX_8)
        else:
            raw = text.encode()
            self.byte_length(len(raw))
            self.data += raw

    def packed(self, text: str, kind: int) -> None:
        def pack(char: str) -> int:
            if char == "\0":
                return 15
            if kind == NIBBLE_8:
                return {"-": 10, ".": 11}.get(char, ord(char) - 48 if char.isdigit() else 0)
            return ord(char) - 48 if char.isdigit() else 10 + ord(char) - 65

        length = (len(text) + 1) // 2
        self.data += bytes([kind, length | (128 if len(text) % 2 else 0)])
        padded = text + ("\0" if len(text) % 2 else "")
        for index in range(0, len(padded), 2):
            self.data.append((pack(padded[index]) << 4) | pack(padded[index + 1]))

    def jid(self, jid: JID) -> None:
        if (jid.server in (USER_SERVER, LID_SERVER) and jid.device > 0) or jid.server in ("hosted", "hosted.lid"):
            domain = SERVER_DOMAINS.get(jid.server, jid.agent) if jid.server != USER_SERVER else jid.agent
            self.data += bytes([AD_JID, domain, jid.device])
            self.string(jid.user)
        else:
            self.data.append(JID_PAIR)
            if jid.user:
                self.string(jid.user)
            else:
                self.data.append(LIST_EMPTY)
            self.string(jid.server)


def encode_node(node: Node) -> bytes:
    encoder = NodeEncoder()
    encoder.node(node)
    return bytes(encoder.data)


class NodeDecoder:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.index = 0

    def take(self, count: int) -> bytes:
        if self.index + count > len(self.data):
            raise EOFError("node data ended early")
        chunk = self.data[self.index : self.index + count]
        self.index += count
        return chunk

    def int_n(self, count: int) -> int:
        return int.from_bytes(self.take(count), "big")

    def list_size(self, tag: int) -> int:
        if tag == LIST_EMPTY:
            return 0
        if tag == LIST_8:
            return self.int_n(1)
        if tag == LIST_16:
            return self.int_n(2)
        raise ValueError(f"bad list tag {tag} at {self.index}")

    def read(self, as_string: bool) -> Any:
        tag = self.int_n(1)
        if tag == LIST_EMPTY:
            return None
        if tag in (LIST_8, LIST_16):
            return self.list(tag)
        if tag in (BINARY_8, BINARY_20, BINARY_32):
            if tag == BINARY_8:
                size = self.int_n(1)
            elif tag == BINARY_20:
                raw = self.take(3)
                size = ((raw[0] & 15) << 16) | (raw[1] << 8) | raw[2]
            else:
                size = self.int_n(4)
            data = self.take(size)
            return data.decode() if as_string else data
        if DICTIONARY_0 <= tag <= DICTIONARY_0 + 3:
            return DOUBLE_TOKENS[tag - DICTIONARY_0][self.int_n(1)]
        if tag == JID_PAIR:
            user = self.read(True)
            server = self.read(True)
            return JID(user or "", server)
        if tag == AD_JID:
            domain = self.int_n(1)
            device = self.int_n(1)
            user = self.read(True)
            if domain in DOMAIN_SERVERS and domain != 0:
                return JID(user, DOMAIN_SERVERS[domain], device)
            return JID(user, USER_SERVER, device, domain)
        if tag == FB_JID:
            user = self.read(True)
            device = self.int_n(2)
            server = self.read(True)
            return JID(user, server, device)
        if tag == INTEROP_JID:
            user = self.read(True)
            device = self.int_n(2)
            self.int_n(2)
            server = self.read(True)
            return JID(user, server, device)
        if tag in (NIBBLE_8, HEX_8):
            return self.packed(tag)
        if 1 <= tag < len(SINGLE_TOKENS):
            return SINGLE_TOKENS[tag]
        raise ValueError(f"invalid token {tag} at {self.index}")

    def packed(self, tag: int) -> str:
        start = self.int_n(1)
        chars = []
        for _ in range(start & 127):
            byte = self.int_n(1)
            for nibble in (byte >> 4, byte & 0x0F):
                if tag == NIBBLE_8:
                    chars.append({10: "-", 11: ".", 15: "\0"}.get(nibble, str(nibble) if nibble < 10 else "?"))
                else:
                    chars.append(str(nibble) if nibble < 10 else chr(65 + nibble - 10))
        text = "".join(chars)
        return text[:-1] if start >> 7 and text else text

    def list(self, tag: int) -> list[Node]:
        return [self.node() for _ in range(self.list_size(tag))]

    def node(self) -> Node:
        size = self.list_size(self.int_n(1))
        tag = self.read(True)
        if size == 0 or not tag:
            raise ValueError("invalid node")
        attrs = {}
        for _ in range((size - 1) >> 1):
            key = self.read(True)
            attrs[key] = self.read(True)
        content = None if size % 2 == 1 else self.read(False)
        return Node(str(tag), attrs, content)


def decode_frame(data: bytes) -> Node:
    flags, data = data[0], data[1:]
    if flags & 2:
        data = zlib.decompress(data)
    decoder = NodeDecoder(data)
    node = decoder.node()
    if decoder.index != len(data):
        raise ValueError(f"{len(data) - decoder.index} leftover bytes")
    return node


# ---------------------------------------------------------------------------------------------------------
# Session store


class Session:
    def __init__(self, data: dict) -> None:
        self.data = data

    @staticmethod
    def load() -> Session | None:
        if not os.path.exists(SESSION_PATH):
            return None
        with open(SESSION_PATH) as file:
            return Session(json.load(file))

    @staticmethod
    def create() -> Session:
        identity = KeyPair.generate()
        signed = KeyPair.generate()
        return Session(
            {
                "noiseKey": KeyPair.generate().to_json(),
                "identityKey": identity.to_json(),
                "signedPreKey": {
                    "id": 1,
                    **signed.to_json(),
                    "signature": b64(identity.sign(bytes([DJB_TYPE]) + signed.public)),
                },
                "registrationId": secrets.randbits(32),
                "advSecret": b64(secrets.token_bytes(32)),
                "preKeys": {},
                "nextPreKeyId": 1,
                "uploadedPreKeyId": 0,
            }
        )

    def save(self) -> None:
        os.makedirs(os.path.dirname(SESSION_PATH), exist_ok=True)
        temporary = SESSION_PATH + ".tmp"
        with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(self.data, file, indent=1)
        os.replace(temporary, SESSION_PATH)

    @property
    def noise_key(self) -> KeyPair:
        return KeyPair.from_json(self.data["noiseKey"])

    @property
    def identity_key(self) -> KeyPair:
        return KeyPair.from_json(self.data["identityKey"])

    @property
    def jid(self) -> JID | None:
        return JID.parse(self.data["jid"]) if self.data.get("jid") else None

    @property
    def lid(self) -> JID | None:
        return JID.parse(self.data["lid"]) if self.data.get("lid") else None


def wa_version(session: Session | None) -> tuple[int, int, int]:
    if session and session.data.get("waVersion"):
        return tuple(session.data["waVersion"])
    return DEFAULT_WA_VERSION


def fetch_wa_version() -> tuple[int, int, int]:
    """The current web client revision, as Baileys reads it (Utils/generics.ts fetchLatestWaWebVersion)."""
    request = urllib.request.Request(
        "https://web.whatsapp.com/sw.js",
        # Without Sec-Fetch-Site the page answers 400 (observed 2026-10-30).
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Sec-Fetch-Site": "none",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read().decode()
    match = re.search(r'\\?"client_revision\\?":\s*(\d+)', body)
    if not match:
        raise SystemExit("client_revision not found in sw.js")
    return (2, 3000, int(match.group(1)))


# ---------------------------------------------------------------------------------------------------------
# Signal protocol (libsignal-go session/, ratchet/, groups/; state kept as JSON in the session file)

MAX_MESSAGE_KEYS = 2000
MAX_RECEIVER_CHAINS = 5
MAX_ARCHIVED_STATES = 40
MAX_SENDER_KEY_STATES = 5
SIGNAL_VERSION = 3


class SignalError(Exception):
    pass


class OldCounterError(SignalError):
    pass


def djb(public: bytes) -> bytes:
    return bytes([DJB_TYPE]) + public


def undjb(public: bytes) -> bytes:
    if len(public) == 33 and public[0] == DJB_TYPE:
        return public[1:]
    if len(public) == 32:
        return public
    raise SignalError(f"bad public key ({len(public)} bytes)")


def aes_cbc_encrypt(key: bytes, iv: bytes, plaintext: bytes) -> bytes:
    pad = 16 - len(plaintext) % 16
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return encryptor.update(plaintext + bytes([pad]) * pad) + encryptor.finalize()


def aes_cbc_decrypt(key: bytes, iv: bytes, ciphertext: bytes) -> bytes:
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()
    pad = padded[-1] if padded else 0
    if not 1 <= pad <= 16 or padded[-pad:] != bytes([pad]) * pad:
        raise SignalError("bad CBC padding")
    return padded[:-pad]


def chain_message_keys(chain_key: bytes) -> dict:
    material = hkdf(hmac.new(chain_key, b"\x01", hashlib.sha256).digest(), 80, info=b"WhisperMessageKeys")
    return {"cipherKey": material[:32], "macKey": material[32:64], "iv": material[64:80]}


def chain_next(chain_key: bytes) -> bytes:
    return hmac.new(chain_key, b"\x02", hashlib.sha256).digest()


def root_create_chain(root_key: bytes, their_ratchet: bytes, our_ratchet: KeyPair) -> tuple[bytes, bytes]:
    derived = hkdf(our_ratchet.agree(their_ratchet), 64, salt=root_key, info=b"WhisperRatchet")
    return derived[:32], derived[32:]


def _bytes_fields(data: Any, decode: bool) -> Any:
    """State is held with bytes in memory and base64 strings in JSON."""
    if isinstance(data, dict):
        return {key: _bytes_fields(value, decode) for key, value in data.items()}
    if isinstance(data, list):
        return [_bytes_fields(value, decode) for value in data]
    if decode and isinstance(data, str) and data.startswith("b64:"):
        return unb64(data[4:])
    if not decode and isinstance(data, (bytes, bytearray)):
        return "b64:" + b64(bytes(data))
    return data


class SignalStore:
    """Sessions, identities and sender keys, persisted in the session file."""

    def __init__(self, session: Session) -> None:
        self.session = session
        data = session.data
        self.sessions: dict[str, dict] = _bytes_fields(data.setdefault("signalSessions", {}), True)
        self.sender_keys: dict[str, list] = _bytes_fields(data.setdefault("senderKeys", {}), True)
        data.setdefault("identities", {})

    def save(self) -> None:
        self.session.data["signalSessions"] = _bytes_fields(self.sessions, False)
        self.session.data["senderKeys"] = _bytes_fields(self.sender_keys, False)
        self.session.save()

    def record(self, address: str) -> dict:
        return copy.deepcopy(self.sessions.get(address) or {"current": None, "previous": []})

    def store_record(self, address: str, record: dict) -> None:
        self.sessions[address] = record

    def save_identity(self, address: str, identity: bytes) -> None:
        self.session.data["identities"][address] = b64(undjb(identity))

    def trusted(self, address: str, identity: bytes) -> bool:
        known = self.session.data["identities"].get(address)
        return known is None or unb64(known) == undjb(identity)

    @property
    def identity(self) -> KeyPair:
        return self.session.identity_key

    @property
    def registration_id(self) -> int:
        return self.session.data["registrationId"]

    # --- one-to-one sessions

    def decrypt_prekey_message(self, address: str, raw: bytes, keep_state: bool = True) -> bytes:
        if raw[0] >> 4 != SIGNAL_VERSION:
            raise SignalError(f"unsupported prekey message version {raw[0] >> 4}")
        message = whisper.PreKeySignalMessage.FromString(raw[1:])
        record = self.record(address)
        if not self.trusted(address, message.identityKey):
            # whatsmeow's AutoTrustIdentity: forget the old identity and session, then build a new one.
            log(f"identity changed for {address}; trusting the new one")
            record = {"current": None, "previous": []}
        used_prekey = self._process_prekey_message(record, message)
        plaintext = self._decrypt_with_record(record, message.message)
        if keep_state:
            self.store_record(address, record)
            self.save_identity(address, message.identityKey)
            if used_prekey is not None:
                self.session.data["preKeys"].pop(str(used_prekey), None)
            self.save()
        return plaintext

    def decrypt_message(self, address: str, raw: bytes) -> bytes:
        if address not in self.sessions:
            raise SignalError(f"no session for {address}")
        record = self.record(address)
        plaintext = self._decrypt_with_record(record, raw)
        self.store_record(address, record)
        self.save()
        return plaintext

    def _process_prekey_message(self, record: dict, message: Any) -> int | None:
        states = [record["current"], *record["previous"]]
        if any(state and state["version"] == SIGNAL_VERSION and state["senderBaseKey"] == message.baseKey for state in states):
            return None
        signed = self.session.data["signedPreKey"]
        if message.signedPreKeyId != signed["id"]:
            raise SignalError(f"no signed prekey {message.signedPreKeyId}")
        our_signed = KeyPair(unb64(signed["private"]), unb64(signed["public"]))
        their_base = undjb(message.baseKey)
        their_identity = undjb(message.identityKey)
        secrets_ = [b"\xff" * 32, our_signed.agree(their_identity), self.identity.agree(their_base), our_signed.agree(their_base)]
        prekey_id = message.preKeyId if message.HasField("preKeyId") and message.preKeyId else None
        if prekey_id is not None:
            stored = self.session.data["preKeys"].get(str(prekey_id))
            if not stored:
                raise SignalError(f"no one-time prekey {prekey_id}")
            secrets_.append(KeyPair.from_json(stored).agree(their_base))
        derived = hkdf(b"".join(secrets_), 64, info=b"WhisperText")
        if record["current"]:
            record["previous"].insert(0, record["current"])
            del record["previous"][MAX_ARCHIVED_STATES:]
        record["current"] = {
            "version": SIGNAL_VERSION,
            "remoteIdentity": djb(their_identity),
            "localIdentity": djb(self.identity.public),
            "rootKey": derived[:32],
            "previousCounter": 0,
            "senderChain": {"private": our_signed.private, "public": our_signed.public, "key": derived[32:], "index": 0},
            "receiverChains": [],
            "pendingPreKey": None,
            "localRegistrationId": self.registration_id,
            "remoteRegistrationId": message.registrationId,
            "senderBaseKey": message.baseKey,
        }
        return prekey_id

    def _decrypt_with_record(self, record: dict, raw: bytes) -> bytes:
        candidates = [record["current"], *record["previous"]]
        last_error: Exception | None = None
        for index, state in enumerate(candidates):
            if not state:
                continue
            attempt = copy.deepcopy(state)
            try:
                plaintext = self._decrypt_with_state(attempt, raw)
            except OldCounterError:
                raise
            except Exception as error:  # noqa: BLE001
                last_error = error
                continue
            if index == 0:
                record["current"] = attempt
            else:
                del record["previous"][index - 1]
                record["previous"].insert(0, record["current"])
                record["current"] = attempt
            return plaintext
        raise SignalError(f"no valid session ({last_error})")

    def _decrypt_with_state(self, state: dict, raw: bytes) -> bytes:
        if raw[0] >> 4 != state["version"]:
            raise SignalError("wrong message version")
        message = whisper.SignalMessage.FromString(raw[1:-8])
        their_ratchet = undjb(message.ratchetKey)
        chain = self._receiver_chain(state, their_ratchet)
        keys = self._message_keys(chain, message.counter)
        mac = hmac.new(keys["macKey"], state["remoteIdentity"] + state["localIdentity"] + raw[:-8], hashlib.sha256).digest()[:8]
        if not hmac.compare_digest(mac, raw[-8:]):
            raise SignalError("bad MAC")
        plaintext = aes_cbc_decrypt(keys["cipherKey"], keys["iv"], message.ciphertext)
        state["pendingPreKey"] = None
        return plaintext

    def _receiver_chain(self, state: dict, their_ratchet: bytes) -> dict:
        for chain in state["receiverChains"]:
            if chain["ratchet"] == their_ratchet:
                return chain
        sender = state["senderChain"]
        root, receive_key = root_create_chain(state["rootKey"], their_ratchet, KeyPair(sender["private"], sender["public"]))
        new_ratchet = KeyPair.generate()
        root, send_key = root_create_chain(root, their_ratchet, new_ratchet)
        state["rootKey"] = root
        chain = {"ratchet": their_ratchet, "key": receive_key, "index": 0, "messageKeys": []}
        state["receiverChains"].append(chain)
        del state["receiverChains"][:-MAX_RECEIVER_CHAINS]
        state["previousCounter"] = max(sender["index"] - 1, 0)
        state["senderChain"] = {"private": new_ratchet.private, "public": new_ratchet.public, "key": send_key, "index": 0}
        return chain

    @staticmethod
    def _message_keys(chain: dict, counter: int) -> dict:
        if chain["index"] > counter:
            for index, keys in enumerate(chain["messageKeys"]):
                if keys["index"] == counter:
                    return chain["messageKeys"].pop(index)
            raise OldCounterError(f"old counter {counter} (chain at {chain['index']})")
        if counter - chain["index"] > MAX_MESSAGE_KEYS:
            raise SignalError("message too far into the future")
        while chain["index"] < counter:
            chain["messageKeys"].append({"index": chain["index"], **chain_message_keys(chain["key"])})
            del chain["messageKeys"][:-MAX_MESSAGE_KEYS]
            chain["key"] = chain_next(chain["key"])
            chain["index"] += 1
        keys = chain_message_keys(chain["key"])
        chain["key"] = chain_next(chain["key"])
        chain["index"] += 1
        return keys

    def has_session(self, address: str) -> bool:
        record = self.sessions.get(address)
        return bool(record and record.get("current"))

    def build_session(self, address: str, bundle: dict) -> None:
        """X3DH as the initiator from a fetched prekey bundle (libsignal-go Builder.ProcessBundle)."""
        identity = bundle["identity"]
        if not xeddsa_verify(identity, djb(bundle["signedPreKey"]), bundle["signature"]):
            raise SignalError("invalid signed prekey signature")
        if not self.trusted(address, identity):
            log(f"identity changed for {address}; trusting the new one")
        record = self.record(address)
        base = KeyPair.generate()
        secrets_ = [b"\xff" * 32, self.identity.agree(bundle["signedPreKey"]), base.agree(identity), base.agree(bundle["signedPreKey"])]
        if bundle.get("preKey"):
            secrets_.append(base.agree(bundle["preKey"]))
        derived = hkdf(b"".join(secrets_), 64, info=b"WhisperText")
        sending = KeyPair.generate()
        root, send_key = root_create_chain(derived[:32], bundle["signedPreKey"], sending)
        if record["current"]:
            record["previous"].insert(0, record["current"])
            del record["previous"][MAX_ARCHIVED_STATES:]
        record["current"] = {
            "version": SIGNAL_VERSION,
            "remoteIdentity": djb(identity),
            "localIdentity": djb(self.identity.public),
            "rootKey": root,
            "previousCounter": 0,
            "senderChain": {"private": sending.private, "public": sending.public, "key": send_key, "index": 0},
            "receiverChains": [{"ratchet": bundle["signedPreKey"], "key": derived[32:], "index": 0, "messageKeys": []}],
            "pendingPreKey": {"preKeyId": bundle.get("preKeyId"), "signedPreKeyId": bundle["signedPreKeyId"], "baseKey": djb(base.public)},
            "localRegistrationId": self.registration_id,
            "remoteRegistrationId": bundle["registrationId"],
            "senderBaseKey": djb(base.public),
        }
        self.store_record(address, record)
        self.save_identity(address, identity)
        self.save()

    def encrypt(self, address: str, plaintext: bytes) -> tuple[str, bytes]:
        """Returns ("pkmsg" or "msg", serialized message) and advances the sending chain."""
        record = self.record(address)
        state = record["current"]
        if not state:
            raise SignalError(f"no session for {address}")
        chain = state["senderChain"]
        keys = chain_message_keys(chain["key"])
        body = whisper.SignalMessage(
            ratchetKey=djb(chain["public"]), counter=chain["index"], previousCounter=state["previousCounter"],
            ciphertext=aes_cbc_encrypt(keys["cipherKey"], keys["iv"], plaintext),
        ).SerializeToString()
        serialized = bytes([(SIGNAL_VERSION << 4) | SIGNAL_VERSION]) + body
        mac = hmac.new(keys["macKey"], state["localIdentity"] + state["remoteIdentity"] + serialized, hashlib.sha256).digest()[:8]
        message, kind = serialized + mac, "msg"
        pending = state.get("pendingPreKey")
        if pending:
            prekey = whisper.PreKeySignalMessage(
                registrationId=state["localRegistrationId"], signedPreKeyId=pending["signedPreKeyId"],
                baseKey=pending["baseKey"], identityKey=state["localIdentity"], message=message,
            )
            if pending.get("preKeyId") is not None:
                prekey.preKeyId = pending["preKeyId"]
            message, kind = bytes([(SIGNAL_VERSION << 4) | SIGNAL_VERSION]) + prekey.SerializeToString(), "pkmsg"
        chain["key"] = chain_next(chain["key"])
        chain["index"] += 1
        self.store_record(address, record)
        self.save()
        return kind, message

    # --- sender keys (groups)

    def process_sender_key_distribution(self, group: str, address: str, raw: bytes) -> None:
        message = whisper.SenderKeyDistributionMessage.FromString(raw[1:])
        name = f"{group}|{address}"
        states = self.sender_keys.get(name, [])
        states.insert(0, {"id": message.id, "iteration": message.iteration, "chainKey": message.chainKey, "signingKey": undjb(message.signingKey), "messageKeys": []})
        self.sender_keys[name] = states[:MAX_SENDER_KEY_STATES]
        self.save()

    def decrypt_group_message(self, group: str, address: str, raw: bytes) -> bytes:
        name = f"{group}|{address}"
        states = self.sender_keys.get(name)
        if not states:
            raise SignalError(f"no sender key for {address} in {group}")
        message = whisper.SenderKeyMessage.FromString(raw[1:-64])
        state = next((state for state in states if state["id"] == message.id), None)
        if not state:
            raise SignalError(f"no sender key state {message.id}")
        if not xeddsa_verify(state["signingKey"], raw[:-64], raw[-64:]):
            raise SignalError("bad sender key signature")
        attempt = copy.deepcopy(state)
        seed = self._sender_message_seed(attempt, message.iteration)
        derived = hkdf(seed, 48, info=b"WhisperGroup")
        plaintext = aes_cbc_decrypt(derived[16:48], derived[:16], message.ciphertext)
        state.update(attempt)
        self.save()
        return plaintext

    @staticmethod
    def _sender_message_seed(state: dict, iteration: int) -> bytes:
        if state["iteration"] > iteration:
            for index, keys in enumerate(state["messageKeys"]):
                if keys["iteration"] == iteration:
                    return state["messageKeys"].pop(index)["seed"]
            raise OldCounterError(f"old sender key iteration {iteration} (at {state['iteration']})")
        if iteration - state["iteration"] > MAX_MESSAGE_KEYS:
            raise SignalError("sender key message too far into the future")
        while state["iteration"] < iteration:
            state["messageKeys"].append({"iteration": state["iteration"], "seed": hmac.new(state["chainKey"], b"\x01", hashlib.sha256).digest()})
            del state["messageKeys"][:-MAX_MESSAGE_KEYS]
            state["chainKey"] = hmac.new(state["chainKey"], b"\x02", hashlib.sha256).digest()
            state["iteration"] += 1
        seed = hmac.new(state["chainKey"], b"\x01", hashlib.sha256).digest()
        state["chainKey"] = hmac.new(state["chainKey"], b"\x02", hashlib.sha256).digest()
        state["iteration"] += 1
        return seed


def unpad_message(plaintext: bytes, version: int) -> bytes:
    if version == 3:
        return plaintext
    if not plaintext:
        raise SignalError("empty plaintext")
    pad = plaintext[-1]
    if pad == 0 or plaintext[-pad:] != bytes([pad]) * pad:
        raise SignalError("bad message padding")
    return plaintext[:-pad]


def pad_message(plaintext: bytes) -> bytes:
    pad = secrets.randbelow(16) or 15
    return plaintext + bytes([pad]) * pad


# ---------------------------------------------------------------------------------------------------------
# Client payload (whatsmeow store/clientpayload.go)


def base_payload(version: tuple[int, int, int]) -> Any:
    payload = waWa6.ClientPayload()
    agent = payload.userAgent
    agent.platform = waWa6.ClientPayload.UserAgent.WEB
    agent.releaseChannel = waWa6.ClientPayload.UserAgent.RELEASE
    agent.appVersion.primary, agent.appVersion.secondary, agent.appVersion.tertiary = version
    agent.mcc = "000"
    agent.mnc = "000"
    agent.osVersion = "0.1"
    agent.manufacturer = ""
    agent.device = "Desktop"
    agent.osBuildNumber = "0.1"
    agent.localeLanguageIso6391 = "en"
    agent.localeCountryIso31661Alpha2 = "US"
    payload.webInfo.webSubPlatform = waWa6.ClientPayload.WebInfo.WEB_BROWSER
    payload.connectType = waWa6.ClientPayload.WIFI_UNKNOWN
    payload.connectReason = waWa6.ClientPayload.USER_ACTIVATED
    return payload


def device_props() -> bytes:
    props = waCompanionReg.DeviceProps()
    props.os = DEVICE_NAME
    props.version.primary, props.version.secondary, props.version.tertiary = 0, 1, 0
    sync = props.historySyncConfig
    sync.storageQuotaMb = 10240
    sync.inlineInitialPayloadInE2EeMsg = True
    sync.supportCallLogHistory = False
    sync.supportBotUserAgentChatHistory = True
    sync.supportCagReactionsAndPolls = True
    sync.supportBizHostedMsg = True
    sync.supportRecentSyncChunkMessageCountTuning = True
    sync.supportHostedGroupMsg = True
    sync.supportFbidBotChatHistory = True
    sync.supportMessageAssociation = True
    sync.supportGroupHistory = True
    sync.thumbnailSyncDaysLimit = 60
    props.platformType = PLATFORM_TYPE_SAFARI
    props.requireFullSync = False
    return props.SerializeToString()


def client_payload(session: Session) -> bytes:
    version = wa_version(session)
    payload = base_payload(version)
    jid = session.jid
    if jid:
        payload.username = int(jid.user)
        payload.device = jid.device
        payload.passive = True
        payload.pull = True
        payload.lidDbMigrated = True
        payload.lc = 1
    else:
        signed = session.data["signedPreKey"]
        registration = payload.devicePairingData
        registration.eRegid = struct.pack(">I", session.data["registrationId"])
        registration.eKeytype = bytes([DJB_TYPE])
        registration.eIdent = session.identity_key.public
        registration.eSkeyID = struct.pack(">I", signed["id"])[1:]
        registration.eSkeyVal = unb64(signed["public"])
        registration.eSkeySig = unb64(signed["signature"])
        registration.buildHash = hashlib.md5(".".join(map(str, version)).encode()).digest()
        registration.deviceProps = device_props()
        payload.passive = False
        payload.pull = False
    return payload.SerializeToString()


# ---------------------------------------------------------------------------------------------------------
# Noise transport (whatsmeow socket/ and handshake.go)


def _iv(counter: int) -> bytes:
    return b"\0" * 8 + struct.pack(">I", counter)


class NoiseHandshake:
    def __init__(self, header: bytes) -> None:
        self.hash = NOISE_PATTERN if len(NOISE_PATTERN) == 32 else hashlib.sha256(NOISE_PATTERN).digest()
        self.salt = self.hash
        self.key = AESGCM(self.hash)
        self.counter = 0
        self.authenticate(header)

    def authenticate(self, data: bytes) -> None:
        self.hash = hashlib.sha256(self.hash + data).digest()

    def encrypt(self, plaintext: bytes) -> bytes:
        ciphertext = self.key.encrypt(_iv(self.counter), plaintext, self.hash)
        self.counter += 1
        self.authenticate(ciphertext)
        return ciphertext

    def decrypt(self, ciphertext: bytes) -> bytes:
        plaintext = self.key.decrypt(_iv(self.counter), ciphertext, self.hash)
        self.counter += 1
        self.authenticate(ciphertext)
        return plaintext

    def mix_into_key(self, data: bytes) -> None:
        self.counter = 0
        keys = hkdf(data, 64, salt=self.salt)
        self.salt = keys[:32]
        self.key = AESGCM(keys[32:])

    def finish(self) -> tuple[AESGCM, AESGCM]:
        keys = hkdf(b"", 64, salt=self.salt)
        return AESGCM(keys[:32]), AESGCM(keys[32:])


def verify_server_certificate(certificate: bytes, server_static: bytes) -> None:
    chain = waCert.CertChain.FromString(certificate)
    intermediate, leaf = chain.intermediate, chain.leaf
    if not xeddsa_verify(WA_CERT_PUBLIC_KEY, intermediate.details, intermediate.signature):
        raise ValueError("intermediate certificate signature is invalid")
    intermediate_details = waCert.CertChain.NoiseCertificate.Details.FromString(intermediate.details)
    if intermediate_details.issuerSerial != 0:
        raise ValueError("unexpected intermediate issuer")
    if not xeddsa_verify(intermediate_details.key, leaf.details, leaf.signature):
        raise ValueError("leaf certificate signature is invalid")
    leaf_details = waCert.CertChain.NoiseCertificate.Details.FromString(leaf.details)
    if leaf_details.issuerSerial != intermediate_details.serial:
        raise ValueError("unexpected leaf issuer")
    if not hmac.compare_digest(leaf_details.key, server_static):
        raise ValueError("certificate key doesn't match the server's static key")
    now = time.time()
    for details in (intermediate_details, leaf_details):
        if not details.notBefore <= now <= details.notAfter:
            raise ValueError("certificate is outside its validity period")


class Connection:
    """One WebSocket: frames are a 3-byte length then the payload; the first frame carries the WA header."""

    def __init__(self, websocket: Any) -> None:
        self.websocket = websocket
        self.header = b"WA" + bytes([6, DICT_VERSION])
        self.buffer = b""
        self.frames: asyncio.Queue[bytes | None] = asyncio.Queue()
        self.write_key: AESGCM | None = None
        self.read_key: AESGCM | None = None
        self.write_counter = 0
        self.read_counter = 0
        self.reader = asyncio.create_task(self.read_loop())

    async def read_loop(self) -> None:
        try:
            async for message in self.websocket:
                self.buffer += message
                while len(self.buffer) >= 3:
                    length = int.from_bytes(self.buffer[:3], "big")
                    if len(self.buffer) < 3 + length:
                        break
                    frame, self.buffer = self.buffer[3 : 3 + length], self.buffer[3 + length :]
                    await self.frames.put(frame)
        except Exception as error:  # noqa: BLE001
            log(f"socket closed: {type(error).__name__}: {error}")
        await self.frames.put(None)

    async def send_raw(self, data: bytes) -> None:
        frame = self.header + len(data).to_bytes(3, "big") + data
        self.header = b""
        await self.websocket.send(frame)

    async def receive_raw(self, timeout: float = 20) -> bytes:
        frame = await asyncio.wait_for(self.frames.get(), timeout)
        if frame is None:
            raise ConnectionError("socket closed")
        return frame

    async def handshake(self, session: Session) -> None:
        ephemeral = KeyPair.generate()
        noise = NoiseHandshake(self.header)
        noise.authenticate(ephemeral.public)
        hello = waWa6.HandshakeMessage()
        hello.clientHello.ephemeral = ephemeral.public
        await self.send_raw(hello.SerializeToString())

        response = waWa6.HandshakeMessage.FromString(await self.receive_raw())
        server = response.serverHello
        noise.authenticate(server.ephemeral)
        noise.mix_into_key(ephemeral.agree(server.ephemeral))
        server_static = noise.decrypt(server.static)
        noise.mix_into_key(ephemeral.agree(server_static))
        verify_server_certificate(noise.decrypt(server.payload), server_static)

        noise_key = session.noise_key
        encrypted_static = noise.encrypt(noise_key.public)
        noise.mix_into_key(noise_key.agree(server.ephemeral))
        finish = waWa6.HandshakeMessage()
        finish.clientFinish.static = encrypted_static
        finish.clientFinish.payload = noise.encrypt(client_payload(session))
        await self.send_raw(finish.SerializeToString())
        self.write_key, self.read_key = noise.finish()

    async def send(self, node: Node) -> None:
        ciphertext = self.write_key.encrypt(_iv(self.write_counter), encode_node(node), None)
        self.write_counter += 1
        await self.send_raw(ciphertext)

    async def receive(self) -> Node | None:
        frame = await self.frames.get()
        if frame is None:
            return None
        plaintext = self.read_key.decrypt(_iv(self.read_counter), frame, None)
        self.read_counter += 1
        return decode_frame(plaintext)


# ---------------------------------------------------------------------------------------------------------
# Client


class StreamEnded(Exception):
    pass


class Client:
    def __init__(self, session: Session, verbose: bool = False) -> None:
        self.session = session
        self.verbose = verbose
        self.connection: Connection | None = None
        self.waiters: dict[str, asyncio.Future] = {}
        self.prefix = f"{secrets.randbelow(65536)}.{secrets.randbelow(65536)}-"
        self.counter = 0
        self.handlers: dict[str, Any] = {}
        self.events: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
        self.tasks: set[asyncio.Task] = set()

    def request_id(self) -> str:
        self.counter += 1
        return f"{self.prefix}{self.counter}"

    async def connect(self) -> None:
        import websockets

        websocket = await websockets.connect(
            SOCKET_URL,
            additional_headers={"Origin": ORIGIN, "Cache-Control": "no-cache", "Pragma": "no-cache"},
            max_size=1 << 24,
            ping_interval=None,
        )
        self.connection = Connection(websocket)
        await self.connection.handshake(self.session)
        self.spawn(self.receive_loop())
        # whatsmeow starts keepalives on connect, before login; WhatsApp drops a silent socket.
        self.spawn(self.keepalive_loop())

    async def keepalive_loop(self) -> None:
        while True:
            await asyncio.sleep(20 + secrets.randbelow(10))
            try:
                await self.iq("w:p", "get", timeout=10)
            except TimeoutError:
                log("keepalive timed out")

    def spawn(self, coroutine: Any) -> None:
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self._task_done)

    def _task_done(self, task: asyncio.Task) -> None:
        self.tasks.discard(task)
        if not task.cancelled() and task.exception():
            error = task.exception()
            log(f"task failed: {type(error).__name__}: {error}")
            self.events.put_nowait(("error", error))

    async def close(self) -> None:
        for task in list(self.tasks):
            task.cancel()
        if self.connection:
            await self.connection.websocket.close()

    async def send(self, node: Node) -> None:
        if self.verbose:
            log("→", node.describe())
        await self.connection.send(node)

    async def iq(self, xmlns: str, kind: str, content: Any = None, to: JID = SERVER_JID, timeout: float = 60, **attrs: Any) -> Node:
        request_id = self.request_id()
        future = asyncio.get_running_loop().create_future()
        self.waiters[request_id] = future
        await self.send(Node("iq", {"id": request_id, "xmlns": xmlns, "type": kind, "to": to, **attrs}, content))
        try:
            response = await asyncio.wait_for(future, timeout)
        finally:
            self.waiters.pop(request_id, None)
        if response.attr("type") == "error":
            raise IQError(response)
        return response

    async def send_and_wait(self, node: Node, identifier: str, timeout: float = 60) -> Node:
        """Sends a stanza and waits for the server's <ack> with the same id."""
        future = asyncio.get_running_loop().create_future()
        self.waiters[identifier] = future
        try:
            await self.send(node)
            return await asyncio.wait_for(future, timeout)
        finally:
            self.waiters.pop(identifier, None)

    async def receive_loop(self) -> None:
        while True:
            node = await self.connection.receive()
            if node is None:
                await self.events.put(("closed", None))
                return
            if self.verbose:
                log("←", node.describe())
            if node.tag == "iq" and node.attr("type") in ("result", "error") and node.attr("id") in self.waiters:
                self.waiters[node.attr("id")].set_result(node)
                continue
            if node.tag == "ack" and node.attr("id") in self.waiters:
                self.waiters[node.attr("id")].set_result(node)
                continue
            handler = self.handlers.get(node.tag)
            if handler:
                self.spawn(handler(node))
            elif node.tag not in ("ack",):
                log(f"unhandled <{node.tag}>")

    async def ack(self, node: Node) -> None:
        attrs = {"class": node.tag, "id": node.attrs.get("id"), "to": node.attrs.get("from")}
        for key in ("participant", "recipient"):
            if key in node.attrs:
                attrs[key] = node.attrs[key]
        if node.tag != "message" and "type" in node.attrs:
            attrs["type"] = node.attrs["type"]
        await self.send(Node("ack", attrs))


class IQError(Exception):
    def __init__(self, node: Node) -> None:
        error = node.child("error")
        self.code = error.attr("code") if error else ""
        self.text = error.attr("text") if error else ""
        # The whole error node, so hints beyond code/text (such as a retry time on 429) aren't lost.
        super().__init__(f"iq error {self.code} {self.text}: {error if error else node}")


# ---------------------------------------------------------------------------------------------------------
# Linking (whatsmeow pair.go, pair-code.go)


class Linker:
    def __init__(self, client: Client, phone: str | None) -> None:
        self.client = client
        self.phone = phone
        self.pairing: dict | None = None
        self.code_requested = False
        self.attach(client)

    def attach(self, client: Client) -> None:
        """Handles a (re)connected client's linking stanzas, keeping the pairing state of earlier connections."""
        self.client = client
        client.handlers["iq"] = self.handle_iq
        client.handlers["notification"] = self.handle_notification

    async def handle_iq(self, node: Node) -> None:
        if node.attrs.get("from") != SERVER_JID or len(node.children()) != 1:
            return
        child = node.children()[0]
        if child.tag == "pair-device":
            await self.client.send(Node("iq", {"to": node.attrs["from"], "id": node.attr("id"), "type": "result"}))
            if self.phone:
                if not self.code_requested:
                    self.code_requested = True
                    await self.request_code()
            else:
                session = self.client.session
                refs = [ref.bytes().decode() for ref in child.children() if ref.tag == "ref"]
                self.client.spawn(self.rotate_qr(refs))
        elif child.tag == "pair-success":
            await self.pair_success(node, child)

    async def rotate_qr(self, refs: list[str]) -> None:
        """Each ref is shown for 60 s, then 20 s, as whatsmeow's QR channel does."""
        session = self.client.session
        for index, ref in enumerate(refs):
            data = ",".join([ref, b64(session.noise_key.public), b64(session.identity_key.public), session.data["advSecret"], PAIR_CLIENT_SAFARI])
            await self.client.events.put(("qr", f"https://wa.me/settings/linked_devices#{data}"))
            await asyncio.sleep(60 if index == 0 else 20)
        await self.client.events.put(("qr-timeout", None))

    async def request_code(self) -> None:
        phone = re.sub(r"[^0-9]", "", self.phone)
        ephemeral = KeyPair.generate()
        salt, iv = secrets.token_bytes(32), secrets.token_bytes(16)
        raw = int.from_bytes(secrets.token_bytes(5), "big")
        code = "".join(LINKING_ALPHABET[(raw >> (35 - 5 * index)) & 31] for index in range(8))
        key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=2 << 16).derive(code.encode())
        wrapped = salt + iv + aes_ctr(key, iv, ephemeral.public)
        session = self.client.session
        response = await self.client.iq(
            "md",
            "set",
            [
                Node(
                    "link_code_companion_reg",
                    {"jid": JID(phone, USER_SERVER), "stage": "companion_hello", "should_show_push_notification": "true"},
                    [
                        Node("link_code_pairing_wrapped_companion_ephemeral_pub", {}, wrapped),
                        Node("companion_server_auth_key_pub", {}, session.noise_key.public),
                        Node("companion_platform_id", {}, PAIR_CLIENT_SAFARI),
                        Node("companion_platform_display", {}, PAIR_CLIENT_DISPLAY),
                        Node("link_code_pairing_nonce", {}, bytes([0])),
                    ],
                )
            ],
        )
        ref = response.child("link_code_companion_reg", "link_code_pairing_ref")
        self.pairing = {"jid": JID(phone, USER_SERVER), "key": ephemeral, "code": code, "ref": ref.bytes()}
        await self.client.events.put(("code", f"{code[:4]}-{code[4:]}"))

    async def handle_notification(self, node: Node) -> None:
        await self.client.ack(node)
        if node.attr("type") != "link_code_companion_reg" or not self.pairing:
            return
        registration = node.child("link_code_companion_reg")
        if registration.child("link_code_pairing_ref").bytes() != self.pairing["ref"]:
            raise ValueError("pairing ref mismatch")
        wrapped = registration.child("link_code_pairing_wrapped_primary_ephemeral_pub").bytes()
        primary_identity = registration.child("primary_identity_pub").bytes()
        key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=wrapped[:32], iterations=2 << 16).derive(self.pairing["code"].encode())
        primary_ephemeral = aes_ctr(key, wrapped[32:48], wrapped[48:80])
        ephemeral_secret = self.pairing["key"].agree(primary_ephemeral)

        session = self.client.session
        identity = session.identity_key
        adv_random, bundle_salt, bundle_nonce = secrets.token_bytes(32), secrets.token_bytes(32), secrets.token_bytes(12)
        bundle_key = hkdf(ephemeral_secret, 32, salt=bundle_salt, info=b"link_code_pairing_key_bundle_encryption_key")
        bundle = AESGCM(bundle_key).encrypt(bundle_nonce, identity.public + primary_identity + adv_random, None)
        identity_secret = identity.agree(primary_identity)
        session.data["advSecret"] = b64(hkdf(ephemeral_secret + identity_secret + adv_random, 32, info=b"adv_secret"))
        session.save()
        await self.client.iq(
            "md",
            "set",
            [
                Node(
                    "link_code_companion_reg",
                    {"jid": self.pairing["jid"], "stage": "companion_finish"},
                    [
                        Node("link_code_pairing_wrapped_key_bundle", {}, bundle_salt + bundle_nonce + bundle),
                        Node("companion_identity_public", {}, identity.public),
                        Node("link_code_pairing_ref", {}, self.pairing["ref"]),
                    ],
                )
            ],
        )

    async def pair_success(self, node: Node, success: Node) -> None:
        session = self.client.session
        request_id = node.attr("id")
        container = waAdv.ADVSignedDeviceIdentityHMAC.FromString(success.child("device-identity").bytes())
        mac = hmac.new(unb64(session.data["advSecret"]), digestmod=hashlib.sha256)
        if container.accountType == waAdv.HOSTED:
            mac.update(bytes([6, 5]))
        mac.update(container.details)
        if not hmac.compare_digest(mac.digest(), container.HMAC):
            await self.pair_error(request_id, 401, "hmac-mismatch")
            raise ValueError("pair-success HMAC mismatch")
        identity = waAdv.ADVSignedDeviceIdentity.FromString(container.details)
        details = waAdv.ADVDeviceIdentity.FromString(identity.details)
        key = session.identity_key
        if not xeddsa_verify(identity.accountSignatureKey, ADV_ACCOUNT_SIGNATURE_PREFIX + identity.details + key.public, identity.accountSignature):
            await self.pair_error(request_id, 401, "signature-mismatch")
            raise ValueError("account signature mismatch")
        identity.deviceSignature = key.sign(ADV_DEVICE_SIGNATURE_PREFIX + identity.details + key.public + identity.accountSignatureKey)

        device = success.child("device")
        jid, lid = device.attrs.get("jid"), device.attrs.get("lid")
        session.data["account"] = b64(identity.SerializeToString())
        session.data["jid"] = str(jid)
        session.data["lid"] = str(lid) if lid else None
        session.data["platform"] = success.child("platform").attr("name") if success.child("platform") else ""
        primary_lid = JID(lid.user, LID_SERVER) if lid else None
        session.data.setdefault("identities", {})
        if primary_lid:
            session.data["identities"][primary_lid.signal_address()] = b64(identity.accountSignatureKey)
        session.save()

        identity.ClearField("accountSignatureKey")
        await self.client.send(
            Node(
                "iq",
                {"to": SERVER_JID, "type": "result", "id": request_id},
                [Node("pair-device-sign", {}, [Node("device-identity", {"key-index": details.keyIndex}, identity.SerializeToString())])],
            )
        )
        await self.client.events.put(("paired", str(jid)))

    async def pair_error(self, request_id: str, code: int, text: str) -> None:
        await self.client.send(Node("iq", {"to": SERVER_JID, "type": "error", "id": request_id}, [Node("error", {"code": code, "text": text})]))


# ---------------------------------------------------------------------------------------------------------
# App state (whatsmeow appstate/: syncd patches, LTHash integrity, mutation MACs)

APP_STATE_COLLECTIONS = ["critical_block", "critical_unblock_low", "regular_high", "regular", "regular_low"]
APP_STATE_PATH = os.path.join(ROOT, "logs", "whatsapp-appstate.json")


def lthash_apply(state: bytearray, macs: list[bytes], subtract: bool) -> None:
    for mac in macs:
        expanded = hkdf(mac, 128, info=b"WhatsApp Patch Integrity")
        for index in range(0, 128, 2):
            x = int.from_bytes(state[index : index + 2], "little")
            y = int.from_bytes(expanded[index : index + 2], "little")
            state[index : index + 2] = ((x - y if subtract else x + y) & 0xFFFF).to_bytes(2, "little")


def app_state_keys(key_data: bytes) -> dict:
    expanded = hkdf(key_data, 160, info=b"WhatsApp Mutation Keys")
    return {"index": expanded[:32], "value": expanded[32:64], "valueMac": expanded[64:96], "snapshotMac": expanded[96:128], "patchMac": expanded[128:160]}


class AppStateSync:
    def __init__(self, account: Account) -> None:
        self.account = account
        self.session = account.session
        self.server_sync = importlib.import_module("waServerSync.WAWebProtobufsServerSync_pb2")
        self.sync_action = importlib.import_module("waSyncAction.WAWebProtobufSyncAction_pb2")
        self.session.data.setdefault("appState", {})

    def keys(self, key_id: bytes) -> dict:
        stored = self.session.data["appStateKeys"].get(key_id.hex())
        if not stored:
            raise SignalError(f"missing app state key {key_id.hex()}")
        return app_state_keys(unb64(stored["data"]))

    def snapshot_mac(self, hash_state: bytes, version: int, name: str, key: bytes) -> bytes:
        return hmac.new(key, hash_state + struct.pack(">Q", version) + name.encode(), hashlib.sha256).digest()

    async def fetch(self, name: str, full: bool) -> list[dict]:
        stored = self.session.data["appState"].get(name)
        if full or not stored:
            state = {"version": 0, "hash": bytearray(128), "macs": {}}
        else:
            state = {"version": stored["version"], "hash": bytearray(unb64(stored["hash"])), "macs": dict(stored["macs"])}
        mutations: list[dict] = []
        want_snapshot = state["version"] == 0
        while True:
            attrs = {"name": name, "return_snapshot": "true" if want_snapshot else "false"}
            if not want_snapshot:
                attrs["version"] = state["version"]
            response = await self.account.client.iq("w:sync:app:state", "set", [Node("sync", {}, [Node("collection", attrs)])])
            collection = response.child("sync", "collection")
            if collection.child("error"):
                raise SignalError(f"{name}: {collection.child('error').describe()}")
            snapshot_node = collection.child("snapshot")
            if snapshot_node and snapshot_node.bytes():
                reference = self.server_sync.ExternalBlobReference.FromString(snapshot_node.bytes())
                raw = await self.download(reference)
                snapshot = self.server_sync.SyncdSnapshot.FromString(raw)
                mutations += self.apply_snapshot(name, state, snapshot)
            patches_node = collection.child("patches")
            for patch_node in patches_node.children() if patches_node else []:
                patch = self.server_sync.SyncdPatch.FromString(patch_node.bytes())
                if patch.HasField("externalMutations"):
                    external = self.server_sync.SyncdMutations.FromString(await self.download(patch.externalMutations))
                    del patch.mutations[:]
                    patch.mutations.extend(external.mutations)
                mutations += self.apply_patch(name, state, patch)
            want_snapshot = False
            if collection.attr("has_more_patches") != "true":
                break
        self.session.data["appState"][name] = {"version": state["version"], "hash": b64(bytes(state["hash"])), "macs": state["macs"]}
        self.session.save()
        return mutations

    async def download(self, reference: Any) -> bytes:
        return await self.account.download_media(
            reference.directPath, reference.fileEncSHA256, reference.fileSHA256, reference.mediaKey, b"WhatsApp App State Keys", "md-app-state"
        )

    def decode_mutation(self, operation: int, record: Any) -> dict:
        keys = self.keys(record.keyID.ID)
        blob = record.value.blob
        content, value_mac = blob[:-32], blob[-32:]
        key_id = record.keyID.ID
        expected = hmac.new(keys["valueMac"], bytes([operation + 1]) + key_id + content + struct.pack(">Q", len(key_id) + 1), hashlib.sha512).digest()[:32]
        if not hmac.compare_digest(expected, value_mac):
            raise SignalError("app state value MAC mismatch")
        action = self.sync_action.SyncActionData.FromString(aes_cbc_decrypt(keys["value"], content[:16], content[16:]))
        index_mac = record.index.blob
        if not hmac.compare_digest(hmac.new(keys["index"], action.index, hashlib.sha256).digest(), index_mac):
            raise SignalError("app state index MAC mismatch")
        return {"operation": operation, "index": json.loads(action.index), "action": action.value, "indexMac": index_mac, "valueMac": value_mac}

    def apply_snapshot(self, name: str, state: dict, snapshot: Any) -> list[dict]:
        state["version"] = snapshot.version.version
        state["hash"] = bytearray(128)
        state["macs"] = {}
        value_macs = [record.value.blob[-32:] for record in snapshot.records]
        lthash_apply(state["hash"], value_macs, subtract=False)
        keys = self.keys(snapshot.keyID.ID)
        if not hmac.compare_digest(self.snapshot_mac(bytes(state["hash"]), state["version"], name, keys["snapshotMac"]), snapshot.mac):
            raise SignalError(f"{name}: snapshot LTHash mismatch")
        mutations = []
        for record in snapshot.records:
            mutation = self.decode_mutation(0, record)
            state["macs"][b64(mutation["indexMac"])] = b64(mutation["valueMac"])
            mutations.append(mutation)
        return mutations

    def apply_patch(self, name: str, state: dict, patch: Any) -> list[dict]:
        added, removed = [], []
        for index, mutation in enumerate(patch.mutations):
            blob = mutation.record.value.blob
            if mutation.operation == 0:
                added.append(blob[-32:])
            index_mac = mutation.record.index.blob
            previous = None
            for earlier in reversed(patch.mutations[:index]):
                if earlier.record.index.blob == index_mac:
                    previous = earlier.record.value.blob[-32:] if earlier.operation == 0 else None
                    break
            else:
                stored = state["macs"].get(b64(index_mac))
                previous = unb64(stored) if stored else None
            if previous:
                removed.append(previous)
        lthash_apply(state["hash"], removed, subtract=True)
        lthash_apply(state["hash"], added, subtract=False)
        version = patch.version.version
        keys = self.keys(patch.keyID.ID)
        if not hmac.compare_digest(self.snapshot_mac(bytes(state["hash"]), version, name, keys["snapshotMac"]), patch.snapshotMAC):
            raise SignalError(f"{name}: patch v{version} LTHash mismatch")
        patch_data = patch.snapshotMAC + b"".join(m.record.value.blob[-32:] for m in patch.mutations) + struct.pack(">Q", version) + name.encode()
        if not hmac.compare_digest(hmac.new(keys["patchMac"], patch_data, hashlib.sha256).digest(), patch.patchMAC):
            raise SignalError(f"{name}: patch v{version} MAC mismatch")
        state["version"] = version
        mutations = []
        for mutation in patch.mutations:
            decoded = self.decode_mutation(mutation.operation, mutation.record)
            key = b64(decoded["indexMac"])
            if mutation.operation == 0:
                state["macs"][key] = b64(decoded["valueMac"])
            else:
                state["macs"].pop(key, None)
            mutations.append(decoded)
        return mutations


def summarize_app_state(mutations: list[dict], summary: dict) -> None:
    """Folds mutations into chat metadata: contact names, mute, archive, pin, read state, locked chats."""
    for mutation in mutations:
        index, action = mutation["index"], mutation["action"]
        if not index:
            continue
        kind, target = index[0], index[1] if len(index) > 1 else ""
        removed = mutation["operation"] == 1
        if kind == "contact":
            if removed:
                summary["contacts"].pop(target, None)
            else:
                summary["contacts"][target] = {"fullName": action.contactAction.fullName, "firstName": action.contactAction.firstName,
                                               "lid": action.contactAction.lidJID, "pn": action.contactAction.pnJID}
        elif kind == "mute":
            summary["muted"][target] = action.muteAction.muteEndTimestamp if action.muteAction.muted and not removed else None
        elif kind == "archive":
            summary["archived"][target] = action.archiveChatAction.archived and not removed
        elif kind == "pin_v1":
            summary["pinned"][target] = action.pinAction.pinned and not removed
        elif kind == "markChatAsRead":
            summary["read"][target] = action.markChatAsReadAction.read
        elif kind == "lock":
            summary.setdefault("locked", {})[target] = action.lockChatAction.locked and not removed
        summary["kinds"][kind] = summary["kinds"].get(kind, 0) + 1


async def fetch_groups(account: Account) -> dict:
    """Joined groups with subjects and participants (whatsmeow GetJoinedGroups), saved in the session file."""
    response = await account.client.iq(
        "w:g2", "get", [Node("participating", {}, [Node("participants", {}), Node("description", {})])], to=JID("", GROUP_SERVER)
    )
    groups = {}
    for node in response.child("groups").children() if response.child("groups") else []:
        if node.tag != "group":
            continue
        participants = []
        for participant in node.children():
            if participant.tag != "participant":
                continue
            jid = participant.attrs.get("jid")
            pn = participant.attrs.get("phone_number") if jid and jid.server == LID_SERVER else jid
            lid = jid if jid and jid.server == LID_SERVER else participant.attrs.get("lid")
            account.store_lid(pn, lid)
            participants.append({"lid": str(lid) if lid else None, "pn": str(pn) if pn else None, "role": participant.attr("type")})
        groups[f"{node.attr('id')}@{GROUP_SERVER}"] = {"subject": node.attr("subject"), "addressingMode": node.attr("addressing_mode"), "participants": participants}
    account.session.data["groups"] = groups
    account.session.save()
    return groups


async def command_appstate(args: argparse.Namespace) -> None:
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    account = Account(session, verbose=args.verbose)
    await account.start()
    sync = AppStateSync(account)
    summary = {"contacts": {}, "muted": {}, "archived": {}, "pinned": {}, "read": {}, "locked": {}, "kinds": {}}
    if os.path.exists(APP_STATE_PATH) and not args.full:
        with open(APP_STATE_PATH) as file:
            summary = json.load(file)
    try:
        for name in APP_STATE_COLLECTIONS:
            try:
                mutations = await sync.fetch(name, full=args.full)
            except (SignalError, IQError) as error:
                print(f"{name}: failed: {error}", flush=True)
                continue
            summarize_app_state(mutations, summary)
            print(f"{name}: v{session.data['appState'][name]['version']}, {len(mutations)} mutations", flush=True)
        groups = await fetch_groups(account)
        print(f"{len(groups)} groups", flush=True)
    finally:
        await account.close()
    with open(os.open(APP_STATE_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
        json.dump(summary, file, indent=1)
    muted = sum(1 for value in summary["muted"].values() if value is not None)
    archived = sum(1 for value in summary["archived"].values() if value)
    pinned = sum(1 for value in summary["pinned"].values() if value)
    locked = [target for target, value in summary.get("locked", {}).items() if value]
    servers = sorted({target.split("@")[-1] for target in locked})
    print(f"{len(summary['contacts'])} contacts, {muted} muted, {archived} archived, {pinned} pinned, {len(locked)} locked ({', '.join(servers)}); kinds {summary['kinds']}", flush=True)


def load_chats(session: Session) -> list[dict]:
    """The Chats list from saved history syncs and app state, newest first (no message text)."""
    conversations: dict[str, Any] = {}
    for name in sorted(os.listdir(HISTORY_DIR)) if os.path.isdir(HISTORY_DIR) else []:
        with open(os.path.join(HISTORY_DIR, name), "rb") as file:
            history = waHistorySync.HistorySync.FromString(file.read())
        for conversation in history.conversations:
            previous = conversations.get(conversation.ID)
            if not previous or conversation.conversationTimestamp >= previous.conversationTimestamp or len(conversation.messages) > len(previous.messages):
                conversations[conversation.ID] = conversation
    app_state = {"contacts": {}, "muted": {}, "archived": {}, "pinned": {}}
    if os.path.exists(APP_STATE_PATH):
        with open(APP_STATE_PATH) as file:
            app_state = json.load(file)
    lid_to_pn = {lid: pn for pn, lid in session.data.get("lidMap", {}).items()}
    push_names = session.data.get("pushNames", {})
    now = time.time()
    chats = []
    for chat_id, conversation in conversations.items():
        jid = JID.parse(chat_id)
        if jid.server in ("broadcast", "newsletter"):
            continue
        pn_user = jid.user if jid.server == USER_SERVER else lid_to_pn.get(jid.user)
        candidates = [chat_id, f"{pn_user}@{USER_SERVER}" if pn_user else None, conversation.pnJID, conversation.lidJID]
        contact = next((app_state["contacts"][key] for key in candidates if key and key in app_state["contacts"]), None)
        name = (
            (session.data.get("groups", {}).get(chat_id, {}).get("subject") or conversation.name) if jid.server == GROUP_SERVER else None
        ) or (contact or {}).get("fullName") or conversation.displayName or push_names.get(jid.user) or (push_names.get(pn_user) if pn_user else None) or (f"+{pn_user}" if pn_user else chat_id)
        mute_end = app_state["muted"].get(chat_id, conversation.muteEndTime or None)
        muted = bool(mute_end) and (mute_end == -1 or mute_end > now * (1000 if mute_end > 1e12 else 1))
        archived = app_state["archived"].get(chat_id, conversation.archived)
        last = max((message.message.messageTimestamp for message in conversation.messages), default=0) or conversation.conversationTimestamp
        chats.append({"id": chat_id, "name": name, "group": jid.server == GROUP_SERVER, "unread": conversation.unreadCount,
                      "markedUnread": conversation.markedAsUnread, "muted": muted, "archived": bool(archived),
                      "pinned": bool(app_state["pinned"].get(chat_id, conversation.pinned)), "last": last, "messages": len(conversation.messages)})
    chats.sort(key=lambda chat: chat["last"], reverse=True)
    return chats


def command_history_flags(args: argparse.Namespace) -> None:
    """Archive, pin and mute for one chat in each saved history sync, in arrival order, next to app state's."""
    for name in sorted(os.listdir(HISTORY_DIR)) if os.path.isdir(HISTORY_DIR) else []:
        with open(os.path.join(HISTORY_DIR, name), "rb") as file:
            history = waHistorySync.HistorySync.FromString(file.read())
        if not history.conversations:
            continue
        archived = sum(1 for conversation in history.conversations if conversation.archived)
        pinned = sum(1 for conversation in history.conversations if conversation.pinned)
        muted = sum(1 for conversation in history.conversations if conversation.muteEndTime)
        match = next((conversation for conversation in history.conversations if conversation.ID == args.chat), None)
        flags = f"archived={match.archived} pinned={match.pinned} muteEndTime={match.muteEndTime}" if match else "absent"
        print(f"{name}: {len(history.conversations)} chats, {archived} archived, {pinned} pinned, {muted} muted; {args.chat}: {flags}")
    if os.path.exists(APP_STATE_PATH):
        with open(APP_STATE_PATH) as file:
            summary = json.load(file)
        print(f"app state: archived={summary['archived'].get(args.chat)} muted={summary['muted'].get(args.chat)} pinned={summary['pinned'].get(args.chat)}")


def command_chats(args: argparse.Namespace) -> None:
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    chats = [chat for chat in load_chats(session) if chat["archived"] == args.archived]
    for chat in chats[: args.limit]:
        flags = "".join(flag for flag, on in (("G", chat["group"]), ("M", chat["muted"]), ("P", chat["pinned"]), ("U", chat["markedUnread"])) if on)
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(chat["last"])) if chat["last"] else "-"
        print(f"{when}  {chat['unread']:>3}  {flags:<4} {chat['name']}  ({chat['messages']} msgs, {chat['id']})")
    print(f"{len(chats)} {'archived ' if args.archived else ''}chats")


# ---------------------------------------------------------------------------------------------------------
# Sending (whatsmeow send.go, user.go GetUserDevices, prekeys.go fetchPreKeys)


def message_id(own: JID) -> str:
    data = struct.pack(">Q", int(time.time())) + f"{own.user}@c.us".encode() + secrets.token_bytes(16)
    return "3EB0" + hashlib.sha256(data).hexdigest()[:18].upper()


async def get_devices(account: Account, users: list[JID]) -> list[JID]:
    user_nodes = [Node("user", {"jid": user.non_ad()}) for user in users]
    response = await account.client.iq(
        "usync",
        "get",
        [
            Node(
                "usync",
                {"sid": account.client.request_id(), "mode": "query", "last": "true", "index": "0", "context": "message"},
                [Node("query", {}, [Node("devices", {"version": "2"})]), Node("list", {}, user_nodes)],
            )
        ],
    )
    devices = []
    for user in response.child("usync", "list").children():
        jid = user.attrs.get("jid")
        device_list = user.child("devices", "device-list")
        for device in device_list.children() if device_list else []:
            if device.tag != "device" or device.attr("is_hosted") == "true":
                continue
            devices.append(JID(jid.user, jid.server, int(device.attr("id"))))
    return devices


async def fetch_bundles(account: Account, devices: list[JID]) -> dict[JID, dict]:
    response = await account.client.iq(
        "encrypt", "get", [Node("key", {}, [Node("user", {"jid": device, "reason": "identity"}) for device in devices])]
    )
    bundles = {}
    for user in response.child("list").children():
        if user.tag != "user" or user.child("error"):
            continue
        keys = user.child("keys") or user

        def key_node(node: Node) -> tuple[int, bytes]:
            return int.from_bytes(node.child("id").bytes(), "big"), node.child("value").bytes()

        signed_id, signed_public = key_node(keys.child("skey"))
        bundle = {
            "registrationId": int.from_bytes(user.child("registration").bytes(), "big"),
            "identity": keys.child("identity").bytes(),
            "signedPreKeyId": signed_id,
            "signedPreKey": signed_public,
            "signature": keys.child("skey").child("signature").bytes(),
        }
        if keys.child("key"):
            bundle["preKeyId"], bundle["preKey"] = key_node(keys.child("key"))
        bundles[user.attrs["jid"]] = bundle
    return bundles


TC_TOKEN_BUCKET = 604800
TC_TOKEN_BUCKETS = 4


def tc_token_cutoff() -> int:
    """Tokens from before this bucket boundary have expired (whatsmeow currentTCTokenCutoffTimestamp)."""
    return (int(time.time()) // TC_TOKEN_BUCKET - (TC_TOKEN_BUCKETS - 1)) * TC_TOKEN_BUCKET


def privacy_tokens(session: Session) -> dict:
    """Privacy tokens by LID user: from history sync conversations (whatsmeow message.go) and privacy_token
    notifications, which `Account` stores in the session."""
    tokens = session.data.setdefault("privacyTokens", {})
    for name in sorted(os.listdir(HISTORY_DIR)) if os.path.isdir(HISTORY_DIR) else []:
        with open(os.path.join(HISTORY_DIR, name), "rb") as file:
            history = waHistorySync.HistorySync.FromString(file.read())
        if history.nctSalt:
            session.data["nctSalt"] = b64(history.nctSalt)
        for conversation in history.conversations:
            if not conversation.tcToken:
                continue
            jid = JID.parse(conversation.ID)
            user = session.data["lidMap"].get(jid.user, jid.user) if jid.server == USER_SERVER else jid.user
            previous = tokens.get(user)
            if previous and previous["t"] >= conversation.tcTokenTimestamp:
                continue
            tokens[user] = {"token": b64(conversation.tcToken), "t": conversation.tcTokenTimestamp, "senderT": conversation.tcTokenSenderTimestamp or (previous or {}).get("senderT", 0)}
    return tokens


def token_node(session: Session, lid: JID) -> Node | None:
    """`<tctoken>` with the recipient's unexpired privacy token, else `<cstoken>` (HMAC-SHA256 of their LID under the
    account's NCT salt), else nothing (whatsmeow sendDM, cstoken.go)."""
    token = privacy_tokens(session).get(lid.user)
    if token and token["t"] >= tc_token_cutoff():
        return Node("tctoken", {}, unb64(token["token"]))
    if session.data.get("nctSalt"):
        return Node("cstoken", {}, hmac.new(unb64(session.data["nctSalt"]), f"{lid.user}@{LID_SERVER}".encode(), hashlib.sha256).digest())
    return None


async def issue_privacy_token(account: Account, lid: JID) -> None:
    """After a send, our own token goes to the recipient once per week bucket (whatsmeow issuePrivacyTokenAndSave)."""
    tokens = privacy_tokens(account.session)
    sender_t = tokens.get(lid.user, {}).get("senderT", 0)
    now = int(time.time())
    if sender_t and now // TC_TOKEN_BUCKET <= sender_t // TC_TOKEN_BUCKET:
        return
    await account.client.iq("privacy", "set", [Node("tokens", {}, [Node("token", {"jid": JID(lid.user, LID_SERVER), "t": str(now), "type": "trusted_contact"})])])
    tokens.setdefault(lid.user, {"token": "", "t": 0})["senderT"] = now
    account.session.save()
    print(f"issued our privacy token to {lid.user}@lid", flush=True)


async def send_dm(account: Account, to: JID, message: Any) -> str:
    """One-to-one send in LID addressing: the recipient's devices get the message, our other devices a DeviceSentMessage."""
    session = account.session
    own_lid = session.lid
    peer_pn = None
    if to.server == USER_SERVER:
        lid = account.lid_for(to)
        if not lid:
            raise SystemExit(f"no LID known for {to}")
        peer_pn, to = to, JID(lid.user, LID_SERVER)
    plaintext = message.SerializeToString()
    sent = waE2E.Message()
    sent.deviceSentMessage.destinationJID = str(to)
    sent.deviceSentMessage.message.CopyFrom(message)
    if message.HasField("messageContextInfo"):
        sent.messageContextInfo.CopyFrom(message.messageContextInfo)
    device_sent = sent.SerializeToString()
    users = [to] if to.user == own_lid.user else [to, JID(own_lid.user, LID_SERVER)]
    devices = [device for device in await get_devices(account, users) if not (device.user == own_lid.user and device.device == own_lid.device)]
    missing = [device for device in devices if not account.store.has_session(device.signal_address())]
    if missing:
        for device, bundle in (await fetch_bundles(account, missing)).items():
            account.store.build_session(device.signal_address(), bundle)
    participants, include_identity = [], False
    for device in devices:
        if not account.store.has_session(device.signal_address()):
            log(f"no session for {device}, skipping")
            continue
        payload = device_sent if device.user == own_lid.user else plaintext
        kind, ciphertext = account.store.encrypt(device.signal_address(), pad_message(payload))
        include_identity |= kind == "pkmsg"
        participants.append(Node("to", {"jid": device}, [Node("enc", {"v": "2", "type": kind}, ciphertext)]))
    identifier = message_id(session.jid)
    content = [Node("participants", {}, participants)]
    if include_identity:
        content.append(Node("device-identity", {}, unb64(session.data["account"])))
    token = token_node(session, to)
    if token:
        content.append(token)
    attrs = {"id": identifier, "type": "text", "to": to}
    if peer_pn:
        attrs["peer_recipient_pn"] = peer_pn
    ack = await account.client.send_and_wait(Node("message", attrs, content), identifier)
    if ack.attrs.get("error"):
        raise SystemExit(f"send failed: {ack.describe()}")
    print(f"sent {identifier} to {to} ({len(participants)} devices, {token.tag if token else 'no token'}), server t={ack.attr('t')}", flush=True)
    await issue_privacy_token(account, to)
    return identifier


async def send_peer(account: Account, message: Any) -> str:
    """A protocol message to the user's own phone (whatsmeow SendPeerMessage, preparePeerMessageNode): encrypted
    for the phone's device only, `category="peer"`; an on-demand history request goes with `push_priority`
    high_force and `privacy_sensitive`."""
    session = account.session
    phone = JID(session.lid.user, LID_SERVER)
    if not account.store.has_session(phone.signal_address()):
        for device, bundle in (await fetch_bundles(account, [phone])).items():
            account.store.build_session(device.signal_address(), bundle)
    kind, ciphertext = account.store.encrypt(phone.signal_address(), pad_message(message.SerializeToString()))
    identifier = message_id(session.jid)
    attrs = {"id": identifier, "type": "text", "category": "peer", "to": session.jid.non_ad()}
    operation = message.protocolMessage.peerDataOperationRequestMessage
    if operation.peerDataOperationRequestType == waE2E.PeerDataOperationRequestType.HISTORY_SYNC_ON_DEMAND:
        attrs["push_priority"] = "high_force"
        attrs["privacy_sensitive"] = "1"
    content = [Node("meta", {"appdata": "default"}), Node("enc", {"v": "2", "type": kind}, ciphertext)]
    if kind == "pkmsg":
        content.append(Node("device-identity", {}, unb64(session.data["account"])))
    ack = await account.client.send_and_wait(Node("message", attrs, content), identifier)
    if ack.attrs.get("error"):
        raise SystemExit(f"peer send failed: {ack.describe()}")
    return identifier


def oldest_known(chat: str) -> Any | None:
    """The oldest message saved for the chat in history syncs, as the anchor for an on-demand request."""
    oldest = None
    for name in os.listdir(HISTORY_DIR) if os.path.isdir(HISTORY_DIR) else []:
        with open(os.path.join(HISTORY_DIR, name), "rb") as file:
            history = waHistorySync.HistorySync.FromString(file.read())
        for conversation in history.conversations:
            if conversation.ID != chat:
                continue
            for item in conversation.messages:
                if oldest is None or item.message.messageTimestamp < oldest.messageTimestamp:
                    oldest = item.message
    return oldest


async def command_history(args: argparse.Namespace) -> None:
    """Asks the phone for older messages in one chat (whatsmeow BuildHistorySyncRequest): up to --count before the
    oldest saved one. The answer arrives as an ON_DEMAND history sync, saved like the others."""
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    anchor = oldest_known(args.chat)
    if anchor is None:
        raise SystemExit(f"no saved messages for {args.chat}")
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        message = waE2E.Message()
        protocol = message.protocolMessage
        protocol.type = waE2E.ProtocolMessage.PEER_DATA_OPERATION_REQUEST_MESSAGE
        operation = protocol.peerDataOperationRequestMessage
        operation.peerDataOperationRequestType = waE2E.PeerDataOperationRequestType.HISTORY_SYNC_ON_DEMAND
        request = operation.historySyncOnDemandRequest
        request.chatJID = args.chat
        request.oldestMsgID = anchor.key.ID
        request.oldestMsgFromMe = anchor.key.fromMe
        request.onDemandMsgCount = args.count
        # Seconds, despite the name (whatsmeow).
        request.oldestMsgTimestampMS = anchor.messageTimestamp
        age = (time.time() - anchor.messageTimestamp) / 86400
        identifier = await send_peer(account, message)
        print(f"requested {args.count} messages before {anchor.key.ID} ({age:.0f}d old) as {identifier}; waiting {args.listen:.0f}s", flush=True)
        await asyncio.sleep(args.listen)
    finally:
        await account.close()


async def command_avatar(args: argparse.Namespace) -> None:
    """Profile picture URLs (whatsmeow GetProfilePictureInfo); prints status, id, expiry and size, not the image."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        for text in args.jids:
            jid = JID(session.lid.user, LID_SERVER) if text == "self" else JID.parse(text)
            attrs = {"query": "url", "type": "image" if args.full else "preview"}
            if args.existing_id:
                attrs["id"] = args.existing_id
            try:
                response = await account.client.iq("w:profile:picture", "get", [Node("picture", attrs)], target=jid)
            except IQError as error:
                print(f"{jid}: error {error.code} {error.text}", flush=True)
                continue
            picture = response.child("picture")
            if not picture:
                print(f"{jid}: no picture node", flush=True)
                continue
            if picture.attr("status"):
                print(f"{jid}: status {picture.attr('status')}", flush=True)
                continue
            url = picture.attr("url")
            expiry = re.search(r"[?&]oe=([0-9A-Fa-f]+)", url)
            expires = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(expiry.group(1), 16))) if expiry else "?"
            request = urllib.request.Request(url)
            with urllib.request.urlopen(request, timeout=20) as reply:
                size = len(reply.read())
                kind = reply.headers.get("Content-Type")
            print(f"{jid}: id {picture.attr('id')} type {picture.attr('type')} host {urllib.parse.urlparse(url).netloc} expires {expires} -> {size} bytes {kind}", flush=True)
    finally:
        await account.close()


async def command_push_settings(args: argparse.Namespace) -> None:
    """The server's push configuration (whatsmeow GetServerPushNotificationConfig)."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        response = await account.client.iq("urn:xmpp:whatsapp:push", "get", [Node("settings", {})])
        print(response.describe(), flush=True)
    finally:
        await account.close()


def webpush_decrypt(body: bytes, private_key: Any, auth: bytes) -> bytes:
    """RFC 8291 aes128gcm with the subscription's P-256 key and auth secret."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization

    salt, record_size, key_length = body[:16], int.from_bytes(body[16:20], "big"), body[20]
    sender_key = body[21 : 21 + key_length]
    ciphertext = body[21 + key_length :]
    receiver_public = private_key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    shared = private_key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), sender_key))
    ikm = hkdf(shared, 32, salt=auth, info=b"WebPush: info\x00" + receiver_public + sender_key)
    content_key = hkdf(ikm, 16, salt=salt, info=b"Content-Encoding: aes128gcm\x00")
    nonce = hkdf(ikm, 12, salt=salt, info=b"Content-Encoding: nonce\x00")
    plaintext = AESGCM(content_key).decrypt(nonce, ciphertext[:record_size], None)
    return plaintext.rstrip(b"\x00")[:-1] if plaintext.rstrip(b"\x00").endswith(b"\x02") else plaintext


def describe_json(value: Any) -> Any:
    """JSON structure with strings replaced by their length, so others' text never prints."""
    if isinstance(value, dict):
        return {key: describe_json(item) for key, item in value.items()}
    if isinstance(value, list):
        return [describe_json(item) for item in value]
    if isinstance(value, str):
        return f"<str {len(value)}>"
    return value


async def command_push_capture(args: argparse.Namespace) -> None:
    """Registers a Web Push subscription whose endpoint is a temporary local capture server (a Cloudflare quick
    tunnel), goes offline and prints each push: headers (the VAPID key in Authorization) and the decrypted payload's
    structure. Raw decrypted payloads go to logs/whatsapp-push/ (0600). Unregisters by registering nothing? No:
    WhatsApp keeps the last config; run `push-capture` again or relink to replace it."""
    import http.server
    import threading
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization

    private_key = ec.generate_private_key(ec.SECP256R1())
    public = private_key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    auth = secrets.token_bytes(16)
    out_dir = os.path.join(ROOT, "logs", "whatsapp-push")
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    received: list[float] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.send_response(201)
            self.end_headers()
            headers = {key: value for key, value in self.headers.items() if key.lower() in ("authorization", "content-encoding", "ttl", "urgency", "topic", "content-type")}
            vapid = re.search(r"k=([A-Za-z0-9_-]+)", headers.get("Authorization", ""))
            print(f"push {time.strftime('%H:%M:%S')} {len(body)} bytes path {self.path} headers {{{', '.join(f'{k}: {v[:40]}' for k, v in headers.items())}}}", flush=True)
            if vapid:
                print(f"  vapid key {vapid.group(1)}", flush=True)
            try:
                plaintext = webpush_decrypt(body, private_key, auth)
            except Exception as error:  # noqa: BLE001
                print(f"  couldn't decrypt: {error}", flush=True)
                return
            path = os.path.join(out_dir, f"{int(time.time() * 1000)}.bin")
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as file:
                file.write(plaintext)
            try:
                print(f"  payload json {json.dumps(describe_json(json.loads(plaintext)))}", flush=True)
            except ValueError:
                print(f"  payload {len(plaintext)} bytes, not JSON (saved {os.path.relpath(path, ROOT)})", flush=True)
            received.append(time.time())

        def log_message(self, *_: Any) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tunnel = subprocess.Popen(["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{args.port}", "--no-autoupdate"], stderr=subprocess.PIPE, text=True)
    endpoint = None
    deadline = time.time() + 40
    while time.time() < deadline and not endpoint:
        line = tunnel.stderr.readline()
        match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", line)
        if match:
            endpoint = match.group(0) + "/push"
    if not endpoint:
        tunnel.terminate()
        raise SystemExit("cloudflared didn't print a tunnel URL")
    print(f"capture endpoint {endpoint}", flush=True)
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        # As WhatsApp Web's WASmaxPushConfigSetRPC sends it, with the locale (whatsmeow's WebPushConfig leaves it out).
        config = {"platform": "web", "endpoint": endpoint, "auth": b64(auth), "p256dh": b64(public), "lg": "en", "lc": "US"}
        response = await account.client.iq("urn:xmpp:whatsapp:push", "set", [Node("config", config)])
        print(f"registered: {response.describe()}", flush=True)
        if args.unavailable:
            # Mark the device offline the way a client going to the background does, so pushes aren't held back.
            await account.client.send(Node("presence", {"type": "unavailable"}))
            await asyncio.sleep(2)
            print("sent presence unavailable", flush=True)
    finally:
        await account.close()
    print(f"offline; waiting {args.listen:.0f} s for pushes", flush=True)
    try:
        await asyncio.sleep(args.listen)
    finally:
        tunnel.terminate()
        server.shutdown()
    print(f"{len(received)} pushes", flush=True)


# AB props WhatsApp Web reads for push and background sync (codes from its bundled ABProps table, 2026-10-30).
PUSH_AB_PROPS = {
    8782: "web_background_sync_v2", 6656: "web_pwa_background_sync", 6706: "web_pwa_background_sync_min_interval_hours",
    13679: "enable_call_links_push_notification", 34763: "wa_web_calling_push_notification_on_call_end_enabled",
    36911: "web_call_push_notification_require_interaction", 29564: "web_calling_offline_resume_ordering",
    1773: "web_offline_resume_qpl_enabled", 16956: "web_offline_resume_wait_for_ping_timeout_seconds",
    36913: "web_voip_call_push_notification_clear_timeout_sec", 2508: "web_non_blocking_offline_resume_max_message_count",
}


async def command_abprops(args: argparse.Namespace) -> None:
    """The account's AB props (Baileys fetchProps): push-related ones by name, or every code with --all."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        response = await account.client.iq("abt", "get", [Node("props", {"protocol": "1"})])
        props = response.child("props")
        values = {int(prop.attr("config_code", "0")): prop.attr("config_value") for prop in (props.children() if props else []) if prop.tag == "prop"}
        print(f"{len(values)} props (hash {props.attr('hash') if props else None})", flush=True)
        for code, name in sorted(PUSH_AB_PROPS.items(), key=lambda item: item[1]):
            print(f"  {name} ({code}): {values.get(code, '<not sent: client default>')}", flush=True)
        if args.all:
            for code, value in sorted(values.items()):
                print(f"  {code}: {value[:80]}", flush=True)
    finally:
        await account.close()


async def command_push_clear(args: argparse.Namespace) -> None:
    """Removes this device's push registration, as WhatsApp Web's WASmaxPushConfigSetRPC `clear` does."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        response = await account.client.iq("urn:xmpp:whatsapp:push", "set", [Node("clear", {"platform": args.platform})])
        print(f"cleared: {response.describe()}", flush=True)
    finally:
        await account.close()


async def command_send(args: argparse.Namespace) -> None:
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    to = JID(session.lid.user, LID_SERVER) if args.to == "self" else JID.parse(args.to)
    if args.to != "self" and not args.allow_others:
        raise SystemExit("only `--to self` is allowed without --allow-others (send tests go to the self chat)")
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        if args.reply_to:
            # A reply quotes the original (whatsmeow examples): its id, sender and content in contextInfo.
            message = waE2E.Message()
            message.extendedTextMessage.text = args.text
            context = message.extendedTextMessage.contextInfo
            context.stanzaID = args.reply_to
            context.participant = str(JID(session.jid.user, USER_SERVER)) if args.quoted_from_me else str(to)
            context.quotedMessage.conversation = args.quoted_text or ""
        else:
            message = waE2E.Message(conversation=args.text)
        await send_dm(account, to, message)
        await asyncio.sleep(args.listen)
    finally:
        await account.close()


async def upload_media(account: Account, data: bytes, info: bytes, mms_type: str) -> dict:
    """Encrypts and uploads a file (whatsmeow Upload, rawUpload): AES-CBC under keys from a fresh media key, a
    10-byte HMAC, POSTed to the first media host with the media_conn auth. Returns what the message needs."""
    media_key = secrets.token_bytes(32)
    expanded = hkdf(media_key, 112, info=info)
    iv, cipher_key, mac_key = expanded[:16], expanded[16:48], expanded[48:80]
    ciphertext = aes_cbc_encrypt(cipher_key, iv, data)
    upload = ciphertext + hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()[:10]
    enc_sha256 = hashlib.sha256(upload).digest()
    response = await account.client.iq("w:m", "set", [Node("media_conn", {})])
    connection = response.child("media_conn")
    host = [child.attr("hostname") for child in connection.children() if child.tag == "host"][0]
    token = base64.urlsafe_b64encode(enc_sha256).decode()
    url = f"https://{host}/mms/{mms_type}/{token}?" + urllib.parse.urlencode({"auth": connection.attr("auth"), "token": token})
    request = urllib.request.Request(url, data=upload, method="POST", headers={"Origin": ORIGIN, "Referer": ORIGIN + "/", "Content-Type": "application/octet-stream"})
    body = json.loads(await asyncio.to_thread(lambda: urllib.request.urlopen(request, timeout=120).read()))
    return {"url": body["url"], "directPath": body["direct_path"], "mediaKey": media_key, "fileEncSHA256": enc_sha256,
            "fileSHA256": hashlib.sha256(data).digest(), "fileLength": len(data)}


async def command_send_media(args: argparse.Namespace) -> None:
    """Uploads a file and sends it to the self chat as a photo or document (whatsmeow Upload + ImageMessage)."""
    session = Session.load()
    to = JID(session.lid.user, LID_SERVER)
    with open(args.file, "rb") as file:
        data = file.read()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        info, mms_type, _ = MEDIA_FIELDS[f"{args.kind}Message"]
        uploaded = await upload_media(account, data, info, mms_type)
        print(f"uploaded {len(data)} bytes → {uploaded['directPath'][:40]}…", flush=True)
        message = waE2E.Message()
        media = getattr(message, f"{args.kind}Message")
        media.URL = uploaded["url"]
        media.directPath = uploaded["directPath"]
        media.mediaKey = uploaded["mediaKey"]
        media.fileEncSHA256 = uploaded["fileEncSHA256"]
        media.fileSHA256 = uploaded["fileSHA256"]
        media.fileLength = uploaded["fileLength"]
        media.mimetype = args.mimetype
        media.mediaKeyTimestamp = int(time.time())
        if args.kind == "image" and args.width:
            media.width, media.height = args.width, args.height
        if args.kind == "document":
            media.fileName = os.path.basename(args.file)
        await send_dm(account, to, message)
        await asyncio.sleep(3)
    finally:
        await account.close()


async def command_resend(args: argparse.Namespace) -> None:
    """Asks the phone for one message by its key (whatsmeow BuildUnavailableMessageRequest,
    PLACEHOLDER_MESSAGE_RESEND) and prints what the answer holds (kinds, whether media has a path), never text."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    answered = asyncio.get_running_loop().create_future()

    async def on_message(info: dict, message: Any) -> None:
        response = message.protocolMessage.peerDataOperationRequestResponseMessage if message.HasField("protocolMessage") else None
        if response is None or not response.peerDataOperationResult:
            return
        for result in response.peerDataOperationResult:
            raw = result.placeholderMessageResendResponse.webMessageInfoBytes
            if not raw:
                print("answer without a message", flush=True)
                continue
            web = importlib.import_module("waWeb.WAWebProtobufsWeb_pb2").WebMessageInfo.FromString(raw)
            part = media_of(web.message)
            detail = f"{part[0]} path={'yes' if part[1].directPath else 'no'} key={'yes' if part[1].mediaKey else 'no'}" if part else describe_message(web.message)
            print(f"resent {web.key.ID}: {detail}", flush=True)
        if not answered.done():
            answered.set_result(True)

    account.on_message = on_message
    await account.start()
    try:
        message = waE2E.Message()
        protocol = message.protocolMessage
        protocol.type = waE2E.ProtocolMessage.PEER_DATA_OPERATION_REQUEST_MESSAGE
        operation = protocol.peerDataOperationRequestMessage
        operation.peerDataOperationRequestType = waE2E.PeerDataOperationRequestType.PLACEHOLDER_MESSAGE_RESEND
        key = operation.placeholderMessageResendRequest.add().messageKey
        key.remoteJID = args.chat
        key.fromMe = args.from_me
        key.ID = args.id
        await send_peer(account, message)
        try:
            await asyncio.wait_for(answered, args.listen)
        except TimeoutError:
            print("no answer", flush=True)
    finally:
        await account.close()


async def command_react(args: argparse.Namespace) -> None:
    """A reaction (whatsmeow BuildReaction) to a message in the self chat; an empty --emoji removes it."""
    session = Session.load()
    to = JID(session.lid.user, LID_SERVER)
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        message = waE2E.Message()
        reaction = message.reactionMessage
        reaction.key.remoteJID = str(to)
        reaction.key.fromMe = args.from_me
        reaction.key.ID = args.id
        reaction.text = args.emoji
        reaction.senderTimestampMS = int(time.time() * 1000)
        await send_dm(account, to, message)
        await asyncio.sleep(3)
    finally:
        await account.close()


def command_forget_session(args: argparse.Namespace) -> None:
    session = Session.load()
    address = JID(session.lid.user, LID_SERVER, device=args.device).signal_address()
    sessions = session.data.get("signalSessions", {})
    print(f"forgot {address}" if sessions.pop(address, None) is not None else f"no session for {address}; sessions: {sorted(k for k in sessions if k.startswith(session.lid.user))}", flush=True)
    session.save()


async def command_typing(args: argparse.Namespace) -> None:
    """Presence available, composing then paused in the self chat, then unavailable (whatsmeow SendPresence,
    SendChatPresence); prints chatstate and presence nodes that arrive meanwhile."""
    session = Session.load()
    to = JID(session.lid.user, LID_SERVER)
    account = Account(session, verbose=args.verbose)

    async def show(node: Node) -> None:
        print(f"{node.tag} from {node.attr('from')} {[child.tag for child in node.children()]} {node.attrs.get('type', '')}", flush=True)

    account.client.handlers.update({"chatstate": show, "presence": show})
    await account.start()
    try:
        name = session.data.get("pushName") or "probe"
        await account.client.send(Node("presence", {"type": "available", "name": name}))
        await account.client.send(Node("chatstate", {"to": to}, [Node("composing", {})]))
        await asyncio.sleep(3)
        await account.client.send(Node("chatstate", {"to": to}, [Node("paused", {})]))
        await asyncio.sleep(2)
        await account.client.send(Node("presence", {"type": "unavailable", "name": name}))
        await asyncio.sleep(2)
        print("sent available, composing, paused, unavailable", flush=True)
    finally:
        await account.close()


MEDIA_FIELDS = {
    "imageMessage": (b"WhatsApp Image Keys", "image", "jpg"),
    "videoMessage": (b"WhatsApp Video Keys", "video", "mp4"),
    "audioMessage": (b"WhatsApp Audio Keys", "audio", "ogg"),
    "documentMessage": (b"WhatsApp Document Keys", "document", "bin"),
    "stickerMessage": (b"WhatsApp Image Keys", "image", "webp"),
}
MEDIA_DIR = os.path.join(ROOT, "logs", "whatsapp-media")


def media_of(message: Any) -> tuple[str, Any] | None:
    """The message's downloadable part (whatsmeow classToMediaType), looking inside view-once and ephemeral wrappers."""
    for wrapper in ("ephemeralMessage", "viewOnceMessage", "viewOnceMessageV2", "documentWithCaptionMessage"):
        if message.HasField(wrapper):
            return media_of(getattr(message, wrapper).message)
    for field in MEDIA_FIELDS:
        if message.HasField(field):
            return field, getattr(message, field)
    return None


def history_media(limit_per_kind: int, kinds: set[str], message_id: str | None = None) -> list[tuple]:
    """(chat, message id, field, media) from saved history syncs, newest files first, up to `limit_per_kind` per kind."""
    found: list[tuple] = []
    counts: dict[str, int] = {}
    seen: set[str] = set()
    for name in sorted(os.listdir(HISTORY_DIR), reverse=True) if os.path.isdir(HISTORY_DIR) else []:
        with open(os.path.join(HISTORY_DIR, name), "rb") as file:
            history = waHistorySync.HistorySync.FromString(file.read())
        for conversation in history.conversations:
            for item in conversation.messages:
                info = item.message
                part = media_of(info.message)
                if not part or info.key.ID in seen or (message_id and info.key.ID != message_id):
                    continue
                field, media = part
                if field not in kinds or counts.get(field, 0) >= limit_per_kind:
                    continue
                seen.add(info.key.ID)
                counts[field] = counts.get(field, 0) + 1
                found.append((conversation.ID, info.key.ID, field, media, info.messageTimestamp, info.key.fromMe, info.key.participant or info.participant))
    return found


async def media_retry(account: "Account", chat: str, message_id: str, from_me: bool, participant: str, media_key: bytes, timeout: float = 30) -> str:
    """Asks the phone to upload expired media again (whatsmeow SendMediaRetryReceipt) and returns the new direct
    path from its `mediaretry` notification (DecryptMediaRetryNotification)."""
    key = hkdf(media_key, 32, info=b"WhatsApp Media Retry Notification")
    iv = secrets.token_bytes(12)
    request = waMmsRetry.ServerErrorReceipt(stanzaID=message_id).SerializeToString()
    ciphertext = AESGCM(key).encrypt(iv, request, message_id.encode())
    rmr = {"jid": JID.parse(chat), "from_me": "true" if from_me else "false"}
    if chat.endswith("@g.us") and participant:
        rmr["participant"] = JID.parse(participant)
    waiter = asyncio.get_running_loop().create_future()
    account.media_retries[message_id] = waiter
    await account.client.send(
        Node(
            "receipt",
            {"id": message_id, "to": account.session.jid.non_ad(), "type": "server-error"},
            [Node("encrypt", {}, [Node("enc_p", {}, ciphertext), Node("enc_iv", {}, iv)]), Node("rmr", rmr)],
        )
    )
    node = await asyncio.wait_for(waiter, timeout)
    if node.child("error"):
        code = node.child("error").attr("code")
        raise SignalError("not available on the phone" if code == "2" else f"media retry error {code}")
    encrypt = node.child("encrypt")
    plaintext = AESGCM(key).decrypt(encrypt.child("enc_iv").bytes(), encrypt.child("enc_p").bytes(), message_id.encode())
    notification = waMmsRetry.MediaRetryNotification.FromString(plaintext)
    if notification.result != waMmsRetry.MediaRetryNotification.SUCCESS:
        raise SignalError(f"media retry result {waMmsRetry.MediaRetryNotification.ResultType.Name(notification.result)}")
    return notification.directPath


async def command_media(args: argparse.Namespace) -> None:
    """Downloads and decrypts media from saved history (whatsmeow Download): prints each file's kind, MIME type,
    sizes and the inline thumbnail's size, and saves it under logs/whatsapp-media (0600) for checking its format.
    Never prints captions or other content."""
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    kinds = set(args.kind) if args.kind else set(MEDIA_FIELDS)
    items = history_media(args.limit, kinds, args.id)
    if not items:
        raise SystemExit("no media in saved history")
    account = Account(session, verbose=args.verbose)
    await account.start()
    os.makedirs(MEDIA_DIR, mode=0o700, exist_ok=True)
    try:
        for chat, identifier, field, media, timestamp, from_me, participant in items:
            info, mms_type, extension = MEDIA_FIELDS[field]
            extras = []
            if field == "audioMessage":
                extras.append(f"ptt={media.PTT} seconds={media.seconds} waveform={len(media.waveform)}")
            if field == "videoMessage":
                extras.append(f"gif={media.gifPlayback} seconds={media.seconds}")
            if field == "stickerMessage":
                extras.append(f"animated={media.isAnimated}")
            if field in ("imageMessage", "videoMessage", "stickerMessage"):
                extras.append(f"{media.width}x{media.height}")
            thumbnail = len(media.JPEGThumbnail) if hasattr(media, "JPEGThumbnail") else len(getattr(media, "pngThumbnail", b""))
            extras.append(f"age={(time.time() - timestamp) / 86400:.0f}d")
            started = time.monotonic()
            try:
                if not media.directPath:
                    raise SignalError("no direct path (404)")
                data = await account.download_media(media.directPath, media.fileEncSHA256, media.fileSHA256, media.mediaKey, info, mms_type)
            except Exception as error:  # noqa: BLE001
                expired = any(code in str(error) for code in ("403", "404", "410"))
                print(f"{field} {chat} {identifier} {media.mimetype} {' '.join(extras)} FAILED: {error}", flush=True)
                if not (args.retry and expired):
                    continue
                try:
                    direct_path = await media_retry(account, chat, identifier, from_me, participant, media.mediaKey)
                    print(f"  media retry gave a new path; downloading", flush=True)
                    data = await account.download_media(direct_path, media.fileEncSHA256, media.fileSHA256, media.mediaKey, info, mms_type)
                except Exception as retry_error:  # noqa: BLE001
                    print(f"  media retry FAILED: {retry_error}", flush=True)
                    continue
            path = os.path.join(MEDIA_DIR, f"{identifier}.{extension}")
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as file:
                file.write(data)
            print(
                f"{field} {chat} {identifier} {media.mimetype} {len(data)} bytes (declared {media.fileLength}) "
                f"thumb={thumbnail} {' '.join(extras)} ok in {time.monotonic() - started:.1f}s",
                flush=True,
            )
    finally:
        await account.close()


async def command_read(args: argparse.Namespace) -> None:
    """Read receipt for message ids in a chat (whatsmeow MarkRead); --sender is required in groups."""
    session = Session.load()
    account = Account(session, verbose=args.verbose)
    await account.start()
    try:
        chat = JID.parse(args.chat)
        attrs = {"id": args.ids[0], "type": "read", "to": chat, "t": int(time.time())}
        if args.sender and chat.server not in (USER_SERVER, LID_SERVER):
            attrs["participant"] = JID.parse(args.sender).non_ad()
        items = [Node("list", {}, [Node("item", {"id": identifier}) for identifier in args.ids[1:]])] if len(args.ids) > 1 else None
        await account.client.send(Node("receipt", attrs, items))
        await asyncio.sleep(3)
        print("sent read receipt", flush=True)
    finally:
        await account.close()


# ---------------------------------------------------------------------------------------------------------
# Commands


async def command_link(args: argparse.Namespace) -> None:
    session = Session.load()
    if session and session.jid and not args.force:
        raise SystemExit(f"already linked as {session.jid}; pass --force to link a new device")
    session = Session.create()
    session.data["waVersion"] = list(fetch_wa_version())
    session.save()
    client = Client(session, verbose=args.verbose)
    linker = Linker(client, args.phone)
    await client.connect()
    reconnected = False
    code_path = os.path.join(ROOT, "logs", "whatsapp-link-code.txt")
    qr_count, qr_paths = 0, []
    try:
        while True:
            kind, value = await asyncio.wait_for(client.events.get(), args.timeout)
            if kind == "code":
                with open(code_path, "w") as file:
                    file.write(value + "\n")
                print(f"pairing code: {value} (WhatsApp → Linked devices → Link a device → Link with phone number instead)", flush=True)
                if args.offline is not None and not reconnected:
                    # What the app does when iOS suspends it: the socket dies, the keys and pairing stay.
                    reconnected = True
                    await client.close()
                    print(f"disconnected; offline for {args.offline:.0f} s", flush=True)
                    await asyncio.sleep(args.offline)
                    client = Client(session, verbose=args.verbose)
                    linker.attach(client)
                    await client.connect()
                    print("reconnected with the same keys; waiting for link_code_companion_reg", flush=True)
            elif kind == "qr":
                import qrcode

                qr_count += 1
                path = os.path.join(ROOT, "logs", f"whatsapp-qr-{qr_count}.png")
                qrcode.make(value).save(path)
                qr_paths.append(path)
                if args.open_qr:
                    subprocess.run(["open", path], check=False)
                print(f"qr {qr_count}: {os.path.relpath(path, ROOT)}", flush=True)
            elif kind == "qr-timeout":
                raise SystemExit("QR codes expired")
            elif kind == "paired":
                print(f"paired as {value}", flush=True)
            elif kind == "closed":
                break
            elif kind == "error":
                raise value
    finally:
        await client.close()
        for path in [code_path, *qr_paths]:
            if os.path.exists(path):
                os.remove(path)
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not paired")
    # WhatsApp closes the stream after pairing (515); the first login uploads prekeys.
    await login_and_listen(session, args.verbose, duration=args.listen)


class Account:
    """A logged-in linked device: decrypts stanzas in order, sends receipts, keeps the session file current."""

    def __init__(self, session: Session, verbose: bool = False, show_text: bool = False) -> None:
        self.session = session
        self.client = Client(session, verbose=verbose)
        self.store = SignalStore(session)
        self.show_text = show_text
        self.success: asyncio.Future = asyncio.get_running_loop().create_future()
        self.messages: asyncio.Queue[Node] = asyncio.Queue()
        self.offline_done = asyncio.Event()
        self.on_message: Any = None
        self.media_retries: dict[str, asyncio.Future] = {}
        session.data.setdefault("lidMap", {})
        session.data.setdefault("appStateKeys", {})
        session.data.setdefault("pushNames", {})
        own_jid, own_lid = session.jid, session.lid
        if own_jid and own_lid:
            session.data["lidMap"][own_jid.user] = own_lid.user
        self.client.handlers.update(
            {
                "success": self.handle_success,
                "failure": self.handle_failure,
                "stream:error": self.handle_stream_error,
                "message": self.enqueue_message,
                "receipt": self.handle_receipt,
                "notification": self.handle_notification,
                "ib": self.handle_ib,
                "iq": self.handle_iq,
                "call": self.client.ack,
                "presence": self.ignore,
                "chatstate": self.ignore,
            }
        )

    async def ignore(self, node: Node) -> None:
        pass

    async def start(self) -> None:
        await self.client.connect()
        node = await asyncio.wait_for(self.success, 30)
        print(f"logged in as {self.session.jid} (lid {self.session.data.get('lid')}), server time {node.attr('t')}", flush=True)
        self.client.spawn(self.message_loop())
        await ensure_prekeys(self.client)
        await self.client.iq("passive", "set", [Node("active", {})])

    async def close(self) -> None:
        await self.client.close()

    async def handle_success(self, node: Node) -> None:
        if node.attrs.get("lid") and not self.session.data.get("lid"):
            self.session.data["lid"] = str(node.attrs["lid"])
            self.session.save()
        if not self.success.done():
            self.success.set_result(node)

    async def handle_failure(self, node: Node) -> None:
        reason = node.attr("reason")
        if not self.success.done():
            self.success.set_exception(SystemExit(f"connect failure {reason}: {node.describe()}"))

    async def handle_stream_error(self, node: Node) -> None:
        log(f"stream error: {node.describe()}")

    async def handle_ib(self, node: Node) -> None:
        for child in node.children():
            if child.tag == "offline_preview":
                log(f"offline preview: {child.attrs}")
            elif child.tag == "offline":
                log(f"offline sync done ({child.attr('count')} stanzas)")
                self.offline_done.set()

    async def handle_iq(self, node: Node) -> None:
        log(f"server iq: {node.describe()}")

    async def handle_receipt(self, node: Node) -> None:
        await self.client.ack(node)

    async def handle_notification(self, node: Node) -> None:
        await self.client.ack(node)
        kind = node.attr("type")
        if kind == "encrypt" and node.attrs.get("from") == SERVER_JID and node.child("count"):
            if int(node.child("count").attr("value", "0")) < MIN_PREKEY_COUNT:
                await ensure_prekeys(self.client)
        if kind == "privacy_token" and node.child("tokens"):
            sender = JID.parse(node.attr("sender_lid") or node.attr("from"))
            user = self.session.data["lidMap"].get(sender.user, sender.user) if sender.server == USER_SERVER else sender.user
            for token in node.child("tokens").children():
                if token.tag == "token" and token.attr("type") == "trusted_contact":
                    entry = self.session.data.setdefault("privacyTokens", {}).setdefault(user, {"senderT": 0})
                    entry.update({"token": b64(token.bytes()), "t": int(token.attr("t", "0"))})
            self.session.save()
        if kind == "mediaretry":
            waiter = self.media_retries.pop(node.attr("id"), None)
            if waiter and not waiter.done():
                waiter.set_result(node)
        log(f"notification {kind} from {node.attr('from')}")

    async def enqueue_message(self, node: Node) -> None:
        await self.messages.put(node)

    async def message_loop(self) -> None:
        while True:
            node = await self.messages.get()
            try:
                await self.handle_message(node)
            except Exception as error:  # noqa: BLE001
                log(f"message {node.attr('id')} failed: {type(error).__name__}: {error}")
                await self.client.ack(node)

    # --- addressing

    def lid_for(self, jid: JID) -> JID | None:
        lid = self.session.data["lidMap"].get(jid.user)
        return JID(lid, LID_SERVER, jid.device) if lid else None

    def store_lid(self, pn: JID | None, lid: JID | None) -> None:
        if pn and lid and pn.server == USER_SERVER and lid.server == LID_SERVER:
            if self.session.data["lidMap"].get(pn.user) != lid.user:
                self.session.data["lidMap"][pn.user] = lid.user
                self.session.save()

    def source(self, node: Node) -> dict:
        """whatsmeow parseMessageSource."""
        own_jid, own_lid = self.session.jid, self.session.lid
        own_users = {own_jid.user, own_lid.user if own_lid else None}
        sender_from = node.attrs["from"]
        info: dict[str, Any] = {"id": node.attr("id"), "t": int(node.attr("t", "0")), "type": node.attr("type"), "category": node.attr("category"), "notify": node.attr("notify")}
        alt = None
        if sender_from.server in (GROUP_SERVER, "broadcast"):
            info["group"] = True
            info["chat"] = sender_from
            sender = node.attrs.get("participant")
            alt = node.attrs.get("participant_pn") or (node.attrs.get("participant_lid") if node.attr("addressing_mode") != "lid" else None)
            info["fromMe"] = bool(sender and sender.user in own_users)
        elif sender_from.user in own_users:
            info["group"] = False
            info["fromMe"] = True
            sender = sender_from
            recipient = node.attrs.get("recipient")
            info["chat"] = recipient if recipient else sender_from.non_ad()
        else:
            info["group"] = False
            info["fromMe"] = False
            sender = sender_from
            info["chat"] = sender_from.non_ad()
            alt = node.attrs.get("sender_pn") if sender.server == LID_SERVER else node.attrs.get("sender_lid")
        if alt and alt.device == 0 and sender:
            alt = JID(alt.user, alt.server, sender.device)
        info["sender"] = sender
        info["senderAlt"] = alt
        return info

    def encryption_jid(self, info: dict) -> JID:
        sender, alt = info["sender"], info["senderAlt"]
        if sender.server == USER_SERVER:
            if alt and alt.server == LID_SERVER:
                self.store_lid(sender, alt)
                return alt
            lid = self.lid_for(sender)
            if lid:
                return lid
            log(f"no LID known for {sender}")
        elif sender.server == LID_SERVER and alt and alt.server == USER_SERVER:
            self.store_lid(alt, sender)
        return sender

    # --- messages

    async def handle_message(self, node: Node) -> None:
        info = self.source(node)
        if info["notify"] and info["sender"]:
            self.session.data["pushNames"][info["sender"].user] = info["notify"]
        enc_children = [child for child in node.children() if child.tag == "enc"]
        if not enc_children:
            log(f"message {info['id']} without enc ({[child.tag for child in node.children()]})")
            await self.client.ack(node)
            return
        address_jid = self.encryption_jid(info)
        address = address_jid.signal_address()
        decrypted_any = False
        for child in enc_children:
            kind = child.attr("type")
            try:
                if kind == "pkmsg":
                    plaintext = self.store.decrypt_prekey_message(address, child.bytes(), keep_state=child.attr("state") != "false")
                elif kind == "msg":
                    plaintext = self.store.decrypt_message(address, child.bytes())
                elif kind == "skmsg" and info["group"]:
                    plaintext = self.store.decrypt_group_message(str(info["chat"]), address, child.bytes())
                else:
                    log(f"unhandled enc type {kind} in {info['id']}")
                    continue
            except OldCounterError as error:
                log(f"ignoring {info['id']}: {error}")
                continue
            except SignalError as error:
                log(f"couldn't decrypt {kind} {info['id']} from {address}: {error}")
                await self.send_retry_receipt(node, info)
                return
            version = int(child.attr("v", "2"))
            if version != 2:
                log(f"enc v{version} in {info['id']} isn't handled yet")
                continue
            message = waE2E.Message.FromString(unpad_message(plaintext, version))
            decrypted_any = True
            await self.handle_decrypted(info, message, address_jid)
        await self.send_message_receipt(node, info) if decrypted_any else await self.client.ack(node)

    async def handle_decrypted(self, info: dict, message: Any, address_jid: JID) -> None:
        inner = message.deviceSentMessage.message if message.HasField("deviceSentMessage") else message
        if inner.HasField("senderKeyDistributionMessage") and info["group"]:
            self.store.process_sender_key_distribution(str(info["chat"]), address_jid.signal_address(), inner.senderKeyDistributionMessage.axolotlSenderKeyDistributionMessage)
        if inner.HasField("protocolMessage"):
            await self.handle_protocol_message(info, inner.protocolMessage)
        summary = describe_message(inner)
        chat = message.deviceSentMessage.destinationJID if message.HasField("deviceSentMessage") else str(info["chat"])
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(info['t']))} {chat} {'me' if info['fromMe'] else info['sender']} {info['id']} {summary}"
        if self.show_text and info["fromMe"]:
            text = inner.conversation or inner.extendedTextMessage.text
            if text:
                line += f" {text!r}"
        print(line, flush=True)
        if self.on_message:
            await self.on_message(info, inner)

    async def handle_protocol_message(self, info: dict, protocol: Any) -> None:
        if not info["fromMe"]:
            return
        if protocol.HasField("historySyncNotification"):
            notification = protocol.historySyncNotification
            try:
                await self.save_history_sync(notification)
            finally:
                await self.client.send(Node("receipt", {"id": info["id"], "type": "hist_sync", "to": self.session.jid.non_ad()}))
        if protocol.HasField("appStateSyncKeyShare"):
            for key in protocol.appStateSyncKeyShare.keys:
                key_id = key.keyID.keyID.hex()
                self.session.data["appStateKeys"][key_id] = {
                    "data": b64(key.keyData.keyData),
                    "fingerprint": b64(key.keyData.fingerprint.SerializeToString()),
                    "timestamp": key.keyData.timestamp,
                }
            self.session.save()
            log(f"stored {len(protocol.appStateSyncKeyShare.keys)} app state keys")
        if protocol.HasField("lidMigrationMappingSyncMessage"):
            lid_module = importlib.import_module("waLidMigrationSyncPayload.WAWebProtobufLidMigrationSyncPayload_pb2")
            payload = lid_module.LIDMigrationMappingSyncPayload.FromString(protocol.lidMigrationMappingSyncMessage.encodedMappingPayload)
            for mapping in payload.pnToLidMappings:
                self.session.data["lidMap"][str(mapping.pn)] = str(mapping.assignedLid)
            self.session.save()
            log(f"stored {len(payload.pnToLidMappings)} LID mappings")
        if info["category"] == "peer":
            await self.client.send(Node("receipt", {"id": info["id"], "type": "peer_msg", "to": self.session.jid.non_ad()}))

    async def send_retry_receipt(self, node: Node, info: dict) -> None:
        """Asks the sender to encrypt the message again (whatsmeow sendRetryReceipt): at most 4 times per message,
        with a fresh one-time prekey and our identity from the second time on."""
        identifier = info["id"]
        retries = self.session.data.setdefault("retries", {})
        count = retries.get(identifier, 0) + 1
        in_message = [child for child in node.children() if child.tag == "enc"]
        if count == 1 and len(in_message) == 1 and in_message[0].attr("count"):
            count = int(in_message[0].attr("count")) + 1
        retries[identifier] = count
        self.session.save()
        if count >= 5:
            log(f"not sending more retry receipts for {identifier}")
            await self.client.ack(node)
            return
        attrs = {"id": identifier, "to": node.attrs["from"], "type": "retry"}
        for key in ("participant", "recipient"):
            if key in node.attrs:
                attrs[key] = node.attrs[key]
        if info["type"] == "peer_msg" and info["fromMe"]:
            attrs["category"] = "peer"
        content = [
            Node("retry", {"count": str(count), "id": identifier, "t": node.attrs.get("t", str(int(time.time()))), "v": "1"}),
            Node("registration", {}, struct.pack(">I", self.session.data["registrationId"])),
        ]
        if count > 1:
            key_id = self.session.data["nextPreKeyId"]
            self.session.data["nextPreKeyId"] += 1
            pair = KeyPair.generate()
            self.session.data["preKeys"][str(key_id)] = pair.to_json()
            self.session.save()
            signed = self.session.data["signedPreKey"]
            content.append(Node("keys", {}, [
                Node("type", {}, bytes([DJB_TYPE])),
                Node("identity", {}, self.session.identity_key.public),
                Node("key", {}, [Node("id", {}, struct.pack(">I", key_id)[1:]), Node("value", {}, pair.public)]),
                Node("skey", {}, [Node("id", {}, struct.pack(">I", signed["id"])[1:]), Node("value", {}, unb64(signed["public"])), Node("signature", {}, unb64(signed["signature"]))]),
                Node("device-identity", {}, unb64(self.session.data["account"])),
            ]))
        await self.client.send(Node("receipt", attrs, content))
        await self.client.ack(node)
        print(f"sent retry receipt #{count} for {identifier} to {node.attrs['from']}{' with keys' if count > 1 else ''}", flush=True)

    async def send_message_receipt(self, node: Node, info: dict) -> None:
        attrs = {"id": info["id"], "to": node.attrs["from"]}
        for key in ("recipient", "participant"):
            if key in node.attrs:
                attrs[key] = node.attrs[key]
        if info["fromMe"]:
            attrs["type"] = "peer_msg" if info["type"] == "peer_msg" else "sender"
        else:
            # Like whatsmeow without active receipts: delivered to an inactive device, never "read".
            attrs["type"] = "inactive"
        await self.client.send(Node("receipt", attrs))

    # --- history sync

    async def save_history_sync(self, notification: Any) -> None:
        if notification.initialHistBootstrapInlinePayload:
            compressed = notification.initialHistBootstrapInlinePayload
        else:
            compressed = await self.download_media(notification.directPath, notification.fileEncSHA256, notification.fileSHA256, notification.mediaKey, b"WhatsApp History Keys", "md-msg-hist")
        raw = zlib.decompress(compressed)
        history = waHistorySync.HistorySync.FromString(raw)
        os.makedirs(HISTORY_DIR, mode=0o700, exist_ok=True)
        name = f"{int(time.time() * 1000)}-{waHistorySync.HistorySync.HistorySyncType.Name(history.syncType)}-{history.chunkOrder}.pb"
        path = os.path.join(HISTORY_DIR, name)
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as file:
            file.write(raw)
        for mapping in history.phoneNumberToLidMappings:
            pn, lid = JID.parse(mapping.pnJID), JID.parse(mapping.lidJID)
            self.session.data["lidMap"][pn.user] = lid.user
        for push_name in history.pushnames:
            self.session.data["pushNames"][JID.parse(push_name.ID).user] = push_name.pushname
        self.session.save()
        messages = sum(len(conversation.messages) for conversation in history.conversations)
        print(
            f"history sync {waHistorySync.HistorySync.HistorySyncType.Name(history.syncType)} chunk {history.chunkOrder} progress {history.progress}: "
            f"{len(history.conversations)} chats, {messages} messages, {len(history.pushnames)} push names, "
            f"{len(history.phoneNumberToLidMappings)} LID mappings → {os.path.relpath(path, ROOT)}",
            flush=True,
        )

    async def download_media(self, direct_path: str, enc_sha256: bytes, sha256: bytes, media_key: bytes, info: bytes, mms_type: str) -> bytes:
        response = await self.client.iq("w:m", "set", [Node("media_conn", {})])
        hosts = [host.attr("hostname") for host in response.child("media_conn").children() if host.tag == "host"]
        expanded = hkdf(media_key, 112, info=info)
        iv, cipher_key, mac_key = expanded[:16], expanded[16:48], expanded[48:80]
        last_error: Exception | None = None
        for host in hosts:
            url = f"https://{host}{direct_path}&hash={base64.urlsafe_b64encode(enc_sha256).decode()}&mms-type={mms_type}&__wa-mms="
            request = urllib.request.Request(url, headers={"Origin": ORIGIN, "Referer": ORIGIN + "/"})
            try:
                data = await asyncio.to_thread(lambda: urllib.request.urlopen(request, timeout=60).read())
            except Exception as error:  # noqa: BLE001
                last_error = error
                continue
            if hashlib.sha256(data).digest() != enc_sha256:
                raise SignalError("media enc SHA-256 mismatch")
            file, mac = data[:-10], data[-10:]
            if not hmac.compare_digest(hmac.new(mac_key, iv + file, hashlib.sha256).digest()[:10], mac):
                raise SignalError("media HMAC mismatch")
            plaintext = aes_cbc_decrypt(cipher_key, iv, file)
            if hashlib.sha256(plaintext).digest() != sha256:
                raise SignalError("media SHA-256 mismatch")
            return plaintext
        raise SignalError(f"media download failed: {last_error}")


def describe_message(message: Any) -> str:
    """The message's content kinds, never its text."""
    fields = [field.name for field, _ in message.ListFields() if field.name not in ("messageContextInfo",)]
    if message.HasField("protocolMessage"):
        fields.append(waE2E.ProtocolMessage.Type.Name(message.protocolMessage.type))
    return ",".join(fields) or "empty"


async def login_and_listen(session: Session, verbose: bool, duration: float, show_text: bool = False) -> None:
    account = Account(session, verbose=verbose, show_text=show_text)
    await account.start()
    try:
        kind, value = await asyncio.wait_for(account.client.events.get(), duration)
        if kind == "error":
            raise value
        log(f"stopped: {kind}")
    except TimeoutError:
        pass
    await account.close()


async def ensure_prekeys(client: Client) -> None:
    session = client.session
    response = await client.iq("encrypt", "get", [Node("count", {})])
    count = int(response.child("count").attr("value", "0"))
    uploaded = session.data["uploadedPreKeyId"]
    print(f"server has {count} prekeys", flush=True)
    if count >= MIN_PREKEY_COUNT and uploaded:
        return
    wanted = INITIAL_PREKEY_COUNT if count == 0 and not uploaded else WANTED_PREKEY_COUNT
    keys = []
    for _ in range(wanted):
        key_id = session.data["nextPreKeyId"]
        session.data["nextPreKeyId"] += 1
        pair = KeyPair.generate()
        session.data["preKeys"][str(key_id)] = pair.to_json()
        keys.append((key_id, pair))
    session.save()
    signed = session.data["signedPreKey"]
    await client.iq(
        "encrypt",
        "set",
        [
            Node("registration", {}, struct.pack(">I", session.data["registrationId"])),
            Node("type", {}, bytes([DJB_TYPE])),
            Node("identity", {}, session.identity_key.public),
            Node("list", {}, [Node("key", {}, [Node("id", {}, struct.pack(">I", key_id)[1:]), Node("value", {}, pair.public)]) for key_id, pair in keys]),
            Node(
                "skey",
                {},
                [
                    Node("id", {}, struct.pack(">I", signed["id"])[1:]),
                    Node("value", {}, unb64(signed["public"])),
                    Node("signature", {}, unb64(signed["signature"])),
                ],
            ),
        ],
    )
    session.data["uploadedPreKeyId"] = keys[-1][0]
    session.save()
    print(f"uploaded {len(keys)} prekeys", flush=True)


async def command_connect(args: argparse.Namespace) -> None:
    session = Session.load()
    if not session or not session.jid:
        raise SystemExit("not linked; run `link` first")
    await login_and_listen(session, args.verbose, duration=args.listen, show_text=args.show_text)


def command_version(_: argparse.Namespace) -> None:
    version = fetch_wa_version()
    print(".".join(map(str, version)))
    session = Session.load()
    if session:
        session.data["waVersion"] = list(version)
        session.save()


def command_selftest(_: argparse.Namespace) -> None:
    pair = KeyPair.generate()
    message = b"stupid social"
    signature = pair.sign(message)
    assert xeddsa_verify(pair.public, message, signature), "XEdDSA round trip"
    assert not xeddsa_verify(pair.public, message + b"!", signature), "XEdDSA rejects a changed message"
    node = Node(
        "iq",
        {"id": "1.2-3", "to": JID("27821234567", USER_SERVER, 3), "lid": JID("123456", LID_SERVER, 2), "type": "get", "xmlns": "w:p", "t": 1700000000},
        [Node("ref", {}, b"\x00\x01"), Node("text", {}, "ABCDEF"), Node("x", {"hex": "DEADBEEF"})],
    )
    decoded = decode_frame(encode_node(node))
    assert decoded.attrs["to"] == JID("27821234567", USER_SERVER, 3), decoded.attrs
    assert decoded.attrs["lid"] == JID("123456", LID_SERVER, 2), decoded.attrs
    assert decoded.attrs["t"] == "1700000000"
    assert decoded.children()[0].content == b"\x00\x01"
    assert decoded.children()[1].content in (b"ABCDEF", "ABCDEF")
    signal_selftest()
    print("ok")


def signal_selftest() -> None:
    """Alice builds a session from Bob's bundle, sends a prekey message, Bob replies, Alice replies again."""

    class MemorySession(Session):
        def save(self) -> None:
            pass

    alice, bob = MemorySession(Session.create().data), MemorySession(Session.create().data)
    bob_one_time = KeyPair.generate()
    bob.data["preKeys"]["7"] = bob_one_time.to_json()
    alice_store, bob_store = SignalStore(alice), SignalStore(bob)
    signed = bob.data["signedPreKey"]
    alice_store.build_session(
        "bob.0",
        {
            "identity": bob.identity_key.public, "signedPreKey": unb64(signed["public"]), "signature": unb64(signed["signature"]),
            "signedPreKeyId": signed["id"], "preKey": bob_one_time.public, "preKeyId": 7, "registrationId": bob.data["registrationId"],
        },
    )
    kind, first = alice_store.encrypt("bob.0", b"hello bob")
    assert kind == "pkmsg"
    assert bob_store.decrypt_prekey_message("alice.0", first) == b"hello bob"
    assert "7" not in bob.data["preKeys"], "one-time prekey is consumed"
    kind, reply = bob_store.encrypt("alice.0", b"hello alice")
    assert kind == "msg"
    assert alice_store.decrypt_message("bob.0", reply) == b"hello alice"
    kind, second = alice_store.encrypt("bob.0", b"again")
    assert kind == "msg", "the pending prekey clears once Bob has answered"
    kind, third = alice_store.encrypt("bob.0", b"out of order")
    assert bob_store.decrypt_message("alice.0", third) == b"out of order"
    assert bob_store.decrypt_message("alice.0", second) == b"again", "skipped message keys are kept"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verbose", action="store_true", help="print every node (binary contents as lengths)")
    commands = parser.add_subparsers(dest="command", required=True)

    link = commands.add_parser("link", help="link this probe as a new device")
    link.add_argument("--phone", help="link with an 8-character code for this international number instead of a QR code")
    link.add_argument("--force", action="store_true", help="replace an existing linked session")
    link.add_argument("--open-qr", action="store_true", help="open each QR code image (logs/whatsapp-qr-N.png) in Preview")
    link.add_argument("--timeout", type=float, default=300)
    link.add_argument("--offline", type=float, help="with --phone: after the code, close the socket for this many seconds, then reconnect with the same keys")
    link.add_argument("--listen", type=float, default=300, help="seconds to stay connected after linking (history sync arrives then)")
    link.set_defaults(handler=command_link)

    connect = commands.add_parser("connect", help="log in and print incoming node types")
    connect.add_argument("--listen", type=float, default=60)
    connect.add_argument("--show-text", action="store_true", help="print the text of messages the account itself sent")
    connect.set_defaults(handler=command_connect)

    appstate = commands.add_parser("appstate", help="sync app state (contact names, mute, archive, pin) into logs/whatsapp-appstate.json")
    appstate.add_argument("--full", action="store_true", help="start from snapshots instead of the stored versions")
    appstate.set_defaults(handler=command_appstate)

    flags = commands.add_parser("history-flags", help="archive, pin and mute for one chat in each saved history sync and in app state")
    flags.add_argument("--chat", required=True, help="the chat's JID")
    flags.set_defaults(handler=command_history_flags)
    chats = commands.add_parser("chats", help="list chats from saved history and app state (names, unread, flags; no text)")
    chats.add_argument("--limit", type=int, default=30)
    chats.add_argument("--archived", action="store_true")
    chats.set_defaults(handler=command_chats)

    send = commands.add_parser("send", help="send a text message (only to the self chat unless --allow-others)")
    send.add_argument("--to", default="self", help="`self`, or a user JID")
    send.add_argument("--text", required=True)
    send.add_argument("--allow-others", action="store_true")
    send.add_argument("--reply-to", help="message id to quote")
    send.add_argument("--quoted-text", help="the quoted message's text, as replies carry it")
    send.add_argument("--quoted-from-me", action="store_true", help="the quoted message is the account's own")
    react = commands.add_parser("react", help="react to a message in the self chat (empty --emoji removes it)")
    react.add_argument("--id", required=True)
    react.add_argument("--emoji", default="👍")
    react.add_argument("--from-me", action="store_true", help="the reacted message is the account's own")
    react.set_defaults(handler=command_react)
    commands.add_parser("typing", help="send presence and typing in the self chat").set_defaults(handler=command_typing)
    resend = commands.add_parser("resend", help="ask the phone for one message by its key (prints kinds, never text)")
    resend.add_argument("--chat", required=True)
    resend.add_argument("--id", required=True)
    resend.add_argument("--from-me", action="store_true")
    resend.add_argument("--listen", type=float, default=30)
    resend.set_defaults(handler=command_resend)
    send_media = commands.add_parser("send-media", help="upload a file and send it to the self chat")
    send_media.add_argument("--file", required=True)
    send_media.add_argument("--kind", choices=["image", "document", "video", "audio"], default="image")
    send_media.add_argument("--mimetype", default="image/jpeg")
    send_media.add_argument("--width", type=int)
    send_media.add_argument("--height", type=int)
    send_media.set_defaults(handler=command_send_media)
    forget = commands.add_parser("forget-session", help="drop the Signal session with one of the account's own devices (to test retry receipts)")
    forget.add_argument("--device", type=int, required=True, help="the device number under the user's LID")
    forget.set_defaults(handler=command_forget_session)
    send.add_argument("--listen", type=float, default=10)
    send.set_defaults(handler=command_send)

    avatar = commands.add_parser("avatar", help="fetch profile picture URLs (prints metadata, downloads to check, never saves)")
    avatar.add_argument("jids", nargs="+", help="`self`, user or group JIDs")
    avatar.add_argument("--full", action="store_true", help="the full image instead of the preview")
    avatar.add_argument("--existing-id", help="the picture id already held, to get a 304 when unchanged")
    avatar.set_defaults(handler=command_avatar)

    abprops = commands.add_parser("abprops", help="print the account's push-related AB props")
    abprops.add_argument("--all", action="store_true")
    abprops.set_defaults(handler=command_abprops)

    clear = commands.add_parser("push-clear", help="remove this device's push registration")
    clear.add_argument("--platform", default="web")
    clear.set_defaults(handler=command_push_clear)

    commands.add_parser("push-settings", help="print the server's push settings").set_defaults(handler=command_push_settings)

    capture = commands.add_parser("push-capture", help="register a Web Push endpoint on a temporary tunnel and capture pushes while offline")
    capture.add_argument("--port", type=int, default=8791)
    capture.add_argument("--listen", type=float, default=300)
    capture.add_argument("--unavailable", action="store_true", help="send presence unavailable before going offline")
    capture.set_defaults(handler=command_push_capture)

    media = commands.add_parser("media", help="download and decrypt media from saved history (prints kind, type, sizes; never content)")
    media.add_argument("--kind", action="append", choices=sorted(MEDIA_FIELDS), help="limit to these message kinds (repeatable)")
    media.add_argument("--limit", type=int, default=2, help="files per kind")
    media.add_argument("--id", help="only this message id")
    media.add_argument("--retry", action="store_true", help="on 403/404/410, ask the phone to upload the file again (one request per file)")
    media.set_defaults(handler=command_media)
    history = commands.add_parser("history", help="ask the phone for older messages in one chat (on-demand history sync)")
    history.add_argument("--chat", required=True, help="the chat JID")
    history.add_argument("--count", type=int, default=50)
    history.add_argument("--listen", type=float, default=30)
    history.set_defaults(handler=command_history)
    read = commands.add_parser("read", help="send a read receipt")
    read.add_argument("--chat", required=True)
    read.add_argument("--sender", help="the sender's JID, in groups")
    read.add_argument("ids", nargs="+")
    read.set_defaults(handler=command_read)

    commands.add_parser("version", help="fetch the current web client version").set_defaults(handler=command_version)
    commands.add_parser("selftest", help="offline checks of the codec and signatures").set_defaults(handler=command_selftest)

    args = parser.parse_args()
    result = args.handler(args)
    if asyncio.iscoroutine(result):
        asyncio.run(result)


if __name__ == "__main__":
    main()
