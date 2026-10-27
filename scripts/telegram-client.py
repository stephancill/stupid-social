#!/usr/bin/env python3
"""Dependency-free Telegram MTProto 2.0 probe: the source of truth for the native Swift client.

Talks to Telegram's production DCs over TCP (intermediate transport) with a user account, using the TL
schema in Sources/NoFeedSocialCore/Resources/TelegramSchema.tl (built by scripts/telegram-schema.py).

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
  send --peer user:1 --text "hi" [--reply-to N]
  read --peer user:1 --max-id N
  listen [--seconds N]        print updates pushed on the connection
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
SCHEMA_PATH = ROOT / "Sources/NoFeedSocialCore/Resources/TelegramSchema.tl"
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


class AES256:
    def __init__(self, key: bytes):
        assert len(key) == 32
        words = list(struct.unpack(">8I", key))
        rcon = 1
        for i in range(8, 60):
            temp = words[i - 1]
            if i % 8 == 0:
                temp = ((temp << 8) | (temp >> 24)) & 0xFFFFFFFF
                temp = self._sub_word(temp) ^ (rcon << 24)
                rcon = ((rcon << 1) ^ 0x11B) if rcon & 0x80 else rcon << 1
            elif i % 8 == 4:
                temp = self._sub_word(temp)
            words.append(words[i - 8] ^ temp)
        self.ek = words
        dk = []
        for r in range(14, -1, -1):
            round_key = words[4 * r : 4 * r + 4]
            if 0 < r < 14:
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
        t0, t1, t2, t3 = TE
        s0, s1, s2, s3 = struct.unpack(">4I", block)
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        for r in range(1, 14):
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
            ((S[s0 >> 24] << 24) | (S[(s1 >> 16) & 255] << 16) | (S[(s2 >> 8) & 255] << 8) | S[s3 & 255]) ^ k[56],
            ((S[s1 >> 24] << 24) | (S[(s2 >> 16) & 255] << 16) | (S[(s3 >> 8) & 255] << 8) | S[s0 & 255]) ^ k[57],
            ((S[s2 >> 24] << 24) | (S[(s3 >> 16) & 255] << 16) | (S[(s0 >> 8) & 255] << 8) | S[s1 & 255]) ^ k[58],
            ((S[s3 >> 24] << 24) | (S[(s0 >> 16) & 255] << 16) | (S[(s1 >> 8) & 255] << 8) | S[s2 & 255]) ^ k[59],
        )

    def decrypt_block(self, block: bytes) -> bytes:
        k = self.dk
        t0, t1, t2, t3 = TD
        s0, s1, s2, s3 = struct.unpack(">4I", block)
        s0 ^= k[0]
        s1 ^= k[1]
        s2 ^= k[2]
        s3 ^= k[3]
        for r in range(1, 14):
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
            ((S[s0 >> 24] << 24) | (S[(s3 >> 16) & 255] << 16) | (S[(s2 >> 8) & 255] << 8) | S[s1 & 255]) ^ k[56],
            ((S[s1 >> 24] << 24) | (S[(s0 >> 16) & 255] << 16) | (S[(s3 >> 8) & 255] << 8) | S[s2 & 255]) ^ k[57],
            ((S[s2 >> 24] << 24) | (S[(s1 >> 16) & 255] << 16) | (S[(s0 >> 8) & 255] << 8) | S[s3 & 255]) ^ k[58],
            ((S[s3 >> 24] << 24) | (S[(s2 >> 16) & 255] << 16) | (S[(s1 >> 8) & 255] << 8) | S[s0 & 255]) ^ k[59],
        )


def _xor(a: bytes, b: bytes) -> bytes:
    return (int.from_bytes(a, "big") ^ int.from_bytes(b, "big")).to_bytes(len(a), "big")


def ige_encrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    assert len(data) % 16 == 0
    aes = AES256(key)
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
    aes = AES256(key)
    prev_cipher, prev_plain = iv[:16], iv[16:]
    out = bytearray()
    for i in range(0, len(data), 16):
        block = data[i : i + 16]
        plain = _xor(aes.decrypt_block(_xor(block, prev_plain)), prev_cipher)
        out += plain
        prev_cipher, prev_plain = block, plain
    return bytes(out)


def self_test():
    aes = AES256(bytes(range(32)))
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

    def listen(self, seconds: float):
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
                print(json.dumps(to_json(self.updates.pop(0)), ensure_ascii=False))


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
    history = sub.add_parser("history")
    history.add_argument("--peer", required=True)
    history.add_argument("--limit", type=int, default=20)
    history.add_argument("--offset-id", type=int, default=0)
    history.add_argument("--json", action="store_true")
    send = sub.add_parser("send")
    send.add_argument("--peer", required=True)
    send.add_argument("--text", required=True)
    send.add_argument("--reply-to", type=int)
    read = sub.add_parser("read")
    read.add_argument("--peer", required=True)
    read.add_argument("--max-id", type=int, required=True)
    listen = sub.add_parser("listen")
    listen.add_argument("--seconds", type=float, default=60)
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
        print(f"{result['_']} count={result.get('count', len(result['dialogs']))}")
        for dialog in result["dialogs"]:
            if dialog["_"] == "dialogFolder":
                print(f"dialogFolder {dialog['folder']['title']!r} unmuted_peers={dialog['unread_unmuted_peers_count']} muted_peers={dialog['unread_muted_peers_count']}")
                continue
            key = peer_key(dialog["peer"])
            chat = chats.get(int(key.split(":")[1])) if not key.startswith("user") else None
            kind = "broadcast" if chat and chat.get("broadcast") else "group" if chat else "user"
            top = messages.get((key, dialog["top_message"]))
            print(f"{key:<24} {kind:<9} unread={dialog['unread_count']:<4} read_in={dialog['read_inbox_max_id']} read_out={dialog['read_outbox_max_id']}  {name_of(users, chats, key)}")
            if top:
                print("    " + message_line(top, users, chats))
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
    elif args.command == "send":
        method = {"_": "messages.sendMessage", "peer": client.input_peer(args.peer), "message": args.text, "random_id": secrets.randbits(63)}
        if args.reply_to:
            method["reply_to"] = {"_": "inputReplyToMessage", "reply_to_msg_id": args.reply_to}
        result = client.call(method)
        print(json.dumps(to_json(result), indent=1, ensure_ascii=False)[:2000])
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
        client.session.listen(args.seconds)
    elif args.command == "raw":
        params = json.loads(args.json)
        params["_"] = args.method
        print(json.dumps(to_json(client.call(params)), indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
