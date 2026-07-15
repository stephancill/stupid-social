#!/usr/bin/env python3
"""Probe Bluesky/ATProto OAuth PAR startup for the app client metadata.

This does not open a browser or exchange tokens. It verifies the public native
client metadata by resolving a login handle to its PDS, discovering the PDS auth
server, and submitting a PKCE + DPoP pushed authorization request.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey


DEFAULT_CLIENT_ID = "https://stupidtech.net/stupid-social/oauth/client-metadata.json"
DEFAULT_PUBLIC_PDS = "https://bsky.social"
USER_AGENT = "stupid-social OAuth PAR probe"


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def json_base64url(value: dict[str, Any]) -> str:
    return base64url(json.dumps(value, separators=(",", ":"), sort_keys=True).encode())


def request_json(url: str, *, method: str = "GET", headers: dict[str, str] | None = None, body: bytes | None = None) -> tuple[Any, dict[str, str], int]:
    req = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"accept": "application/json", "user-agent": USER_AGENT, **(headers or {})},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            response_body = response.read().decode()
            value = json.loads(response_body) if response_body else None
            return value, dict(response.headers), response.status
    except urllib.error.HTTPError as error:
        response_body = error.read().decode(errors="replace")
        try:
            value = json.loads(response_body)
        except json.JSONDecodeError:
            value = {"error": response_body}
        return value, dict(error.headers), error.code


def resolve_handle(handle: str) -> str:
    normalized = handle.removeprefix("@").strip()
    query = urllib.parse.urlencode({"handle": normalized})
    value, _, status = request_json(f"{DEFAULT_PUBLIC_PDS}/xrpc/com.atproto.identity.resolveHandle?{query}")
    if status != 200:
        raise SystemExit(f"Handle resolution failed with HTTP {status}: {json.dumps(value)}")
    return value["did"]


def did_document_url(did: str) -> str:
    if did.startswith("did:plc:"):
        return f"https://plc.directory/{urllib.parse.quote(did, safe=':')}"
    if did.startswith("did:web:"):
        host = did.removeprefix("did:web:").replace(":", "/")
        return f"https://{host}/.well-known/did.json"
    raise SystemExit(f"Unsupported DID method: {did}")


def discover_pds_url(did: str) -> str:
    value, _, status = request_json(did_document_url(did))
    if status != 200:
        raise SystemExit(f"DID document fetch failed with HTTP {status}: {json.dumps(value)}")
    for service in value.get("service", []):
        if service.get("id") == "#atproto_pds" or service.get("type") == "AtprotoPersonalDataServer":
            endpoint = service.get("serviceEndpoint")
            if isinstance(endpoint, str):
                return endpoint.rstrip("/")
    raise SystemExit("DID document did not contain an atproto PDS service.")


def discover_auth_server(pds_url: str) -> tuple[str, str, str]:
    protected, _, protected_status = request_json(f"{pds_url}/.well-known/oauth-protected-resource")
    if protected_status != 200:
        raise SystemExit(f"Protected resource metadata failed with HTTP {protected_status}: {json.dumps(protected)}")
    auth_server = protected.get("authorization_servers", [pds_url])[0].rstrip("/")
    auth_metadata, _, auth_status = request_json(f"{auth_server}/.well-known/oauth-authorization-server")
    if auth_status != 200:
        raise SystemExit(f"Authorization server metadata failed with HTTP {auth_status}: {json.dumps(auth_metadata)}")
    return auth_server, auth_metadata["pushed_authorization_request_endpoint"], auth_metadata["authorization_endpoint"]


def private_key() -> EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def public_jwk(key: EllipticCurvePrivateKey) -> dict[str, str]:
    numbers = key.public_key().public_numbers()
    return {
        "kty": "EC",
        "crv": "P-256",
        "x": base64url(numbers.x.to_bytes(32, "big")),
        "y": base64url(numbers.y.to_bytes(32, "big")),
    }


def dpop_proof(*, key: EllipticCurvePrivateKey, method: str, url: str, nonce: str | None) -> str:
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": public_jwk(key)}
    payload: dict[str, Any] = {
        "jti": secrets.token_urlsafe(16),
        "htm": method.upper(),
        "htu": url,
        "iat": int(time.time()),
    }
    if nonce:
        payload["nonce"] = nonce
    signing_input = f"{json_base64url(header)}.{json_base64url(payload)}"
    signature_der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(signature_der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{base64url(signature)}"


def post_par(
    *,
    par_endpoint: str,
    login_hint: str,
    client_id: str,
    redirect_uri: str,
    key: EllipticCurvePrivateKey,
    nonce: str | None,
) -> tuple[Any, dict[str, str], int]:
    verifier = secrets.token_urlsafe(48)
    code_challenge = base64url(hashlib.sha256(verifier.encode()).digest())
    form = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": "atproto transition:generic",
        "state": secrets.token_urlsafe(24),
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "login_hint": login_hint.removeprefix("@"),
    }
    return request_json(
        par_endpoint,
        method="POST",
        headers={
            "content-type": "application/x-www-form-urlencoded",
            "dpop": dpop_proof(key=key, method="POST", url=par_endpoint, nonce=nonce),
        },
        body=urllib.parse.urlencode(form).encode(),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Probe ATProto OAuth PAR for stupid social.")
    parser.add_argument("handle", nargs="?", default="@stephancill.co.za")
    parser.add_argument("--client-id", default=DEFAULT_CLIENT_ID)
    parser.add_argument("--redirect-uri")
    parser.add_argument("--skip-client-metadata-check", action="store_true")
    args = parser.parse_args()
    if args.redirect_uri is None:
        host = urllib.parse.urlparse(args.client_id).hostname or ""
        args.redirect_uri = f"{'.'.join(reversed(host.split('.')))}:/oauth/bluesky/callback"

    if not args.skip_client_metadata_check:
        client_metadata, _, client_status = request_json(args.client_id)
        if client_status != 200:
            raise SystemExit(f"Client metadata fetch failed with HTTP {client_status}: {json.dumps(client_metadata)}")
        if client_metadata.get("client_id") != args.client_id or args.redirect_uri not in client_metadata.get("redirect_uris", []):
            raise SystemExit("Client metadata did not match the app client id and redirect URI.")

    did = resolve_handle(args.handle)
    pds_url = discover_pds_url(did)
    auth_server, par_endpoint, authorization_endpoint = discover_auth_server(pds_url)

    key = private_key()
    response, headers, status = post_par(
        par_endpoint=par_endpoint,
        login_hint=args.handle,
        client_id=args.client_id,
        redirect_uri=args.redirect_uri,
        key=key,
        nonce=None,
    )
    if status in (400, 401) and headers.get("DPoP-Nonce"):
        response, headers, status = post_par(
            par_endpoint=par_endpoint,
            login_hint=args.handle,
            client_id=args.client_id,
            redirect_uri=args.redirect_uri,
            key=key,
            nonce=headers["DPoP-Nonce"],
        )

    print(f"handle: {args.handle}")
    print(f"did: {did}")
    print(f"pds: {pds_url}")
    print(f"auth server: {auth_server}")
    print(f"client metadata: {args.client_id}")
    print(f"redirect uri: {args.redirect_uri}")
    print(f"PAR status: HTTP {status}")
    if status not in (200, 201):
        raise SystemExit(json.dumps(response, indent=2, sort_keys=True))
    print(f"request_uri present: {bool(response.get('request_uri'))}")
    print(f"authorization endpoint: {authorization_endpoint}")


if __name__ == "__main__":
    main()
