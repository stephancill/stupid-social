#!/usr/bin/env python3
"""Probe Bluesky/atproto API responses using the app's simulator OAuth session.

The default credential source reads the same UserDefaults fallback blob that the
debug simulator build uses when Keychain writes are unavailable. The script never
prints token values; use --output to save raw service responses for fixtures.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey
from cryptography.hazmat.primitives import hashes


SIM_PREFS_SCRIPT = Path.home() / ".config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
BLUESKY_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.bluesky.localFallback"
USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Mobile/15E148 Safari/604.1"


@dataclass
class Credentials:
    access_token: str
    refresh_token: str
    did: str
    handle: str | None
    pds_url: str
    auth_server_url: str
    scope: str
    dpop_private_key: bytes
    expires_at: float | None
    auth_nonce: str | None = None
    resource_nonce: str | None = None


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def decode_base64(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.b64decode(value + padding)


def json_base64url(value: dict[str, Any]) -> str:
    return base64url(json.dumps(value, separators=(",", ":"), sort_keys=True).encode())


def load_simulator_credentials() -> Credentials:
    raw = subprocess.check_output(
        ["python3", str(SIM_PREFS_SCRIPT), "--raw-key", BLUESKY_FALLBACK_KEY],
        text=True,
    )
    value = json.loads(raw)
    return Credentials(
        access_token=value["accessToken"],
        refresh_token=value["refreshToken"],
        did=value["did"],
        handle=value.get("handle"),
        pds_url=value["pdsURL"].rstrip("/"),
        auth_server_url=value["authServerURL"].rstrip("/"),
        scope=value["scope"],
        dpop_private_key=decode_base64(value["dpopPrivateKey"]),
        expires_at=value.get("expiresAt"),
        auth_nonce=value.get("authNonce"),
        resource_nonce=value.get("resourceNonce"),
    )


def private_key(raw: bytes) -> EllipticCurvePrivateKey:
    return ec.derive_private_key(int.from_bytes(raw, "big"), ec.SECP256R1())


def public_jwk(key: EllipticCurvePrivateKey) -> dict[str, str]:
    numbers = key.public_key().public_numbers()
    return {
        "kty": "EC",
        "crv": "P-256",
        "x": base64url(numbers.x.to_bytes(32, "big")),
        "y": base64url(numbers.y.to_bytes(32, "big")),
    }


def dpop_proof(
    *,
    method: str,
    url: str,
    raw_private_key: bytes,
    nonce: str | None,
    access_token: str | None,
) -> str:
    key = private_key(raw_private_key)
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": public_jwk(key)}
    payload: dict[str, Any] = {
        "jti": secrets.token_urlsafe(16),
        "htm": method.upper(),
        "htu": url,
        "iat": int(time.time()),
    }
    if nonce:
        payload["nonce"] = nonce
    if access_token:
        payload["ath"] = base64url(hashlib.sha256(access_token.encode()).digest())

    signing_input = f"{json_base64url(header)}.{json_base64url(payload)}"
    signature_der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(signature_der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{base64url(signature)}"


def request_json(
    *,
    credentials: Credentials,
    method: str,
    url: str,
    query: dict[str, str] | None = None,
    retry_nonce: bool = True,
) -> Any:
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    proof = dpop_proof(
        method=method,
        url=url,
        raw_private_key=credentials.dpop_private_key,
        nonce=credentials.resource_nonce,
        access_token=credentials.access_token,
    )
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "accept": "application/json",
            "authorization": f"DPoP {credentials.access_token}",
            "dpop": proof,
            "user-agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            nonce = response.headers.get("DPoP-Nonce")
            if nonce:
                credentials.resource_nonce = nonce
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        nonce = error.headers.get("DPoP-Nonce")
        if retry_nonce and error.code == 401 and nonce:
            credentials.resource_nonce = nonce
            return request_json(credentials=credentials, method=method, url=url, retry_nonce=False)
        body = error.read().decode(errors="replace")
        raise SystemExit(f"HTTP {error.code} {url}\n{body}") from error


def write_output(value: Any, output: Path | None) -> None:
    if output is None:
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {output}")


def summarize_notifications(value: dict[str, Any]) -> None:
    notifications = value.get("notifications", [])
    print(f"notifications: {len(notifications)}")
    for item in notifications[:20]:
        author = item.get("author", {}).get("handle") or item.get("author", {}).get("did")
        text = item.get("record", {}).get("text") or ""
        subject = item.get("reasonSubject") or item.get("uri")
        print(f"- {item.get('reason')} from {author}: {subject} {text[:80]!r}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch Bluesky API responses using simulator OAuth credentials.")
    parser.add_argument("command", choices=["notifications", "post-thread", "profile"])
    parser.add_argument("--output", type=Path, help="Write raw JSON response to this path.")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--uri", help="Post URI for post-thread. Defaults to first notification reasonSubject/uri.")
    parser.add_argument("--actor", help="Actor DID/handle for profile. Defaults to the signed-in DID.")
    parser.add_argument("--summary", action="store_true", help="Print a compact response summary instead of raw JSON.")
    args = parser.parse_args()

    credentials = load_simulator_credentials()

    if args.command == "notifications":
        value = request_json(
            credentials=credentials,
            method="GET",
            url=f"{credentials.pds_url}/xrpc/app.bsky.notification.listNotifications",
            query={"limit": str(args.limit)},
        )
        if args.summary:
            summarize_notifications(value)
        else:
            write_output(value, args.output)
        return

    if args.command == "post-thread":
        uri = args.uri
        if uri is None:
            notifications = request_json(
                credentials=credentials,
                method="GET",
                url=f"{credentials.pds_url}/xrpc/app.bsky.notification.listNotifications",
                query={"limit": str(args.limit)},
            ).get("notifications", [])
            uri = next((item.get("reasonSubject") or item.get("uri") for item in notifications if item.get("reasonSubject") or item.get("uri")), None)
        if uri is None:
            raise SystemExit("No post URI available. Pass --uri.")
        value = request_json(
            credentials=credentials,
            method="GET",
            url=f"{credentials.pds_url}/xrpc/app.bsky.feed.getPostThread",
            query={"uri": uri, "depth": "0"},
        )
        write_output(value, args.output)
        return

    actor = args.actor or credentials.did
    value = request_json(
        credentials=credentials,
        method="GET",
        url=f"{credentials.pds_url}/xrpc/app.bsky.actor.getProfile",
        query={"actor": actor},
    )
    write_output(value, args.output)


if __name__ == "__main__":
    main()
