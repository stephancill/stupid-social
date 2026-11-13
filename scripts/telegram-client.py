#!/usr/bin/env python3
"""Dependency-free Telegram MTProto 2.0 probe: the source of truth for the native Swift client.

Talks to Telegram's production DCs over TCP (intermediate transport) with a user account, using the TL
schema in Sources/StupidSocialCore/Resources/TelegramSchema.tl (built by scripts/telegram-schema.py).

API credentials come from TELEGRAM_APP_ID and TELEGRAM_APP_API_HASH (environment or .env.local), from
https://my.telegram.org. The session (auth keys per DC, salts, peer access hashes) is kept in
logs/telegram-session.json, which holds secrets and is never committed.

Commands:
  handshake [--dc N]          create a fresh auth key on a DC (no credentials needed)
  config                      help.getConfig: this DC and the DC list
  send-code --phone +...      auth.sendCode; keeps phone_code_hash in the session
  sign-in --code 12345        auth.signIn; reports when a 2FA password is needed
  password                    auth.checkPassword (SRP) with TELEGRAM_USER_PASSWORD (environment or .env.local) or a prompt
  me                          the signed-in user
  dialogs [--limit N] [--archived]   messages.getDialogs, newest first; --archived for the Archive folder
  history --peer user:1 [--limit N] [--offset-id N]
  receipts [--limit N]        per dialog: read_outbox_max_id and whether the newest own message is at or before it (no names or text)
  members --peer channel:1 [--limit N]   a group's members: channels.getParticipants (supergroups) or messages.getFullChat (basic groups)
  send --peer user:1 --text "hi" [--reply-to N]
  read --peer user:1 --max-id N
  listen [--seconds N]        print updates pushed on the connection
  download --peer K --msg-id N [--size x] -o FILE   a message's photo or document (a size type, or "full")
  webpage-preview --url U [--download-dir D]   messages.getWebPagePreview: a link preview's type, has_large_media
                              and media (its document, or its Instant View page's photos and videos in page order,
                              or its photo), downloading each at the size the app shows with --download-dir
  avatar --peer K -o FILE [--big]   a user's or chat's profile photo (small, or big with --big)
  chat-info --peer K          a group's full info: title, about, member count, and whether you may edit it
  edit-chat --peer K [--title T] [--about A]   rename a group or replace its description (only in a group you
                              named for testing)
  send-photo --peer K --file F [--caption T]   upload.saveFilePart + messages.sendMedia
  forward --from-peer K --ids N [N …] --to-peer K [--drop-author]   messages.forwardMessages: a native forward,
                              printed with the new messages' ids, media and fwd_from header fields (no text); only
                              to self (Saved Messages) or a chat the user named for testing
  forwards [--dialogs N] [--limit N]   which messageFwdHeader fields received forwards carry, per kind of origin
                              (user, hidden user, channel post), across recent dialogs; no names or text
  send-voice --peer K --file F.ogg --duration S [--levels 0,31,...]   a voice message: an Ogg Opus document with
                              documentAttributeAudio (voice, duration, 5-bit waveform); only to self (Saved Messages)
                              or a chat the user named for testing
  react --peer K --msg-id N [--emoji E]        messages.sendReaction; no emoji removes yours
  buttons --peer K [--limit N]  the inline keyboards (replyInlineMarkup) in a chat's history: each button's
                              constructor, label and data or URL, without message text
  press --peer K --msg-id N --row R --column C   press a callback button: messages.getBotCallbackAnswer with its
                              data, then the bot's answer (toast, alert or URL); only buttons with no side effects
                              beyond the chat (such as Refresh) in a chat the user named for testing
  reactions --peer K          the emoji the account may react with there: messages.getAvailableReactions (active,
                              and not premium unless the account is), narrowed by the chat's available_reactions
  raw --method name --json '{...}'   any method, with peers like {"_": "inputPeerSelf"}
"""

import argparse
import getpass
import hashlib
import json
import os
import pathlib
import secrets
import socket
import struct
import sys
import time
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "Sources/StupidSocialCore/Resources/TelegramSchema.tl"
SESSION_PATH = ROOT / "logs/telegram-session.json"

DC_ADDRESSES = {
    1: "149.154.175.53",
    2: "149.154.167.51",
    3: "149.154.175.100",
    4: "149.154.167.91",
    5: "91.108.56.130",
}
PORT = 443

# Telegram's production RSA key (also in TDLib's PublicRsaKeySharedMain.cpp), as modulus and exponent.
RSA_PEM_BODY = (
    "MIIBCgKCAQEA6LszBcC1LGzyr992NzE0ieY+BSaOW622Aa9Bd4ZHLl+TuFQ4lo4g"
    "5nKaMBwK/BIb9xUfg0Q29/2mgIR6Zr9krM7HjuIcCzFvDtr+L0GQjae9H0pRB2OO"
    "62cECs5HKhT5DZ98K33vmWiLowc621dQuwKWSQKjWf50XYFw42h21P2KXUGyp2y/"
    "+aEyZ+uVgLLQbRA1dEjSDZ2iGRy12Mk5gpYc397aYp438fsJoHIgJ2lgMv5h7WY9"
    "t6N/byY9Nw9p21Og3AoXSL2q/2IJ1WRUhebgAdGVMlV1fkuOQoEzR7EdpqtQD9Cs"
    "5+bfo3Nhmcyvk5ftB0WkJ9z6bNZ7yxrP8wIDAQAB"
)

# The 2048-bit safe prime Telegram uses for DH, checked so a bad prime fails loudly.
KNOWN_DH_PRIME = int(
    "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f"
    "48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c37"
    "20fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f64"
    "2477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4"
    "a4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754"
    "fd17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4"
    "e418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f"
    "0d8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b",
    16,
)


# MARK: AES-256 and IGE


def _build_aes_tables():
    def mul(a, b):
        result = 0
        while b:
            if b & 1:
                result ^= a
            a = ((a << 1) ^ 0x11B) if a & 0x80 else a << 1
            b >>= 1
        return result

    sbox = [0] * 256
    inv = [0] * 256
    for x in range(256):
        # Multiplicative inverse by brute force (256 * 256 is fine once at import).
        inverse = 0 if x == 0 else next(y for y in range(1, 256) if mul(x, y) == 1)
        s = inverse
        for shift in range(1, 5):
            s ^= ((inverse << shift) | (inverse >> (8 - shift))) & 0xFF
        sbox[x] = s ^ 0x63
        inv[sbox[x]] = x

    def ror(word, bits):
        return ((word >> bits) | (word << (32 - bits))) & 0xFFFFFFFF

    te0 = [(mul(s, 2) << 24) | (s << 16) | (s << 8) | mul(s, 3) for s in sbox]
    td0 = [(mul(s, 14) << 24) | (mul(s, 9) << 16) | (mul(s, 13) << 8) | mul(s, 11) for s in inv]
    te = [te0, [ror(w, 8) for w in te0], [ror(w, 16) for w in te0], [ror(w, 24) for w in te0]]
    td = [td0, [ror(w, 8) for w in td0], [ror(w, 16) for w in td0], [ror(w, 24) for w in td0]]
    return sbox, inv, te, td


SBOX, INV_SBOX, TE, TD = _build_aes_tables()


class AES:
    def __init__(self, key: bytes):
        assert len(key) in (16, 32)
        nk = len(key) // 4
        self.rounds = nk + 6
        words = list(struct.unpack(f">{nk}I", key))
        rcon = 1
        for i in range(nk, 4 * (self.rounds + 1)):
            temp = words[i - 1]
            if i % nk == 0:
                temp = ((temp << 8) | (temp >> 24)) & 0xFFFFFFFF
                temp = self._sub_word(temp) ^ (rcon << 24)
                rcon = ((rcon << 1) ^ 0x11B) if rcon & 0x80 else rcon << 1
            elif nk == 8 and i % 8 == 4:
                temp = self._sub_word(temp)
            words.append(words[i - nk] ^ temp)
        self.ek = words
        dk = []
        for r in range(self.rounds, -1, -1):
            round_key = words[4 * r : 4 * r + 4]
            if 0 < r < self.rounds:
                round_key = [
                    TD[0][SBOX[w >> 24]] ^ TD[1][SBOX[(w >> 16) & 255]] ^ TD[2][SBOX[(w >> 8) & 255]] ^ TD[3][SBOX[w & 255]]
                    for w in round_key
                ]
            dk += round_key
        self.dk = dk

    @staticmethod
    def _sub_word(w):
        return (SBOX[w >> 24] << 24) | (SBOX[(w >> 16) & 255] << 16) | (SBOX[(w >> 8) & 255] << 8) | SBOX[w & 255]

    def encrypt_block(self, block: bytes) -> bytes:
        k = self.ek
        f = 4 * self.rounds
        t0, t1, t2, t3 = TE
        s0, s1, s2, s3 = struct.unpack(">4I", block)
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        for r in range(1, self.rounds):
            i = 4 * r
            s0, s1, s2, s3 = (
                t0[s0 >> 24] ^ t1[(s1 >> 16) & 255] ^ t2[(s2 >> 8) & 255] ^ t3[s3 & 255] ^ k[i],
                t0[s1 >> 24] ^ t1[(s2 >> 16) & 255] ^ t2[(s3 >> 8) & 255] ^ t3[s0 & 255] ^ k[i + 1],
                t0[s2 >> 24] ^ t1[(s3 >> 16) & 255] ^ t2[(s0 >> 8) & 255] ^ t3[s1 & 255] ^ k[i + 2],
                t0[s3 >> 24] ^ t1[(s0 >> 16) & 255] ^ t2[(s1 >> 8) & 255] ^ t3[s2 & 255] ^ k[i + 3],
            )
        S = SBOX
        return struct.pack(
            ">4I",
            ((S[s0 >> 24] << 24) | (S[(s1 >> 16) & 255] << 16) | (S[(s2 >> 8) & 255] << 8) | S[s3 & 255]) ^ k[f],
            ((S[s1 >> 24] << 24) | (S[(s2 >> 16) & 255] << 16) | (S[(s3 >> 8) & 255] << 8) | S[s0 & 255]) ^ k[f + 1],
            ((S[s2 >> 24] << 24) | (S[(s3 >> 16) & 255] << 16) | (S[(s0 >> 8) & 255] << 8) | S[s1 & 255]) ^ k[f + 2],
            ((S[s3 >> 24] << 24) | (S[(s0 >> 16) & 255] << 16) | (S[(s1 >> 8) & 255] << 8) | S[s2 & 255]) ^ k[f + 3],
        )

    def decrypt_block(self, block: bytes) -> bytes:
        k = self.dk
        f = 4 * self.rounds
        t0, t1, t2, t3 = TD
        s0, s1, s2, s3 = struct.unpack(">4I", block)
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        for r in range(1, self.rounds):
            i = 4 * r
            s0, s1, s2, s3 = (
                t0[s0 >> 24] ^ t1[(s3 >> 16) & 255] ^ t2[(s2 >> 8) & 255] ^ t3[s1 & 255] ^ k[i],
                t0[s1 >> 24] ^ t1[(s0 >> 16) & 255] ^ t2[(s3 >> 8) & 255] ^ t3[s2 & 255] ^ k[i + 1],
                t0[s2 >> 24] ^ t1[(s1 >> 16) & 255] ^ t2[(s0 >> 8) & 255] ^ t3[s3 & 255] ^ k[i + 2],
                t0[s3 >> 24] ^ t1[(s2 >> 16) & 255] ^ t2[(s1 >> 8) & 255] ^ t3[s0 & 255] ^ k[i + 3],
            )
        S = INV_SBOX
        return struct.pack(
            ">4I",
            ((S[s0 >> 24] << 24) | (S[(s3 >> 16) & 255] << 16) | (S[(s2 >> 8) & 255] << 8) | S[s1 & 255]) ^ k[f],
            ((S[s1 >> 24] << 24) | (S[(s0 >> 16) & 255] << 16) | (S[(s3 >> 8) & 255] << 8) | S[s2 & 255]) ^ k[f + 1],
            ((S[s2 >> 24] << 24) | (S[(s1 >> 16) & 255] << 16) | (S[(s0 >> 8) & 255] << 8) | S[s3 & 255]) ^ k[f + 2],
            ((S[s3 >> 24] << 24) | (S[(s2 >> 16) & 255] << 16) | (S[(s1 >> 8) & 255] << 8) | S[s0 & 255]) ^ k[f + 3],
        )


def _xor(a: bytes, b: bytes) -> bytes:
    return (int.from_bytes(a, "big") ^ int.from_bytes(b, "big")).to_bytes(len(a), "big")


def ige_encrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    assert len(data) % 16 == 0
    aes = AES(key)
    prev_cipher, prev_plain = iv[:16], iv[16:]
    out = bytearray()
    for i in range(0, len(data), 16):
        block = data[i : i + 16]
        cipher = _xor(aes.encrypt_block(_xor(block, prev_cipher)), prev_plain)
        out += cipher
        prev_cipher, prev_plain = cipher, block
    return bytes(out)


def ige_decrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    assert len(data) % 16 == 0
    aes = AES(key)
    prev_cipher, prev_plain = iv[:16], iv[16:]
    out = bytearray()
    for i in range(0, len(data), 16):
        block = data[i : i + 16]
        plain = _xor(aes.decrypt_block(_xor(block, prev_plain)), prev_cipher)
        out += plain
        prev_cipher, prev_plain = block, plain
    return bytes(out)


def self_test():
    aes = AES(bytes(range(32)))
    plain = bytes.fromhex("00112233445566778899aabbccddeeff")
    cipher = aes.encrypt_block(plain)
    assert cipher.hex() == "8ea2b7ca516745bfeafc49904b496089", cipher.hex()
    assert aes.decrypt_block(cipher) == plain
    data, key, iv = os.urandom(64), os.urandom(32), os.urandom(32)
    assert ige_decrypt(ige_encrypt(data, key, iv), key, iv) == data


# MARK: TL schema and codec


class Combinator:
    def __init__(self, name, cid, params, result, is_function):
        self.name, self.id, self.params, self.result, self.is_function = name, cid, params, result, is_function


class Schema:
    def __init__(self, path: pathlib.Path):
        self.by_id: dict[int, Combinator] = {}
        self.by_name: dict[str, Combinator] = {}
        self.layer = 0
        is_function = False
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if line.startswith("// LAYER"):
                self.layer = int(line.split()[2])
                continue
            if line == "---functions---":
                is_function = True
                continue
            if not line or line.startswith("//"):
                continue
            head, result = line.rstrip(";").split(" = ")
            parts = head.split(" ")
            name, cid = parts[0].split("#")
            params = [tuple(p.split(":", 1)) for p in parts[1:] if not p.startswith("{")]
            combinator = Combinator(name, int(cid, 16), params, result, is_function)
            self.by_id.setdefault(combinator.id, combinator)
            # Functions and the API's `message` win over same-named MTProto constructors when encoding by name.
            if name not in self.by_name or is_function or combinator.result == "Message" and name == "message":
                self.by_name[name] = combinator


SCHEMA = Schema(SCHEMA_PATH)
VECTOR_ID = 0x1CB5C415
GZIP_ID = 0x3072CFA1
BOOL_TRUE, BOOL_FALSE = 0x997275B5, 0xBC799737
MTPROTO_MESSAGE_ID = 0x5BB8E511
RPC_RESULT_ID = 0xF35C6D01
MSG_CONTAINER_ID = 0x73F1F8DC


def tl_bytes(data: bytes) -> bytes:
    if len(data) < 254:
        out = bytes([len(data)]) + data
    else:
        out = b"\xfe" + len(data).to_bytes(3, "little") + data
    return out + b"\x00" * (-len(out) % 4)


def encode(value, type_name: str) -> bytes:
    """Serializes `value` as TL `type_name`; objects are dicts with "_" naming the constructor or method."""
    if type_name == "int":
        return struct.pack("<I", value & 0xFFFFFFFF)
    if type_name == "long":
        return struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF)
    if type_name == "double":
        return struct.pack("<d", value)
    if type_name in ("int128", "int256"):
        assert len(value) == (16 if type_name == "int128" else 32)
        return value
    if type_name == "string":
        return tl_bytes(value.encode())
    if type_name == "bytes":
        return tl_bytes(value)
    if type_name == "Bool":
        return struct.pack("<I", BOOL_TRUE if value else BOOL_FALSE)
    if type_name.startswith("Vector<") or type_name.startswith("vector<"):
        inner = type_name[7:-1]
        head = struct.pack("<I", VECTOR_ID) if type_name[0] == "V" else b""
        return head + struct.pack("<I", len(value)) + b"".join(encode(item, inner) for item in value)
    if isinstance(value, (bytes, bytearray)):
        # Already serialized, such as the inner query of invokeWithLayer.
        return bytes(value)
    combinator = SCHEMA.by_name[value["_"]]
    bare = type_name.startswith("%") or (type_name[:1].islower() and "." not in type_name and type_name in SCHEMA.by_name)
    out = b"" if bare else struct.pack("<I", combinator.id)
    return out + encode_fields(value, combinator)


def encode_fields(value: dict, combinator: Combinator) -> bytes:
    out = b""
    for name, param_type in combinator.params:
        if param_type == "#":
            flags = 0
            for other, other_type in combinator.params:
                if other_type.startswith(f"{name}.") and "?" in other_type:
                    bit = int(other_type.split("?")[0].split(".")[1])
                    present = value.get(other)
                    if other_type.endswith("?true") and present or not other_type.endswith("?true") and present is not None:
                        flags |= 1 << bit
            out += struct.pack("<I", flags)
            continue
        if "?" in param_type:
            inner = param_type.split("?", 1)[1]
            present = value.get(name)
            if inner == "true" or present is None:
                continue
            out += encode(present, inner)
            continue
        if param_type == "!X":
            out += encode(value[name], "X")
            continue
        out += encode(value[name], param_type)
    return out


class Reader:
    def __init__(self, data: bytes):
        self.data, self.offset = data, 0

    def take(self, count: int) -> bytes:
        if self.offset + count > len(self.data):
            raise ValueError("TL data ended early")
        chunk = self.data[self.offset : self.offset + count]
        self.offset += count
        return chunk

    def uint(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def int(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def long(self) -> int:
        return struct.unpack("<q", self.take(8))[0]

    def bytes(self) -> bytes:
        first = self.take(1)[0]
        if first < 254:
            length, header = first, 1
        else:
            length, header = int.from_bytes(self.take(3), "little"), 4
        data = self.take(length)
        self.take(-(header + length) % 4)
        return data


def decode(reader: Reader, type_name: str):
    if type_name == "int":
        return reader.int()
    if type_name == "long":
        return reader.long()
    if type_name == "double":
        return struct.unpack("<d", reader.take(8))[0]
    if type_name == "int128":
        return reader.take(16)
    if type_name == "int256":
        return reader.take(32)
    if type_name == "string":
        return reader.bytes().decode("utf-8", "replace")
    if type_name == "bytes":
        return reader.bytes()
    if type_name.startswith("vector<"):
        return [decode(reader, type_name[7:-1]) for _ in range(reader.uint())]
    if type_name.startswith("%") or (type_name[:1].islower() and type_name in SCHEMA.by_name):
        return decode_fields(reader, SCHEMA.by_name[type_name.lstrip("%")])
    cid = reader.uint()
    if cid == GZIP_ID:
        return decode(Reader(zlib.decompress(reader.bytes(), 47)), type_name)
    if cid == VECTOR_ID:
        inner = type_name[7:-1] if type_name.startswith("Vector<") else "Object"
        return [decode(reader, inner) for _ in range(reader.uint())]
    if type_name.startswith("Vector<"):
        raise ValueError(f"Expected a vector, got {cid:08x}")
    if cid == BOOL_TRUE:
        return True
    if cid == BOOL_FALSE:
        return False
    combinator = SCHEMA.by_id.get(cid)
    if combinator is None:
        raise ValueError(f"Unknown constructor {cid:08x} for {type_name}")
    if cid == RPC_RESULT_ID:
        return {"_": "rpc_result", "req_msg_id": reader.long(), "result": reader}
    if cid == MSG_CONTAINER_ID:
        messages = []
        for _ in range(reader.uint()):
            msg_id, seqno, length = reader.long(), reader.int(), reader.int()
            body = Reader(reader.take(length))
            messages.append({"msg_id": msg_id, "seqno": seqno, "body": body})
        return {"_": "msg_container", "messages": messages}
    return decode_fields(reader, combinator)


def decode_fields(reader: Reader, combinator: Combinator) -> dict:
    value = {"_": combinator.name}
    flags: dict[str, int] = {}
    for name, param_type in combinator.params:
        if param_type == "#":
            flags[name] = reader.uint()
            continue
        if "?" in param_type:
            condition, inner = param_type.split("?", 1)
            field, bit = condition.split(".")
            if not flags[field] & (1 << int(bit)):
                continue
            value[name] = True if inner == "true" else decode(reader, inner)
            continue
        value[name] = decode(reader, param_type)
    return value


def method_result_type(method: dict) -> str:
    combinator = SCHEMA.by_name[method["_"]]
    if combinator.result == "X":
        return method_result_type(method["query"])
    return combinator.result


# MARK: Crypto helpers


def sha1(data: bytes) -> bytes:
    return hashlib.sha1(data).digest()


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def rsa_public_key():
    import base64

    der = base64.b64decode(RSA_PEM_BODY)
    reader = 0

    def read_tlv(data, offset):
        tag = data[offset]
        length = data[offset + 1]
        offset += 2
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[offset : offset + count], "big")
            offset += count
        return tag, data[offset : offset + length], offset + length

    _, sequence, _ = read_tlv(der, reader)
    _, modulus, after = read_tlv(sequence, 0)
    _, exponent, _ = read_tlv(sequence, after)
    n, e = int.from_bytes(modulus, "big"), int.from_bytes(exponent, "big")
    # Fingerprint: lower 64 bits of SHA1(n as TL bytes + e as TL bytes).
    fingerprint = struct.unpack("<q", sha1(tl_bytes(n.to_bytes((n.bit_length() + 7) // 8, "big")) + tl_bytes(e.to_bytes((e.bit_length() + 7) // 8, "big")))[-8:])[0]
    return n, e, fingerprint


def factorize(pq: int) -> tuple[int, int]:
    """Pollard–Brent rho; pq is a 64-bit product of two primes."""
    import math
    import random

    if pq % 2 == 0:
        return 2, pq // 2
    while True:
        y, c, m = random.randrange(1, pq), random.randrange(1, pq), 128
        g, r, q = 1, 1, 1
        x = ys = 0
        while g == 1:
            x = y
            for _ in range(r):
                y = (y * y + c) % pq
            k = 0
            while k < r and g == 1:
                ys = y
                for _ in range(min(m, r - k)):
                    y = (y * y + c) % pq
                    q = q * abs(x - y) % pq
                g = math.gcd(q, pq)
                k += m
            r *= 2
        if g == pq:
            while True:
                ys = (ys * ys + c) % pq
                g = math.gcd(abs(x - ys), pq)
                if g > 1:
                    break
        if g != pq:
            p, q = sorted((g, pq // g))
            return p, q


def int_bytes(value: int, length: int | None = None) -> bytes:
    length = length or (value.bit_length() + 7) // 8
    return value.to_bytes(length, "big")


# MARK: Connection


class TransportError(Exception):
    pass


class RpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(f"{code} {message}")
        self.code, self.message = code, message


class Connection:
    """One TCP connection to a DC, carrying either the plain handshake or one encrypted session."""

    def __init__(self, dc: int):
        self.dc = dc
        self.sock = socket.create_connection((DC_ADDRESSES[dc], PORT), timeout=20)
        self.sock.sendall(b"\xee\xee\xee\xee")
        self.time_offset = 0
        self.last_msg_id = 0

    def send_packet(self, payload: bytes):
        self.sock.sendall(struct.pack("<I", len(payload)) + payload)

    def recv_exact(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise TransportError("Connection closed")
            data += chunk
        return data

    def recv_packet(self) -> bytes:
        length = struct.unpack("<I", self.recv_exact(4))[0]
        payload = self.recv_exact(length)
        if length == 4:
            raise TransportError(f"Transport error {struct.unpack('<i', payload)[0]}")
        return payload

    def new_msg_id(self) -> int:
        now = time.time() + self.time_offset
        msg_id = (int(now) << 32) | (int((now % 1) * 2**32) & ~3)
        if msg_id <= self.last_msg_id:
            msg_id = self.last_msg_id + 4
        self.last_msg_id = msg_id
        return msg_id

    # Plain messages, for creating the auth key.

    def plain_call(self, method: dict):
        body = encode(method, "X")
        self.send_packet(struct.pack("<qqI", 0, self.new_msg_id(), len(body)) + body)
        packet = self.recv_packet()
        reader = Reader(packet)
        auth_key_id, _msg_id, length = reader.long(), reader.long(), reader.uint()
        assert auth_key_id == 0
        return decode(Reader(reader.take(length)), method_result_type(method))

    def create_auth_key(self) -> tuple[bytes, int]:
        n, e, fingerprint = rsa_public_key()
        nonce = os.urandom(16)
        res_pq = self.plain_call({"_": "req_pq_multi", "nonce": nonce})
        assert res_pq["nonce"] == nonce
        if fingerprint not in res_pq["server_public_key_fingerprints"]:
            raise SystemExit(f"Server fingerprints {res_pq['server_public_key_fingerprints']} don't include ours ({fingerprint})")
        server_nonce = res_pq["server_nonce"]
        pq = int.from_bytes(res_pq["pq"], "big")
        p, q = factorize(pq)
        new_nonce = os.urandom(32)
        inner = encode(
            {"_": "p_q_inner_data_dc", "pq": res_pq["pq"], "p": int_bytes(p), "q": int_bytes(q), "nonce": nonce, "server_nonce": server_nonce, "new_nonce": new_nonce, "dc": self.dc},
            "P_Q_inner_data",
        )
        # RSA_PAD: data padded to 192 bytes, reversed, hashed with a temp key, IGE-encrypted, then RSA.
        padded = inner + os.urandom(192 - len(inner))
        while True:
            temp_key = os.urandom(32)
            data_with_hash = padded[::-1] + sha256(temp_key + padded)
            aes_encrypted = ige_encrypt(data_with_hash, temp_key, bytes(32))
            key_aes_encrypted = _xor(temp_key, sha256(aes_encrypted)) + aes_encrypted
            if int.from_bytes(key_aes_encrypted, "big") < n:
                break
        encrypted = int_bytes(pow(int.from_bytes(key_aes_encrypted, "big"), e, n), 256)
        dh_params = self.plain_call(
            {"_": "req_DH_params", "nonce": nonce, "server_nonce": server_nonce, "p": int_bytes(p), "q": int_bytes(q), "public_key_fingerprint": fingerprint, "encrypted_data": encrypted}
        )
        if dh_params["_"] != "server_DH_params_ok":
            raise SystemExit(f"DH params failed: {dh_params['_']}")
        tmp_key = sha1(new_nonce + server_nonce) + sha1(server_nonce + new_nonce)[:12]
        tmp_iv = sha1(server_nonce + new_nonce)[12:] + sha1(new_nonce + new_nonce) + new_nonce[:4]
        answer_with_hash = ige_decrypt(dh_params["encrypted_answer"], tmp_key, tmp_iv)
        answer_reader = Reader(answer_with_hash[20:])
        answer = decode(answer_reader, "Server_DH_inner_data")
        if sha1(answer_with_hash[20 : 20 + answer_reader.offset]) != answer_with_hash[:20]:
            raise SystemExit("DH answer hash mismatch")
        assert answer["nonce"] == nonce and answer["server_nonce"] == server_nonce
        dh_prime = int.from_bytes(answer["dh_prime"], "big")
        if dh_prime != KNOWN_DH_PRIME:
            raise SystemExit("Unexpected DH prime")
        g, g_a = answer["g"], int.from_bytes(answer["g_a"], "big")
        if not (1 < g_a < dh_prime - 1 and 2**1984 < g_a < dh_prime - 2**1984):
            raise SystemExit("g_a out of range")
        self.time_offset = answer["server_time"] - time.time()
        b = int.from_bytes(os.urandom(256), "big")
        g_b = pow(g, b, dh_prime)
        client_inner = encode({"_": "client_DH_inner_data", "nonce": nonce, "server_nonce": server_nonce, "retry_id": 0, "g_b": int_bytes(g_b)}, "Client_DH_Inner_Data")
        data = sha1(client_inner) + client_inner
        data += os.urandom(-len(data) % 16)
        result = self.plain_call({"_": "set_client_DH_params", "nonce": nonce, "server_nonce": server_nonce, "encrypted_data": ige_encrypt(data, tmp_key, tmp_iv)})
        auth_key = int_bytes(pow(g_a, b, dh_prime), 256)
        if result["_"] != "dh_gen_ok":
            raise SystemExit(f"DH generation failed: {result['_']}")
        aux_hash = sha1(auth_key)[:8]
        if sha1(new_nonce + b"\x01" + aux_hash)[4:] != result["new_nonce_hash1"]:
            raise SystemExit("new_nonce_hash1 mismatch")
        salt = struct.unpack("<q", _xor(new_nonce[:8], server_nonce[:8]))[0]
        return auth_key, salt


class Session:
    """An encrypted MTProto session on one DC, with RPC calls, service messages and pushed updates."""

    def __init__(self, store: "Store", dc: int):
        self.store, self.dc = store, dc
        self.conn = Connection(dc)
        saved = store.data["keys"].get(str(dc))
        if saved is None:
            auth_key, salt = self.conn.create_auth_key()
            saved = {"auth_key": auth_key.hex(), "salt": salt, "time_offset": self.conn.time_offset}
            store.data["keys"][str(dc)] = saved
            store.save()
        self.conn.time_offset = saved.get("time_offset", 0)
        self.auth_key = bytes.fromhex(saved["auth_key"])
        self.auth_key_id = sha1(self.auth_key)[-8:]
        self.salt = saved["salt"]
        self.session_id = os.urandom(8)
        self.seq = 0
        self.pending_acks: list[int] = []
        self.initialized = False
        self.updates: list[dict] = []

    def _encrypt(self, msg_id: int, seqno: int, body: bytes) -> bytes:
        plain = struct.pack("<q", self.salt) + self.session_id + struct.pack("<qiI", msg_id, seqno, len(body)) + body
        plain += os.urandom(12 + (-(len(plain) + 12) % 16))
        msg_key = sha256(self.auth_key[88 : 88 + 32] + plain)[8:24]
        key, iv = self._keys(msg_key, 0)
        return self.auth_key_id + msg_key + ige_encrypt(plain, key, iv)

    def _keys(self, msg_key: bytes, x: int) -> tuple[bytes, bytes]:
        a = sha256(msg_key + self.auth_key[x : x + 36])
        b = sha256(self.auth_key[40 + x : 40 + x + 36] + msg_key)
        return a[:8] + b[8:24] + a[24:32], b[:8] + a[8:24] + b[24:32]

    def _decrypt(self, packet: bytes) -> tuple[int, int, bytes]:
        if packet[:8] != self.auth_key_id:
            raise TransportError("auth_key_id mismatch")
        msg_key = packet[8:24]
        key, iv = self._keys(msg_key, 8)
        plain = ige_decrypt(packet[24:], key, iv)
        if sha256(self.auth_key[96 : 96 + 32] + plain)[8:24] != msg_key:
            raise TransportError("msg_key mismatch")
        if plain[8:16] != self.session_id:
            raise TransportError("session_id mismatch")
        msg_id, seqno, length = struct.unpack("<qiI", plain[16:32])
        return msg_id, seqno, plain[32 : 32 + length]

    def _send(self, body: bytes, content_related: bool) -> int:
        msg_id = self.conn.new_msg_id()
        seqno = self.seq * 2 + 1 if content_related else self.seq * 2
        if content_related:
            self.seq += 1
        self.conn.send_packet(self._encrypt(msg_id, seqno, body))
        return msg_id

    def _flush_acks(self):
        if self.pending_acks:
            acks, self.pending_acks = self.pending_acks, []
            self._send(encode({"_": "msgs_ack", "msg_ids": acks}, "MsgsAck"), False)

    def call(self, method: dict):
        if not self.initialized:
            api_id, _ = api_credentials()
            method = {
                "_": "invokeWithLayer",
                "layer": SCHEMA.layer,
                "query": {
                    "_": "initConnection",
                    "api_id": api_id,
                    "device_model": "No Feed Social probe",
                    "system_version": sys.platform,
                    "app_version": "1.0",
                    "system_lang_code": "en",
                    "lang_pack": "",
                    "lang_code": "en",
                    "query": method,
                },
            }
            self.initialized = True
        result_type = method_result_type(method)
        body = encode(method, "X")
        msg_id = self._send(body, True)
        while True:
            outcome = self._receive(msg_id, result_type)
            if outcome is None:
                continue
            kind, value = outcome
            if kind == "resend":
                msg_id = self._send(body, True)
                continue
            self._flush_acks()
            if kind == "error":
                raise RpcError(value["error_code"], value["error_message"])
            return value

    def _receive(self, waiting_id: int | None, result_type: str | None):
        msg_id, seqno, body = self._decrypt(self.conn.recv_packet())
        return self._handle(msg_id, seqno, Reader(body), waiting_id, result_type)

    def _handle(self, msg_id: int, seqno: int, reader: Reader, waiting_id, result_type):
        if seqno & 1:
            self.pending_acks.append(msg_id)
        value = decode(reader, "Object")
        kind = value["_"]
        if kind == "msg_container":
            found = None
            for inner in value["messages"]:
                outcome = self._handle(inner["msg_id"], inner["seqno"], inner["body"], waiting_id, result_type)
                found = found or outcome
            return found
        if kind == "rpc_result":
            result_reader: Reader = value["result"]
            if value["req_msg_id"] != waiting_id:
                return None
            peek = struct.unpack("<I", result_reader.data[result_reader.offset : result_reader.offset + 4])[0]
            if peek == SCHEMA.by_name["rpc_error"].id:
                return ("error", decode(result_reader, "RpcError"))
            return ("ok", decode(result_reader, result_type))
        if kind == "bad_server_salt":
            self.salt = value["new_server_salt"]
            self.store.data["keys"][str(self.dc)]["salt"] = self.salt
            self.store.save()
            return ("resend", None) if value["bad_msg_id"] == waiting_id else None
        if kind == "bad_msg_notification":
            if value["error_code"] in (16, 17):
                self.conn.time_offset = (msg_id >> 32) - time.time()
                self.store.data["keys"][str(self.dc)]["time_offset"] = self.conn.time_offset
                self.store.save()
                return ("resend", None) if value["bad_msg_id"] == waiting_id else None
            raise TransportError(f"bad_msg_notification {value['error_code']}")
        if kind == "new_session_created":
            self.salt = value["server_salt"]
            return None
        if kind.startswith("update") or kind == "updatesTooLong":
            self.updates.append(value)
            return None
        return None

    def listen(self, seconds: float, typing_only: bool = False):
        self.conn.sock.settimeout(1)
        deadline = time.time() + seconds
        last_ping = 0.0
        while time.time() < deadline:
            if time.time() - last_ping > 30:
                self._send(encode({"_": "ping", "ping_id": secrets.randbits(63)}, "X"), True)
                last_ping = time.time()
            try:
                self._receive(None, None)
            except (socket.timeout, TimeoutError):
                pass
            self._flush_acks()
            while self.updates:
                update = self.updates.pop(0)
                if typing_only:
                    for typing in typing_updates(update):
                        print(json.dumps(to_json(typing), ensure_ascii=False))
                else:
                    print(json.dumps(to_json(update), ensure_ascii=False))


TYPING_UPDATES = {"updateUserTyping", "updateChatUserTyping", "updateChannelUserTyping"}


def typing_updates(update: dict) -> list[dict]:
    """Typing updates in a pushed update, which come alone in updateShort or among others in updates."""
    if update["_"] == "updateShort":
        return typing_updates(update["update"])
    if update["_"] in ("updates", "updatesCombined"):
        return [u for u in update["updates"] if u["_"] in TYPING_UPDATES]
    return [update] if update["_"] in TYPING_UPDATES else []


# MARK: Session storage and credentials


class Store:
    def __init__(self):
        SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
        self.data = json.loads(SESSION_PATH.read_text()) if SESSION_PATH.exists() else {"dc": 2, "keys": {}, "peers": {}}

    def save(self):
        SESSION_PATH.write_text(json.dumps(self.data, indent=2))
        os.chmod(SESSION_PATH, 0o600)


def local_env() -> dict[str, str]:
    """The environment, with .env.local filling in what it doesn't set."""
    env = dict(os.environ)
    local = ROOT / ".env.local"
    if local.exists():
        for line in local.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                env.setdefault(key.strip(), value.strip().strip("'\""))
    return env


def api_credentials() -> tuple[int, str]:
    env = local_env()
    if "TELEGRAM_APP_ID" not in env or "TELEGRAM_APP_API_HASH" not in env:
        raise SystemExit("Set TELEGRAM_APP_ID and TELEGRAM_APP_API_HASH (from https://my.telegram.org) in the environment or .env.local")
    return int(env["TELEGRAM_APP_ID"]), env["TELEGRAM_APP_API_HASH"]


def to_json(value):
    if isinstance(value, dict):
        return {k: to_json(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_json(v) for v in value]
    if isinstance(value, (bytes, bytearray)):
        return {"bytes": value.hex()} if len(value) <= 64 else {"bytes": f"<{len(value)} bytes>"}
    return value


class Client:
    """The account's session on its home DC, following *_MIGRATE_X errors to another DC."""

    def __init__(self):
        self.store = Store()
        self.session = Session(self.store, self.store.data["dc"])

    def call(self, method: dict):
        try:
            return self.session.call(method)
        except RpcError as error:
            if error.code == 303 and "_MIGRATE_" in error.message:
                dc = int(error.message.rsplit("_", 1)[1])
                print(f"Migrating to DC {dc}", file=sys.stderr)
                self.store.data["dc"] = dc
                self.store.save()
                self.session = Session(self.store, dc)
                return self.session.call(method)
            raise

    def dc_session(self, dc: int) -> "Session":
        """A session on another DC for files, signed in by exporting the home DC's authorization."""
        if dc == self.session.dc:
            return self.session
        sessions = self.__dict__.setdefault("dc_sessions", {})
        if dc not in sessions:
            session = Session(self.store, dc)
            authorized = self.store.data.setdefault("authorized_dcs", [])
            if dc not in authorized:
                exported = self.call({"_": "auth.exportAuthorization", "dc_id": dc})
                session.call({"_": "auth.importAuthorization", "id": exported["id"], "bytes": exported["bytes"]})
                authorized.append(dc)
                self.store.save()
            sessions[dc] = session
        return sessions[dc]

    def download(self, location: dict, dc: int) -> bytes:
        """upload.getFile in 512 KB parts until a short part."""
        session = self.dc_session(dc)
        limit = 512 * 1024
        data = b""
        while True:
            part = session.call({"_": "upload.getFile", "precise": True, "location": location, "offset": len(data), "limit": limit})
            if part["_"] != "upload.file":
                raise SystemExit(f"Unsupported file reply {part['_']} (CDN)")
            data += part["bytes"]
            if len(part["bytes"]) < limit:
                return data

    def remember_peers(self, users: list, chats: list):
        peers = self.store.data["peers"]
        for user in users:
            if user["_"] == "user" and "access_hash" in user:
                peers[f"user:{user['id']}"] = user["access_hash"]
        for chat in chats:
            if chat["_"] == "chat":
                peers[f"chat:{chat['id']}"] = 0
            elif chat["_"] == "channel" and "access_hash" in chat:
                peers[f"channel:{chat['id']}"] = chat["access_hash"]
        self.store.save()

    def input_peer(self, key: str) -> dict:
        if key == "self":
            return {"_": "inputPeerSelf"}
        kind, peer_id = key.split(":")
        access_hash = self.store.data["peers"].get(key)
        if kind == "chat":
            return {"_": "inputPeerChat", "chat_id": int(peer_id)}
        if access_hash is None:
            raise SystemExit(f"No access hash for {key}; run dialogs first")
        if kind == "user":
            return {"_": "inputPeerUser", "user_id": int(peer_id), "access_hash": access_hash}
        return {"_": "inputPeerChannel", "channel_id": int(peer_id), "access_hash": access_hash}


# MARK: SRP (2FA password)


def srp_check(password: str, salt1: bytes, salt2: bytes, g: int, p_bytes: bytes, srp_b: bytes, secret: bytes | None = None) -> tuple[bytes, bytes]:
    """The A and M1 of inputCheckPasswordSRP; `secret` fixes the random exponent, for test vectors."""
    p = int.from_bytes(p_bytes, "big")
    if p != KNOWN_DH_PRIME:
        raise SystemExit("Unexpected SRP prime")

    def sh(data, salt):
        return sha256(salt + data + salt)

    ph1 = sh(sh(password.encode(), salt1), salt2)
    ph2 = sh(hashlib.pbkdf2_hmac("sha512", ph1, salt1, 100000), salt2)
    x = int.from_bytes(ph2, "big")
    g_padded = int_bytes(g, 256)
    p_padded = int_bytes(p, 256)
    g_b = int.from_bytes(srp_b, "big")
    g_b_padded = int_bytes(g_b, 256)
    k = int.from_bytes(sha256(p_padded + g_padded), "big")
    v = pow(g, x, p)
    while True:
        a = int.from_bytes(secret or os.urandom(256), "big")
        g_a_padded = int_bytes(pow(g, a, p), 256)
        u = int.from_bytes(sha256(g_a_padded + g_b_padded), "big")
        if u > 0:
            break
    t = (g_b - k * v) % p
    s_a = pow(t, a + u * x, p)
    k_a = sha256(int_bytes(s_a, 256))
    m1 = sha256(_xor(sha256(p_padded), sha256(g_padded)) + sha256(salt1) + sha256(salt2) + g_a_padded + g_b_padded + k_a)
    return g_a_padded, m1


def check_password(client: Client, password: str) -> dict:
    info = client.call({"_": "account.getPassword"})
    algo = info.get("current_algo")
    if not algo or algo["_"] != "passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow":
        raise SystemExit(f"Unsupported password algorithm {algo and algo['_']}")
    g_a, m1 = srp_check(password, algo["salt1"], algo["salt2"], algo["g"], algo["p"], info["srp_B"])
    return client.call({"_": "auth.checkPassword", "password": {"_": "inputCheckPasswordSRP", "srp_id": info["srp_id"], "A": g_a, "M1": m1}})


# MARK: Web Push (RFC 8291) for Telegram's token_type 10

# Telegram's VAPID public key, from Telegram Web (tweb src/config/app.ts `pushServerKey`).
TELEGRAM_VAPID_KEY = "BHEbKOXt-GD8MCTTYiAYT3I5R4MB0epIE7Tbbymj1uR0xJRE_7m27eXTVAC_P19TeZnO9413lRz-0oZ87JRPKPM"

P256_P = 2**256 - 2**224 + 2**192 + 2**96 - 1
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
P256_G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)


def p256_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P256_P == 0:
        return None
    if a == b:
        slope = (3 * a[0] * a[0] - 3) * pow(2 * a[1], P256_P - 2, P256_P) % P256_P
    else:
        slope = (b[1] - a[1]) * pow(b[0] - a[0], P256_P - 2, P256_P) % P256_P
    x = (slope * slope - a[0] - b[0]) % P256_P
    return x, (slope * (a[0] - x) - a[1]) % P256_P


def p256_mul(k: int, point):
    result = None
    while k:
        if k & 1:
            result = p256_add(result, point)
        point = p256_add(point, point)
        k >>= 1
    return result


def p256_point(data: bytes):
    assert len(data) == 65 and data[0] == 4
    x, y = int.from_bytes(data[1:33], "big"), int.from_bytes(data[33:], "big")
    assert (y * y - (x * x * x - 3 * x + P256_B)) % P256_P == 0, "not on P-256"
    return x, y


def p256_bytes(point) -> bytes:
    return b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")


def b64url(data: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text: str) -> bytes:
    import base64

    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    import hmac

    return hmac.new(key, data, hashlib.sha256).digest()


def gcm_decrypt(key: bytes, nonce: bytes, data: bytes) -> bytes:
    """AES-GCM with a 96-bit nonce; checks the tag."""
    aes = AES(key)
    ciphertext, tag = data[:-16], data[-16:]
    h = int.from_bytes(aes.encrypt_block(bytes(16)), "big")

    def gf_mul(x: int, y: int) -> int:
        z, v = 0, y
        for i in range(127, -1, -1):
            if (x >> i) & 1:
                z ^= v
            v = (v >> 1) ^ (0xE1 << 120) if v & 1 else v >> 1
        return z

    ghash = 0
    padded = ciphertext + bytes(-len(ciphertext) % 16)
    for i in range(0, len(padded), 16):
        ghash = gf_mul(ghash ^ int.from_bytes(padded[i : i + 16], "big"), h)
    ghash = gf_mul(ghash ^ (len(ciphertext) * 8), h)
    expected = _xor(aes.encrypt_block(nonce + b"\x00\x00\x00\x01"), ghash.to_bytes(16, "big"))
    if expected != tag:
        raise SystemExit("GCM tag mismatch")
    plain = bytearray()
    for index, start in enumerate(range(0, len(ciphertext), 16)):
        stream = aes.encrypt_block(nonce + (index + 2).to_bytes(4, "big"))
        block = ciphertext[start : start + 16]
        plain += _xor(block, stream[: len(block)])
    return bytes(plain)


def webpush_decrypt(body: bytes, private_key: int, auth: bytes) -> bytes:
    """RFC 8291 `aes128gcm`: salt, record size, the sender's key, then one record."""
    salt, record_size, key_length = body[:16], int.from_bytes(body[16:20], "big"), body[20]
    sender = body[21 : 21 + key_length]
    ciphertext = body[21 + key_length :]
    assert len(ciphertext) <= record_size
    receiver = p256_bytes(p256_mul(private_key, P256_G))
    shared = p256_mul(private_key, p256_point(sender))[0].to_bytes(32, "big")
    ikm = hmac_sha256(hmac_sha256(auth, shared), b"WebPush: info\x00" + receiver + sender + b"\x01")
    prk = hmac_sha256(salt, ikm)
    cek = hmac_sha256(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = hmac_sha256(prk, b"Content-Encoding: nonce\x00\x01")[:12]
    padded = gcm_decrypt(cek, nonce, ciphertext).rstrip(b"\x00")
    assert padded.endswith(b"\x02"), "missing last-record delimiter"
    return padded[:-1]


def webpush_token(store: "Store", endpoint: str) -> str:
    """The token_type 10 token: the endpoint and this probe's P-256 key and auth secret (kept in the session)."""
    push = store.data.setdefault("webpush", {})
    if "private_key" not in push:
        push["private_key"] = int.from_bytes(os.urandom(32), "big") % (P256_N - 1) + 1
        push["auth"] = os.urandom(16).hex()
        store.save()
    public = p256_bytes(p256_mul(push["private_key"], P256_G))
    return json.dumps({"endpoint": endpoint, "keys": {"p256dh": b64url(public), "auth": b64url(bytes.fromhex(push["auth"]))}, "vapid": True}, separators=(",", ":"))


# MARK: Commands


def peer_key(peer: dict) -> str:
    if peer["_"] == "peerUser":
        return f"user:{peer['user_id']}"
    if peer["_"] == "peerChat":
        return f"chat:{peer['chat_id']}"
    return f"channel:{peer['channel_id']}"


def name_of(users: dict, chats: dict, key: str) -> str:
    kind, peer_id = key.split(":")
    if kind == "user":
        user = users.get(int(peer_id), {})
        return " ".join(filter(None, [user.get("first_name"), user.get("last_name")])) or user.get("username") or key
    return chats.get(int(peer_id), {}).get("title", key)


def message_line(message: dict, users: dict, chats: dict) -> str:
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(message.get("date", 0)))
    sender = "You" if message.get("out") else name_of(users, chats, peer_key(message["from_id"])) if "from_id" in message else name_of(users, chats, peer_key(message["peer_id"]))
    text = message.get("message") or (message.get("media", {}).get("_") if message.get("media") else message.get("action", {}).get("_", ""))
    reply = f" ↩{message['reply_to'].get('reply_to_msg_id')}" if message.get("reply_to") else ""
    return f"{message['id']:>8} {when} {sender}{reply}: {text}"


def fwd_header_shape(header: dict | None) -> dict | None:
    """A messageFwdHeader with peers as their type and names as their presence, so nothing identifying prints."""
    if not header:
        return None
    shape = {}
    for key, value in header.items():
        if key in ("_", "flags"):
            continue
        if isinstance(value, dict):
            shape[key] = value.get("_")
        elif key in ("from_name", "post_author", "saved_from_name"):
            shape[key] = "<present>"
        else:
            shape[key] = value
    return shape


def sticker_set_documents(client: "Client", name: str, access_hash: int | None = None) -> list[dict]:
    """messages.getStickerSet by id (with its access hash, else looked up among installed sets) or short name."""
    if name.lstrip("-").isdigit():
        if access_hash is None:
            sets = client.call({"_": "messages.getAllStickers", "hash": 0}).get("sets", [])
            access_hash = next(s["access_hash"] for s in sets if s["id"] == int(name))
        stickerset = {"_": "inputStickerSetID", "id": int(name), "access_hash": access_hash}
    else:
        stickerset = {"_": "inputStickerSetShortName", "short_name": name}
    return client.call({"_": "messages.getStickerSet", "stickerset": stickerset, "hash": 0}).get("documents", [])


def sticker_line(doc: dict) -> str:
    attrs = {a["_"]: a for a in doc.get("attributes", [])}
    size = attrs.get("documentAttributeImageSize") or attrs.get("documentAttributeVideo") or {}
    alt = (attrs.get("documentAttributeSticker") or {}).get("alt")
    thumbs = [f"{t.get('type')}" for t in doc.get("thumbs") or []]
    return f"{doc['id']} {doc.get('mime_type')} {doc.get('size')}B {size.get('w')}x{size.get('h')} alt={alt!r} dc={doc.get('dc_id')} thumbs={thumbs}"


def sticker_formats(documents: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for doc in documents:
        counts[doc.get("mime_type")] = counts.get(doc.get("mime_type"), 0) + 1
    return counts


def pack_waveform(levels: list[int]) -> bytes:
    """5-bit levels packed least significant bit first, as documentAttributeAudio.waveform carries them."""
    packed = bytearray((len(levels) * 5 + 7) // 8)
    for index, level in enumerate(levels):
        bit = index * 5
        value = (min(max(level, 0), 31) << (bit % 8))
        packed[bit // 8] |= value & 0xFF
        if bit // 8 + 1 < len(packed):
            packed[bit // 8 + 1] |= value >> 8
    return bytes(packed)


def unpack_waveform(data: bytes) -> list[int]:
    return [((data[i * 5 // 8] | (data[i * 5 // 8 + 1] << 8 if i * 5 // 8 + 1 < len(data) else 0)) >> (i * 5 % 8)) & 31 for i in range(len(data) * 8 // 5)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    handshake = sub.add_parser("handshake")
    handshake.add_argument("--dc", type=int, default=2)
    sub.add_parser("config")
    send_code = sub.add_parser("send-code")
    send_code.add_argument("--phone", required=True)
    sign_in = sub.add_parser("sign-in")
    sign_in.add_argument("--code", required=True)
    sub.add_parser("password")
    sub.add_parser("me")
    dialogs = sub.add_parser("dialogs")
    dialogs.add_argument("--limit", type=int, default=20)
    dialogs.add_argument("--json", action="store_true")
    dialogs.add_argument("--archived", action="store_true", help="the Archive folder (folder_id 1)")
    receipts = sub.add_parser("receipts", help="per dialog: read_outbox_max_id and whether the newest own message was read (no names or text)")
    receipts.add_argument("--limit", type=int, default=20)
    sub.add_parser("notify-defaults", help="when private chats, groups and channels are muted until by default, which chats without their own mute_until follow")
    history = sub.add_parser("history")
    history.add_argument("--peer", required=True)
    history.add_argument("--limit", type=int, default=20)
    history.add_argument("--offset-id", type=int, default=0)
    history.add_argument("--json", action="store_true")
    send = sub.add_parser("send")
    send.add_argument("--peer", required=True)
    send.add_argument("--text", required=True)
    send.add_argument("--reply-to", type=int)
    send.add_argument("--mention-user", type=int, help="a user id to mention by name over --mention-range (inputMessageEntityMentionName)")
    send.add_argument("--mention-range", help="OFFSET:LENGTH of the name in --text, in UTF-16 units")
    edit = sub.add_parser("edit", help="messages.editMessage: replace the text (or caption) of one of your messages")
    edit.add_argument("--peer", required=True)
    edit.add_argument("--msg-id", type=int, required=True)
    edit.add_argument("--text", required=True)
    delete = sub.add_parser("delete", help="messages.deleteMessages (revoke) or channels.deleteMessages: delete your messages for everyone")
    delete.add_argument("--peer", required=True)
    delete.add_argument("--msg-id", type=int, action="append", required=True)
    resolve = sub.add_parser("resolve", help="contacts.resolveUsername: the user or chat an @username names")
    resolve.add_argument("--username", required=True)
    profile = sub.add_parser("profile", help="users.getFullUser: a user's profile, bio and status")
    profile.add_argument("--user", type=int, required=True, help="a user id whose access hash is known (from dialogs, history or resolve)")
    mentions = sub.add_parser("mentions", help="a chat's mention entities, without message text")
    mentions.add_argument("--peer", required=True)
    mentions.add_argument("--limit", type=int, default=100)
    read = sub.add_parser("read")
    read.add_argument("--peer", required=True)
    read.add_argument("--max-id", type=int, required=True)
    listen = sub.add_parser("listen")
    listen.add_argument("--seconds", type=float, default=60)
    listen.add_argument("--typing", action="store_true", help="print only typing updates (updateUserTyping, updateChatUserTyping, updateChannelUserTyping), without message text")
    typing = sub.add_parser("typing", help="messages.setTyping: show the account typing in a chat for about 6 s, or stop it")
    typing.add_argument("--peer", required=True)
    typing.add_argument("--cancel", action="store_true", help="sendMessageCancelAction instead of sendMessageTypingAction")
    download = sub.add_parser("download")
    download.add_argument("--peer", required=True)
    download.add_argument("--msg-id", type=int, required=True)
    download.add_argument("--size", default="x", help='photo or thumbnail size type such as m, x, y; "full" for a whole document')
    download.add_argument("-o", "--output", required=True)
    webpage_preview = sub.add_parser("webpage-preview", help="a link preview's media, as the chat's link previews show it")
    webpage_preview.add_argument("--url", required=True)
    webpage_preview.add_argument("--download-dir")
    avatar = sub.add_parser("avatar")
    avatar.add_argument("--big", action="store_true", help="the 640px photo instead of the 160px one")
    avatar.add_argument("--peer", required=True)
    avatar.add_argument("-o", "--output", required=True)
    send_photo = sub.add_parser("send-photo")
    send_photo.add_argument("--peer", required=True)
    send_photo.add_argument("--file", required=True)
    send_photo.add_argument("--caption", default="")
    forward = sub.add_parser("forward", help="messages.forwardMessages: forward messages natively")
    forward.add_argument("--from-peer", required=True)
    forward.add_argument("--ids", type=int, nargs="+", required=True)
    forward.add_argument("--to-peer", required=True)
    forward.add_argument("--drop-author", action="store_true")
    forwards = sub.add_parser("forwards", help="messageFwdHeader fields on received forwards, without names or text")
    forwards.add_argument("--dialogs", type=int, default=30)
    forwards.add_argument("--limit", type=int, default=100)
    send_voice = sub.add_parser("send-voice")
    send_voice.add_argument("--peer", required=True)
    send_voice.add_argument("--file", required=True)
    send_voice.add_argument("--duration", type=int, required=True)
    send_voice.add_argument("--levels", default="", help="comma-separated waveform levels from 0 to 31")
    push_register = sub.add_parser("push-register")
    push_register.add_argument("--endpoint", help="Web Push endpoint (token_type 10)")
    push_register.add_argument("--apns", help="APNs device token in hex (token_type 1)")
    push_register.add_argument("--sandbox", action="store_true")
    push_unregister = sub.add_parser("push-unregister")
    push_unregister.add_argument("--endpoint")
    push_unregister.add_argument("--apns")
    push_decrypt = sub.add_parser("push-decrypt")
    push_decrypt.add_argument("--file", required=True, help="a captured Web Push request body")
    react = sub.add_parser("react")
    react.add_argument("--peer", required=True)
    react.add_argument("--msg-id", type=int, required=True)
    react.add_argument("--emoji", default="", help="empty removes your reaction")
    buttons = sub.add_parser("buttons", help="a chat's inline keyboards, without message text")
    buttons.add_argument("--peer", required=True)
    buttons.add_argument("--limit", type=int, default=50)
    press = sub.add_parser("press", help="messages.getBotCallbackAnswer: press a message's callback button")
    press.add_argument("--peer", required=True)
    press.add_argument("--msg-id", type=int, required=True)
    press.add_argument("--row", type=int, default=0)
    press.add_argument("--column", type=int, default=0)
    reactions = sub.add_parser("reactions", help="the emoji the account may react with in a chat")
    reactions.add_argument("--peer", required=True)
    chat_info = sub.add_parser("chat-info", help="a group's full info and whether you may edit it")
    chat_info.add_argument("--peer", required=True)
    edit_chat = sub.add_parser("edit-chat", help="rename a group or replace its description")
    edit_chat.add_argument("--peer", required=True)
    edit_chat.add_argument("--title")
    edit_chat.add_argument("--about")
    members = sub.add_parser("members")
    members.add_argument("--peer", required=True)
    members.add_argument("--limit", type=int, default=200)
    members.add_argument("--json", action="store_true")
    mute = sub.add_parser("mute", help="account.updateNotifySettings: mute a chat for good (mute_until max int) or unmute it (0), then read it back")
    mute.add_argument("--peer", required=True)
    mute.add_argument("--off", action="store_true", help="unmute")
    archive = sub.add_parser("archive", help="folders.editPeerFolders: move a chat to the Archive (folder 1) or back to the main list (0)")
    archive.add_argument("--peer", required=True)
    archive.add_argument("--off", action="store_true", help="unarchive")
    peer_status = sub.add_parser("peer-status", help="a private chat's last-seen status, as messages.getPeerDialogs returns it")
    peer_status.add_argument("--peer", required=True)
    custom_emoji = sub.add_parser("custom-emoji", help="a chat's custom emoji (text entities and reactions) and their documents, without message text")
    custom_emoji.add_argument("--peer", required=True)
    custom_emoji.add_argument("--limit", type=int, default=100)
    custom_emoji.add_argument("-o", "--output", help="download the first emoji's image (the whole WebP, else its largest thumbnail) here")
    stickers = sub.add_parser("stickers", help="the account's recent and favourite stickers and installed sticker sets, by format")
    stickers.add_argument("--set", help="list one set's stickers instead: its id or short name")
    stickers_for = sub.add_parser("stickers-for", help="messages.getStickers: stickers for an emoji, from installed sets and Telegram's suggestions")
    stickers_for.add_argument("--emoji", required=True)
    sticker_corpus = sub.add_parser("sticker-corpus", help="download stickers (TGS, WebM, WebP) from sets into a directory, for renderer tests")
    sticker_corpus.add_argument("--set", action="append", default=[], help="a set's short name; repeatable. Default: every installed set, recent and favourite stickers")
    sticker_corpus.add_argument("--animated-emoji", action="store_true", help="also Telegram's animated emoji set")
    sticker_corpus.add_argument("--format", choices=["tgs", "webm", "webp", "all"], default="tgs")
    sticker_corpus.add_argument("-o", "--output", required=True)
    send_sticker = sub.add_parser("send-sticker", help="messages.sendMedia with inputMediaDocument: send a sticker by its document id")
    send_sticker.add_argument("--peer", required=True)
    send_sticker.add_argument("--document-id", type=int, help="a sticker from `stickers` (recent, favourite or an installed set); default: the most recent one")
    send_sticker.add_argument("--reply-to", type=int)
    raw = sub.add_parser("raw")
    raw.add_argument("--method", required=True)
    raw.add_argument("--json", default="{}")
    args = parser.parse_args()

    self_test()

    if args.command == "handshake":
        started = time.time()
        conn = Connection(args.dc)
        auth_key, salt = conn.create_auth_key()
        print(f"Auth key on DC {args.dc} in {time.time() - started:.1f}s: id {sha1(auth_key)[-8:].hex()}, time offset {conn.time_offset:.1f}s")
        return

    client = Client()
    if args.command == "config":
        config = client.call({"_": "help.getConfig"})
        print(json.dumps({"this_dc": config["this_dc"], "date": config["date"], "dc_options": [(o["id"], o["ip_address"], o["port"], [k for k in o if o[k] is True]) for o in config["dc_options"]]}, indent=1))
    elif args.command == "send-code":
        api_id, api_hash = api_credentials()
        sent = client.call({"_": "auth.sendCode", "phone_number": args.phone, "api_id": api_id, "api_hash": api_hash, "settings": {"_": "codeSettings"}})
        client.store.data["login"] = {"phone": args.phone, "phone_code_hash": sent["phone_code_hash"]}
        client.store.save()
        print(json.dumps(to_json({k: v for k, v in sent.items() if k != "phone_code_hash"}), indent=1))
    elif args.command == "sign-in":
        login = client.store.data["login"]
        try:
            result = client.call({"_": "auth.signIn", "phone_number": login["phone"], "phone_code_hash": login["phone_code_hash"], "phone_code": args.code})
        except RpcError as error:
            if error.message == "SESSION_PASSWORD_NEEDED":
                print("2FA password needed: run `password`")
                return
            raise
        print(result["_"], result.get("user", {}).get("id"))
    elif args.command == "password":
        password = local_env().get("TELEGRAM_USER_PASSWORD") or getpass.getpass("Telegram password: ")
        result = check_password(client, password)
        print(result["_"], result.get("user", {}).get("id"))
    elif args.command == "me":
        users = client.call({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]})
        me = users[0]
        print(json.dumps({k: to_json(me.get(k)) for k in ("id", "first_name", "last_name", "username", "photo")}, indent=1))
    elif args.command == "dialogs":
        method = {"_": "messages.getDialogs", "offset_date": 0, "offset_id": 0, "offset_peer": {"_": "inputPeerEmpty"}, "limit": args.limit, "hash": 0}
        if args.archived:
            method["folder_id"] = 1
        result = client.call(method)
        client.remember_peers(result["users"], result["chats"])
        if args.json:
            print(json.dumps(to_json(result), indent=1, ensure_ascii=False))
            return
        users = {u["id"]: u for u in result["users"]}
        chats = {c["id"]: c for c in result["chats"]}
        messages = {(peer_key(m["peer_id"]), m["id"]): m for m in result["messages"] if "peer_id" in m}
        defaults = {kind: client.call({"_": "account.getNotifySettings", "peer": {"_": peer}}).get("mute_until", 0) for kind, peer in (("user", "inputNotifyUsers"), ("group", "inputNotifyChats"), ("broadcast", "inputNotifyBroadcasts"))}
        print(f"{result['_']} count={result.get('count', len(result['dialogs']))}")
        for dialog in result["dialogs"]:
            if dialog["_"] == "dialogFolder":
                print(f"dialogFolder {dialog['folder']['title']!r} unmuted_peers={dialog['unread_unmuted_peers_count']} muted_peers={dialog['unread_muted_peers_count']}")
                continue
            key = peer_key(dialog["peer"])
            chat = chats.get(int(key.split(":")[1])) if not key.startswith("user") else None
            kind = "broadcast" if chat and chat.get("broadcast") else "group" if chat else "user"
            top = messages.get((key, dialog["top_message"]))
            muted = dialog["notify_settings"].get("mute_until", defaults[kind]) > time.time()
            print(f"{key:<24} {kind:<9} {'muted' if muted else '':<5} unread={dialog['unread_count']:<4} read_in={dialog['read_inbox_max_id']} read_out={dialog['read_outbox_max_id']}  {name_of(users, chats, key)}")
            if top:
                print("    " + message_line(top, users, chats))
    elif args.command == "receipts":
        # Someone else read the user's messages up to read_outbox_max_id: in a private chat the other person, in a
        # group anyone. Checked against the newest outgoing message among the dialog's latest page.
        result = client.call({"_": "messages.getDialogs", "offset_date": 0, "offset_id": 0, "offset_peer": {"_": "inputPeerEmpty"}, "limit": args.limit, "hash": 0})
        client.remember_peers(result["users"], result["chats"])
        for dialog in result["dialogs"]:
            if dialog["_"] == "dialogFolder":
                continue
            key = peer_key(dialog["peer"])
            history = client.call({"_": "messages.getHistory", "peer": client.input_peer(key), "offset_id": 0, "offset_date": 0, "add_offset": 0, "limit": 20, "max_id": 0, "min_id": 0, "hash": 0})
            own = [m["id"] for m in history["messages"] if m.get("out")]
            newest = max(own, default=None)
            seen = None if newest is None else newest <= dialog["read_outbox_max_id"]
            print(f"{key.split(':')[0]:<8} read_out={dialog['read_outbox_max_id']:<8} newest_own={newest}  seen={seen}")
    elif args.command == "notify-defaults":
        for peer in ("inputNotifyUsers", "inputNotifyChats", "inputNotifyBroadcasts"):
            print(f"{peer:<22} mute_until={client.call({'_': 'account.getNotifySettings', 'peer': {'_': peer}}).get('mute_until', 0)}")
    elif args.command == "history":
        result = client.call({"_": "messages.getHistory", "peer": client.input_peer(args.peer), "offset_id": args.offset_id, "offset_date": 0, "add_offset": 0, "limit": args.limit, "max_id": 0, "min_id": 0, "hash": 0})
        client.remember_peers(result["users"], result["chats"])
        if args.json:
            print(json.dumps(to_json(result), indent=1, ensure_ascii=False))
            return
        users = {u["id"]: u for u in result["users"]}
        chats = {c["id"]: c for c in result["chats"]}
        print(f"{result['_']} count={result.get('count', len(result['messages']))}")
        for message in reversed(result["messages"]):
            print(message_line(message, users, chats))
    elif args.command == "members":
        peer = client.input_peer(args.peer)
        if peer["_"] == "inputPeerChannel":
            channel = {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}
            result = client.call({"_": "channels.getParticipants", "channel": channel, "filter": {"_": "channelParticipantsRecent"}, "offset": 0, "limit": args.limit, "hash": 0})
            participants, count = result["participants"], result["count"]
        elif peer["_"] == "inputPeerChat":
            result = client.call({"_": "messages.getFullChat", "chat_id": peer["chat_id"]})
            participants = result["full_chat"]["participants"].get("participants", [])
            count = len(participants)
        else:
            raise SystemExit("members needs a group (chat:… or channel:…)")
        if args.json:
            print(json.dumps(to_json(result), indent=1, ensure_ascii=False))
            return
        users = {u["id"]: u for u in result["users"]}
        print(f"{result['_']} count={count} listed={len(participants)}")
        roles: dict = {}
        statuses: dict = {}
        for participant in participants:
            roles[participant["_"]] = roles.get(participant["_"], 0) + 1
            status = (users.get(participant.get("user_id") or participant.get("peer", {}).get("user_id"), {}).get("status") or {}).get("_", "none")
            statuses[status] = statuses.get(status, 0) + 1
        print("roles", roles)
        print("statuses", statuses)
    elif args.command == "chat-info":
        # Whether you may edit: the creator always may; an admin with change_info may; in a basic group, so may
        # everyone unless default_banned_rights.change_info; a supergroup member may unless banned_rights or
        # default_banned_rights has change_info.
        peer = client.input_peer(args.peer)
        if peer["_"] == "inputPeerChannel":
            channel = {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}
            result = client.call({"_": "channels.getFullChannel", "channel": channel})
            chat_id = peer["channel_id"]
        elif peer["_"] == "inputPeerChat":
            result = client.call({"_": "messages.getFullChat", "chat_id": peer["chat_id"]})
            chat_id = peer["chat_id"]
        else:
            raise SystemExit("chat-info needs a group (chat:… or channel:…)")
        full = result["full_chat"]
        chat = next(c for c in result["chats"] if c["id"] == chat_id)
        banned = (chat.get("banned_rights") or {}).get("change_info") or (chat.get("default_banned_rights") or {}).get("change_info")
        print(json.dumps({
            "chat": chat["_"], "full": full["_"], "megagroup": bool(chat.get("megagroup")),
            "title_length": len(chat.get("title", "")), "about_length": len(full.get("about", "")),
            "participants_count": chat.get("participants_count") or full.get("participants_count"),
            "photo": (chat.get("photo") or {}).get("_"), "chat_photo": (full.get("chat_photo") or {}).get("_"),
            "creator": bool(chat.get("creator")), "admin_change_info": bool((chat.get("admin_rights") or {}).get("change_info")),
            "admin_invite_users": bool((chat.get("admin_rights") or {}).get("invite_users")),
            "banned_change_info": bool(banned),
            "can_edit": bool(chat.get("creator") or (chat.get("admin_rights") or {}).get("change_info") or not banned),
        }, indent=1))
    elif args.command == "edit-chat":
        peer = client.input_peer(args.peer)
        if args.title is not None:
            if peer["_"] == "inputPeerChannel":
                channel = {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}
                result = client.call({"_": "channels.editTitle", "channel": channel, "title": args.title})
            else:
                result = client.call({"_": "messages.editChatTitle", "chat_id": peer["chat_id"], "title": args.title})
            print("title:", result["_"])
        if args.about is not None:
            print("about:", client.call({"_": "messages.editChatAbout", "peer": peer, "about": args.about}))
    elif args.command == "custom-emoji":
        result = client.call({"_": "messages.getHistory", "peer": client.input_peer(args.peer), "offset_id": 0, "offset_date": 0, "add_offset": 0, "limit": args.limit, "max_id": 0, "min_id": 0, "hash": 0})
        ids: list[int] = []
        for message in result["messages"]:
            found = [e["document_id"] for e in message.get("entities") or [] if e["_"] == "messageEntityCustomEmoji"]
            found += [r["reaction"]["document_id"] for r in (message.get("reactions") or {}).get("results", []) if r["reaction"]["_"] == "reactionCustomEmoji"]
            if found:
                print(f"message {message['id']}: {len(found)} custom emoji")
            ids += [i for i in found if i not in ids]
        if not ids:
            return
        documents = client.call({"_": "messages.getCustomEmojiDocuments", "document_id": ids[:200]})
        for doc in documents:
            attrs = {a["_"]: a for a in doc.get("attributes", [])}
            emoji = attrs.get("documentAttributeCustomEmoji", {})
            thumbs = [f"{t['_']}:{t.get('type')}" for t in doc.get("thumbs") or []]
            print(f"{doc['id']} {doc.get('mime_type')} {doc.get('size')}B alt={emoji.get('alt')!r} dc={doc.get('dc_id')} thumbs={thumbs}")
        if args.output:
            doc = documents[0]
            sized = [t for t in doc.get("thumbs") or [] if t["_"] == "photoSize"]
            thumb = "" if doc.get("mime_type") == "image/webp" else (sized[-1]["type"] if sized else "")
            location = {"_": "inputDocumentFileLocation", "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"], "thumb_size": thumb}
            data = client.download(location, doc["dc_id"])
            pathlib.Path(args.output).write_bytes(data)
            print(f"{len(data)} bytes (thumb {thumb or 'full'}) -> {args.output}")
    elif args.command == "stickers":
        if args.set:
            documents = sticker_set_documents(client, args.set)
            for doc in documents:
                print(sticker_line(doc))
            return
        recent = client.call({"_": "messages.getRecentStickers", "hash": 0})
        faved = client.call({"_": "messages.getFavedStickers", "hash": 0})
        installed = client.call({"_": "messages.getAllStickers", "hash": 0})
        print(f"recent: {recent['_']} {sticker_formats(recent.get('stickers', []))}")
        for doc in recent.get("stickers", [])[:5]:
            print("  " + sticker_line(doc))
        print(f"faved: {faved['_']} {sticker_formats(faved.get('stickers', []))}")
        print(f"installed: {installed['_']} {len(installed.get('sets', []))} sets")
        for sticker_set in installed.get("sets", []):
            print(f"  {sticker_set['id']} {sticker_set['short_name']!r} {sticker_set['count']} stickers thumbs={[t.get('type') for t in sticker_set.get('thumbs') or []]} thumb_document_id={sticker_set.get('thumb_document_id')}")
    elif args.command == "stickers-for":
        result = client.call({"_": "messages.getStickers", "emoticon": args.emoji, "hash": 0})
        documents = result.get("stickers", [])
        installed = {s["id"] for s in client.call({"_": "messages.getAllStickers", "hash": 0}).get("sets", [])}
        def set_id(doc):
            sticker = next((a for a in doc.get("attributes", []) if a["_"] == "documentAttributeSticker"), {})
            return (sticker.get("stickerset") or {}).get("id")
        print(f"{result['_']}: {len(documents)} stickers, {sum(set_id(d) in installed for d in documents)} from installed sets, formats {sticker_formats(documents)}")
        for doc in documents[:8]:
            print(("  installed " if set_id(doc) in installed else "  suggested ") + sticker_line(doc))
    elif args.command == "sticker-corpus":
        output = pathlib.Path(args.output)
        output.mkdir(parents=True, exist_ok=True)
        documents: dict[int, dict] = {}
        if args.set:
            for name in args.set:
                documents.update((d["id"], d) for d in sticker_set_documents(client, name))
        else:
            for method in ("messages.getRecentStickers", "messages.getFavedStickers"):
                documents.update((d["id"], d) for d in client.call({"_": method, "hash": 0}).get("stickers", []))
            for sticker_set in client.call({"_": "messages.getAllStickers", "hash": 0}).get("sets", []):
                documents.update((d["id"], d) for d in sticker_set_documents(client, str(sticker_set["id"]), access_hash=sticker_set["access_hash"]))
        if args.animated_emoji:
            result = client.call({"_": "messages.getStickerSet", "stickerset": {"_": "inputStickerSetAnimatedEmoji"}, "hash": 0})
            documents.update((d["id"], d) for d in result.get("documents", []))
        extensions = {"application/x-tgsticker": "tgs", "video/webm": "webm", "image/webp": "webp"}
        saved = 0
        for doc in documents.values():
            ext = extensions.get(doc.get("mime_type"))
            if ext is None or (args.format != "all" and ext != args.format):
                continue
            path = output / f"{doc['id']}.{ext}"
            if not path.exists():
                location = {"_": "inputDocumentFileLocation", "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"], "thumb_size": ""}
                path.write_bytes(client.download(location, doc["dc_id"]))
            saved += 1
        print(f"{saved} of {len(documents)} stickers ({args.format}) in {output}")
    elif args.command == "send-sticker":
        if args.document_id:
            pool = client.call({"_": "messages.getRecentStickers", "hash": 0}).get("stickers", [])
            pool += client.call({"_": "messages.getFavedStickers", "hash": 0}).get("stickers", [])
            doc = next((d for d in pool if d["id"] == args.document_id), None)
            if doc is None:
                for sticker_set in client.call({"_": "messages.getAllStickers", "hash": 0}).get("sets", []):
                    doc = next((d for d in sticker_set_documents(client, str(sticker_set["id"]), access_hash=sticker_set["access_hash"]) if d["id"] == args.document_id), None)
                    if doc:
                        break
            if doc is None:
                raise SystemExit("No such sticker among recent, favourite or installed stickers")
        else:
            doc = client.call({"_": "messages.getRecentStickers", "hash": 0})["stickers"][0]
        method = {
            "_": "messages.sendMedia",
            "peer": client.input_peer(args.peer),
            "media": {"_": "inputMediaDocument", "id": {"_": "inputDocument", "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"]}},
            "message": "",
            "random_id": secrets.randbits(63),
        }
        if args.reply_to:
            method["reply_to"] = {"_": "inputReplyToMessage", "reply_to_msg_id": args.reply_to}
        result = client.call(method)
        sent = [u for u in result.get("updates", []) if u["_"] in ("updateNewMessage", "updateNewChannelMessage")]
        media = sent[0]["message"].get("media", {}) if sent else {}
        print(f"{result['_']}: sent {sticker_line(doc)}; message {sent[0]['message']['id'] if sent else '?'} media {media.get('_')} document {(media.get('document') or {}).get('id')}")
    elif args.command == "mute":
        notify_peer = {"_": "inputNotifyPeer", "peer": client.input_peer(args.peer)}
        settings = {"_": "inputPeerNotifySettings", "mute_until": 0 if args.off else 2**31 - 1}
        print("updateNotifySettings:", client.call({"_": "account.updateNotifySettings", "peer": notify_peer, "settings": settings}))
        print("mute_until now:", client.call({"_": "account.getNotifySettings", "peer": notify_peer}).get("mute_until"))
    elif args.command == "archive":
        folder = 0 if args.off else 1
        result = client.call({"_": "folders.editPeerFolders", "folder_peers": [{"_": "inputFolderPeer", "peer": client.input_peer(args.peer), "folder_id": folder}]})
        # An updates with updateFolderPeers {folder_peers: [folderPeer {peer, folder_id}]}.
        print(json.dumps([{"_": u.get("_"), "folder_ids": [fp.get("folder_id") for fp in u.get("folder_peers", [])]} for u in result.get("updates", [])], indent=1))
        dialogs = client.call({"_": "messages.getPeerDialogs", "peers": [{"_": "inputDialogPeer", "peer": client.input_peer(args.peer)}]})
        print("folder_id now:", [d.get("folder_id", 0) for d in dialogs["dialogs"]])
    elif args.command == "peer-status":
        result = client.call({"_": "messages.getPeerDialogs", "peers": [{"_": "inputDialogPeer", "peer": client.input_peer(args.peer)}]})
        user_id = int(args.peer.split(":")[1])
        user = next((u for u in result["users"] if u["id"] == user_id), {})
        print(json.dumps({"self": bool(user.get("self")), "bot": bool(user.get("bot")), "status": to_json(user.get("status"))}, indent=1))
    elif args.command == "send":
        method = {"_": "messages.sendMessage", "peer": client.input_peer(args.peer), "message": args.text, "random_id": secrets.randbits(63)}
        if args.reply_to:
            method["reply_to"] = {"_": "inputReplyToMessage", "reply_to_msg_id": args.reply_to}
        if args.mention_user:
            offset, length = (int(x) for x in args.mention_range.split(":"))
            user = {"_": "inputUser", "user_id": args.mention_user, "access_hash": client.store.data["peers"][f"user:{args.mention_user}"]}
            method["entities"] = [{"_": "inputMessageEntityMentionName", "offset": offset, "length": length, "user_id": user}]
        result = client.call(method)
        print(json.dumps(to_json(result), indent=1, ensure_ascii=False)[:2000])
    elif args.command == "delete":
        peer = client.input_peer(args.peer)
        if peer.get("_") == "inputPeerChannel":
            channel = {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}
            result = client.call({"_": "channels.deleteMessages", "channel": channel, "id": args.msg_id})
        else:
            result = client.call({"_": "messages.deleteMessages", "revoke": True, "id": args.msg_id})
        # messages.affectedMessages: pts and pts_count, the number of messages deleted.
        print(json.dumps({"result": result.get("_"), "pts_count": result.get("pts_count")}, indent=1))
    elif args.command == "edit":
        result = client.call({"_": "messages.editMessage", "peer": client.input_peer(args.peer), "id": args.msg_id, "message": args.text})
        # The edited message comes back in an updateEditMessage (updateEditChannelMessage in supergroups), with edit_date.
        for update in result.get("updates", []):
            message = update.get("message") or {}
            if message.get("id") == args.msg_id:
                print(json.dumps({"update": update["_"], "edit_date": message.get("edit_date"), "edit_hide": bool(message.get("edit_hide")), "text_matches": message.get("message") == args.text}, indent=1))
                break
        else:
            print(result.get("_"))
    elif args.command == "read":
        if args.peer.startswith("channel:"):
            kind, peer_id = args.peer.split(":")
            channel = {"_": "inputChannel", "channel_id": int(peer_id), "access_hash": client.store.data["peers"][args.peer]}
            print(client.call({"_": "channels.readHistory", "channel": channel, "max_id": args.max_id}))
        else:
            print(to_json(client.call({"_": "messages.readHistory", "peer": client.input_peer(args.peer), "max_id": args.max_id})))
    elif args.command == "listen":
        client.call({"_": "updates.getState"})
        print(f"Listening on DC {client.session.dc} for {args.seconds:.0f}s", file=sys.stderr)
        client.session.listen(args.seconds, typing_only=args.typing)
    elif args.command == "typing":
        action = {"_": "sendMessageCancelAction" if args.cancel else "sendMessageTypingAction"}
        print(to_json(client.call({"_": "messages.setTyping", "peer": client.input_peer(args.peer), "action": action})))
    elif args.command == "download":
        kind, peer_id = args.peer.split(":")
        if kind == "channel":
            channel = {"_": "inputChannel", "channel_id": int(peer_id), "access_hash": client.store.data["peers"][args.peer]}
            result = client.call({"_": "channels.getMessages", "channel": channel, "id": [{"_": "inputMessageID", "id": args.msg_id}]})
        else:
            result = client.call({"_": "messages.getMessages", "id": [{"_": "inputMessageID", "id": args.msg_id}]})
        media = result["messages"][0].get("media") or {}
        if media.get("_") == "messageMediaPhoto":
            photo = media["photo"]
            location = {"_": "inputPhotoFileLocation", "id": photo["id"], "access_hash": photo["access_hash"], "file_reference": photo["file_reference"], "thumb_size": args.size}
            dc = photo["dc_id"]
        elif media.get("_") == "messageMediaDocument":
            doc = media["document"]
            location = {"_": "inputDocumentFileLocation", "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"], "thumb_size": "" if args.size == "full" else args.size}
            dc = doc["dc_id"]
        else:
            raise SystemExit(f"No downloadable media: {media.get('_')}")
        started = time.time()
        data = client.download(location, dc)
        pathlib.Path(args.output).write_bytes(data)
        print(f"{len(data)} bytes from DC {dc} in {time.time() - started:.1f}s -> {args.output}")
    elif args.command == "webpage-preview":
        # The preview is webPagePending until Telegram has fetched the page; ask again until it isn't.
        for _ in range(10):
            page = client.call({"_": "messages.getWebPagePreview", "message": args.url})["media"].get("webpage") or {}
            if page.get("_") != "webPagePending":
                break
            time.sleep(2)
        print(f"{page.get('_')} type={page.get('type')} has_large_media={bool(page.get('has_large_media'))} site={page.get('site_name')!r}")
        if page.get("_") != "webPage":
            return

        def best(sizes, max_side=1280):
            sized = [s for s in sizes if s.get("_") in ("photoSize", "photoSizeProgressive", "photoCachedSize")]
            fitting = [s for s in sized if max(s["w"], s["h"]) <= max_side]
            return max(fitting, key=lambda s: s["w"] * s["h"]) if fitting else min(sized, key=lambda s: s["w"] * s["h"], default=None)

        def photo_item(photo):
            size = best(photo.get("sizes", []))
            location = {"_": "inputPhotoFileLocation", "id": photo["id"], "access_hash": photo["access_hash"], "file_reference": photo["file_reference"], "thumb_size": size["type"]}
            return ("photo", f"{size['w']}x{size['h']}", location, photo["dc_id"])

        def document_item(doc):
            video = next((a for a in doc.get("attributes", []) if a.get("_") == "documentAttributeVideo"), None)
            # The poster: the document's largest thumbnail, as a message's video shows it.
            thumb = best(doc.get("thumbs", []), 640)
            location = {"_": "inputDocumentFileLocation", "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"], "thumb_size": thumb["type"] if thumb else ""}
            shape = f"{video['w']}x{video['h']} {video.get('duration', 0):.0f}s" if video else ""
            return (f"document {doc.get('mime_type')} {doc.get('size')} bytes (poster)", shape, location, doc["dc_id"])

        items = []
        cached = page.get("cached_page") or {}
        photos = {p["id"]: p for p in cached.get("photos", [])}
        documents = {d["id"]: d for d in cached.get("documents", [])}

        # A divider ends the page's body: after it come footers such as fxtwitter's "About author" with its avatar.
        def walk(blocks):
            for block in blocks:
                if block.get("_") == "pageBlockDivider":
                    return
                if block.get("_") == "pageBlockPhoto" and block.get("photo_id") in photos:
                    items.append(photo_item(photos[block["photo_id"]]))
                elif block.get("_") == "pageBlockVideo" and block.get("video_id") in documents:
                    items.append(document_item(documents[block["video_id"]]))
                elif block.get("_") in ("pageBlockCollage", "pageBlockSlideshow"):
                    walk(block.get("items", []))

        walk(cached.get("blocks", []))
        print(f"cached_page: {len(items)} media in page order")
        if page.get("document"):
            items = [document_item(page["document"])]
            print("document: the preview's own media (a video or GIF)")
        elif page.get("photo") and not items:
            items.append(photo_item(page["photo"]))
            print("photo: the preview's own image")
        for index, (kind, shape, location, dc) in enumerate(items):
            line = f"  {index}: {kind} {shape} dc={dc}"
            if args.download_dir:
                started = time.time()
                data = client.download(location, dc)
                path = pathlib.Path(args.download_dir) / f"{index}.jpg"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                line += f" -> {len(data)} bytes in {time.time() - started:.1f}s"
            print(line)
    elif args.command == "avatar":
        if args.peer == "self":
            # The signed-in account's own photo, as Settings shows it: users.getUsers([inputUserSelf]),
            # downloaded through inputPeerSelf.
            owner = client.call({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]})[0]
            input_peer = {"_": "inputPeerSelf"}
        else:
            kind, peer_id = args.peer.split(":")
            result = client.call({"_": "messages.getPeerDialogs", "peers": [{"_": "inputDialogPeer", "peer": client.input_peer(args.peer)}]})
            owner = next(o for o in result["users"] + result["chats"] if o["id"] == int(peer_id))
            input_peer = client.input_peer(args.peer)
        photo = owner.get("photo") or {}
        if "photo_id" not in photo:
            raise SystemExit(f"No photo: {photo.get('_')}")
        location = {"_": "inputPeerPhotoFileLocation", "peer": input_peer, "photo_id": photo["photo_id"], "big": args.big}
        started = time.time()
        data = client.download(location, photo["dc_id"])
        pathlib.Path(args.output).write_bytes(data)
        print(f"{len(data)} bytes from DC {photo['dc_id']} in {time.time() - started:.1f}s -> {args.output}")
    elif args.command == "send-photo":
        data = pathlib.Path(args.file).read_bytes()
        file_id = secrets.randbits(63)
        part_size = 512 * 1024
        parts = [data[i : i + part_size] for i in range(0, len(data), part_size)]
        for index, part in enumerate(parts):
            assert client.call({"_": "upload.saveFilePart", "file_id": file_id, "file_part": index, "bytes": part}) is True
        uploaded = {"_": "inputFile", "id": file_id, "parts": len(parts), "name": pathlib.Path(args.file).name, "md5_checksum": ""}
        result = client.call({
            "_": "messages.sendMedia",
            "peer": client.input_peer(args.peer),
            "media": {"_": "inputMediaUploadedPhoto", "file": uploaded},
            "message": args.caption,
            "random_id": secrets.randbits(63),
        })
        sent = [u for u in result.get("updates", []) if u["_"] == "updateMessageID"]
        print(f"{result['_']}: uploaded {len(data)} bytes in {len(parts)} parts, message id {sent[0]['id'] if sent else '?'}")
    elif args.command == "forward":
        method = {
            "_": "messages.forwardMessages",
            "from_peer": client.input_peer(args.from_peer),
            "id": args.ids,
            "random_id": [secrets.randbits(63) for _ in args.ids],
            "to_peer": client.input_peer(args.to_peer),
        }
        if args.drop_author:
            method["drop_author"] = True
        result = client.call(method)
        # Updates: updateMessageID per random_id, then updateNewMessage (updateNewChannelMessage in supergroups and
        # channels) with the forwarded copy and its fwd_from header.
        print(result["_"], [u["_"] for u in result.get("updates", [])])
        for update in result.get("updates", []):
            message = update.get("message")
            if not isinstance(message, dict):
                continue
            media = message.get("media") or {}
            print(json.dumps({
                "update": update["_"],
                "id": message["id"],
                "fwd_from": fwd_header_shape(message.get("fwd_from")),
                "media": media.get("_"),
                "voice": bool(media.get("voice")),
                "has_text": bool(message.get("message")),
            }, indent=1))
    elif args.command == "forwards":
        dialogs = client.call({"_": "messages.getDialogs", "offset_date": 0, "offset_id": 0, "offset_peer": {"_": "inputPeerEmpty"}, "limit": args.dialogs, "hash": 0})
        client.remember_peers(dialogs["users"], dialogs["chats"])
        kinds: dict = {}
        for dialog in dialogs["dialogs"]:
            key = peer_key(dialog["peer"])
            try:
                history = client.call({"_": "messages.getHistory", "peer": client.input_peer(key), "offset_id": 0, "offset_date": 0, "add_offset": 0, "limit": args.limit, "max_id": 0, "min_id": 0, "hash": 0})
            except Exception as error:  # noqa: BLE001 — a chat that can't be read is skipped
                print(f"skip {key.split(':')[0]}: {type(error).__name__}")
                continue
            for message in history.get("messages", []):
                header = message.get("fwd_from")
                if not header:
                    continue
                origin = (header.get("from_id") or {}).get("_", "none")
                kind = f"from_id={origin}" + (" +channel_post" if "channel_post" in header else "") + (" +from_name" if "from_name" in header else "")
                entry = kinds.setdefault(kind, {"count": 0, "fields": set(), "chats": set(), "named": 0})
                entry["count"] += 1
                # Whether the origin's name comes in the same response, so a client can show it without a lookup.
                origin_peer = header.get("from_id") or {}
                known = {("peerUser", u["id"]) for u in history.get("users", [])} | {("peerChannel", c["id"]) for c in history.get("chats", [])} | {("peerChat", c["id"]) for c in history.get("chats", [])}
                origin_id = origin_peer.get("user_id") or origin_peer.get("channel_id") or origin_peer.get("chat_id")
                if (origin_peer.get("_"), origin_id) in known or "from_name" in header:
                    entry["named"] += 1
                entry["fields"].update(k for k in header if k not in ("_", "flags"))
                entry["chats"].add(key.split(":")[0])
        for kind, entry in sorted(kinds.items()):
            print(f"{kind}: {entry['count']} ({entry['named']} named in the response) in {sorted(entry['chats'])} chats, fields {sorted(entry['fields'])}")
    elif args.command == "send-voice":
        data = pathlib.Path(args.file).read_bytes()
        file_id = secrets.randbits(63)
        part_size = 512 * 1024
        parts = [data[i : i + part_size] for i in range(0, len(data), part_size)]
        for index, part in enumerate(parts):
            assert client.call({"_": "upload.saveFilePart", "file_id": file_id, "file_part": index, "bytes": part}) is True
        uploaded = {"_": "inputFile", "id": file_id, "parts": len(parts), "name": pathlib.Path(args.file).name, "md5_checksum": ""}
        audio = {"_": "documentAttributeAudio", "voice": True, "duration": args.duration}
        if args.levels:
            audio["waveform"] = pack_waveform([int(level) for level in args.levels.split(",")])
        result = client.call({
            "_": "messages.sendMedia",
            "peer": client.input_peer(args.peer),
            "media": {"_": "inputMediaUploadedDocument", "file": uploaded, "mime_type": "audio/ogg", "attributes": [audio]},
            "message": "",
            "random_id": secrets.randbits(63),
        })
        sent = [u for u in result.get("updates", []) if u["_"] == "updateMessageID"]
        for update in result.get("updates", []):
            message = update.get("message") or {}
            document = (message.get("media") or {}).get("document")
            if document:
                attributes = [{k: v for k, v in a.items() if k != "waveform"} | ({"waveform_levels": unpack_waveform(a["waveform"])} if "waveform" in a else {}) for a in document["attributes"]]
                print("media", message["media"]["_"], "voice" if message["media"].get("voice") else "not voice", document["mime_type"], document["size"], attributes)
        print(f"{result['_']}: uploaded {len(data)} bytes in {len(parts)} parts, message id {sent[0]['id'] if sent else '?'}")
    elif args.command == "push-register":
        token_type, token = (1, args.apns) if args.apns else (10, webpush_token(client.store, args.endpoint))
        result = client.call({"_": "account.registerDevice", "no_muted": True, "token_type": token_type, "token": token, "app_sandbox": args.sandbox, "secret": b"", "other_uids": []})
        print(f"account.registerDevice: {result}")
    elif args.command == "push-unregister":
        token_type, token = (1, args.apns) if args.apns else (10, webpush_token(client.store, args.endpoint))
        print(f"account.unregisterDevice: {client.call({'_': 'account.unregisterDevice', 'token_type': token_type, 'token': token, 'other_uids': []})}")
    elif args.command == "push-decrypt":
        push = client.store.data["webpush"]
        plain = webpush_decrypt(pathlib.Path(args.file).read_bytes(), push["private_key"], bytes.fromhex(push["auth"]))
        print(json.dumps(json.loads(plain), indent=1, ensure_ascii=False))
    elif args.command == "react":
        reaction = [{"_": "reactionEmoji", "emoticon": args.emoji}] if args.emoji else []
        result = client.call({"_": "messages.sendReaction", "peer": client.input_peer(args.peer), "msg_id": args.msg_id, "reaction": reaction})
        for update in result.get("updates", []):
            if update["_"] == "updateMessageReactions":
                counts = [(r["reaction"].get("emoticon"), r["count"], "chosen_order" in r) for r in update["reactions"]["results"]]
                print("updateMessageReactions", counts)
    elif args.command == "buttons":
        result = client.call({"_": "messages.getHistory", "peer": client.input_peer(args.peer), "offset_id": 0, "offset_date": 0, "add_offset": 0, "limit": args.limit, "max_id": 0, "min_id": 0, "hash": 0})
        for message in result["messages"]:
            markup = message.get("reply_markup")
            if not markup:
                continue
            # replyKeyboardMarkup is the bot's custom keyboard under the composer, not buttons on the message.
            print(message["id"], markup["_"], "edited" if message.get("edit_date") else "")
            for row in markup.get("rows", []):
                print("   ", [(b["_"].removeprefix("keyboardButton"), b.get("text"), b.get("data", b.get("url"))) for b in row["buttons"]])
    elif args.command == "press":
        peer = client.input_peer(args.peer)
        message = client.call({"_": "messages.getMessages", "id": [{"_": "inputMessageID", "id": args.msg_id}]})["messages"][0] if peer["_"] != "inputPeerChannel" else client.call({"_": "channels.getMessages", "channel": {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}, "id": [{"_": "inputMessageID", "id": args.msg_id}]})["messages"][0]
        button = message["reply_markup"]["rows"][args.row]["buttons"][args.column]
        if button["_"] != "keyboardButtonCallback":
            sys.exit(f"{button['_']} is not a callback button")
        print("pressing", button["text"], button["data"], "edit_date before:", message.get("edit_date"))
        started = time.time()
        answer = client.call({"_": "messages.getBotCallbackAnswer", "peer": peer, "msg_id": args.msg_id, "data": button["data"]})
        print(f"{time.time() - started:.1f}s", json.dumps(to_json(answer), ensure_ascii=False))
        time.sleep(2)
        after = client.call({"_": "messages.getMessages", "id": [{"_": "inputMessageID", "id": args.msg_id}]})["messages"][0] if peer["_"] != "inputPeerChannel" else None
        if after:
            print("edit_date after:", after.get("edit_date"), "same text:", after.get("message") == message.get("message"))
    elif args.command == "reactions":
        # An emoji outside the list is refused with REACTION_INVALID (observed 2026-10-31); reactions in Saved
        # Messages are tags, which need Premium (PREMIUM_ACCOUNT_REQUIRED for any emoji).
        premium = bool(client.call({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]})[0].get("premium"))
        available = client.call({"_": "messages.getAvailableReactions", "hash": 0})["reactions"]
        usable = [r["reaction"] for r in available if not r.get("inactive") and (premium or not r.get("premium"))]
        peer = client.input_peer(args.peer)
        chat_reactions = None
        if peer["_"] == "inputPeerChannel":
            channel = {"_": "inputChannel", "channel_id": peer["channel_id"], "access_hash": peer["access_hash"]}
            chat_reactions = client.call({"_": "channels.getFullChannel", "channel": channel})["full_chat"].get("available_reactions")
        elif peer["_"] == "inputPeerChat":
            chat_reactions = client.call({"_": "messages.getFullChat", "chat_id": peer["chat_id"]})["full_chat"].get("available_reactions")
        kind = (chat_reactions or {}).get("_")
        if peer["_"] == "inputPeerSelf" and not premium:
            allowed = []
        elif kind == "chatReactionsNone":
            allowed = []
        elif kind == "chatReactionsSome":
            listed = {r.get("emoticon") for r in chat_reactions["reactions"]}
            allowed = [e for e in usable if e in listed]
        else:
            allowed = usable
        print(json.dumps({"premium": premium, "chat_reactions": kind, "count": len(allowed), "allowed": "".join(allowed)}, indent=1, ensure_ascii=False))
    elif args.command == "resolve":
        result = client.call({"_": "contacts.resolveUsername", "username": args.username.lstrip("@")})
        client.remember_peers(result["users"], result["chats"])
        user = next((u for u in result["users"] if u["id"] == result["peer"].get("user_id")), None)
        chat = next((c for c in result["chats"] if c["id"] in (result["peer"].get("channel_id"), result["peer"].get("chat_id"))), None)
        if user:
            print(json.dumps({"peer": f"user:{user['id']}", "name": " ".join(filter(None, [user.get("first_name"), user.get("last_name")])), "username": user.get("username"), "bot": bool(user.get("bot")), "photo": (user.get("photo") or {}).get("_"), "status": (user.get("status") or {}).get("_")}, indent=1, ensure_ascii=False))
        else:
            print(json.dumps({"peer": peer_key(result["peer"]), "title": (chat or {}).get("title"), "broadcast": bool((chat or {}).get("broadcast"))}, indent=1, ensure_ascii=False))
    elif args.command == "profile":
        user = {"_": "inputUser", "user_id": args.user, "access_hash": client.store.data["peers"][f"user:{args.user}"]}
        result = client.call({"_": "users.getFullUser", "id": user})
        full = result["full_user"]
        listed = next(u for u in result["users"] if u["id"] == args.user)
        print(json.dumps({"name": " ".join(filter(None, [listed.get("first_name"), listed.get("last_name")])), "username": listed.get("username"), "about": full.get("about"), "status": to_json(listed.get("status")), "photo": (full.get("profile_photo") or {}).get("_"), "common_chats_count": full.get("common_chats_count")}, indent=1, ensure_ascii=False))
    elif args.command == "mentions":
        result = client.call({"_": "messages.getHistory", "peer": client.input_peer(args.peer), "offset_id": 0, "offset_date": 0, "add_offset": 0, "limit": args.limit, "max_id": 0, "min_id": 0, "hash": 0})
        client.remember_peers(result["users"], result["chats"])
        usernames = {(u.get("username") or "").lower(): u["id"] for u in result["users"] if u.get("username")}
        user_ids = {u["id"] for u in result["users"]}
        for message in result["messages"]:
            utf16 = message.get("message", "").encode("utf-16-le")
            for entity in message.get("entities") or []:
                if entity["_"] == "messageEntityMention":
                    # Offsets and lengths count UTF-16 code units, as Telegram's do.
                    name = utf16[entity["offset"] * 2:(entity["offset"] + entity["length"]) * 2].decode("utf-16-le")
                    found = usernames.get(name[1:].lower())
                    print(f"{message['id']:>8} @username {entity['offset']}:{entity['length']} -> {f'user:{found} (in response)' if found else 'resolve on tap'}")
                elif entity["_"] == "messageEntityMentionName":
                    print(f"{message['id']:>8} name {entity['offset']}:{entity['length']} -> user:{entity['user_id']}{' (in response)' if entity['user_id'] in user_ids else ''}")
    elif args.command == "raw":
        params = json.loads(args.json)
        params["_"] = args.method
        print(json.dumps(to_json(client.call(params)), indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
