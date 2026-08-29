#!/usr/bin/env python3
"""App Store Connect helper for external TestFlight submission.

Generates a short-lived ES256 JWT from the stored ASC API key and performs
beta group / build / submission operations. Never prints key material.
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.backends import default_backend

CONF = os.path.expanduser("~/.stupid-app/credentials")
BASE = "https://api.appstoreconnect.apple.com/v1"
APP_ID = os.environ.get("ASC_APP_ID", "6764539627")
BUILD_ID = os.environ.get("ASC_BUILD_ID", "ee81e194-4420-4d79-be70-39313ca798fe")


def read(name):
    with open(os.path.join(CONF, name)) as f:
        return f.read().strip()


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token() -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": read("asc.key-id"), "typ": "JWT"}
    payload = {"iss": read("asc.issuer-id"), "exp": now + 1200,
               "aud": "appstoreconnect-v1"}
    signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + \
        "." + b64url(json.dumps(payload, separators=(",", ":")).encode())
    with open(os.path.join(CONF, "asc.key.pem"), "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None,
                                                 backend=default_backend())
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + b64url(sig)


def api(token, method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode())
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["groups", "get-build", "add-to-group", "submit", "whats-new"])
    ap.add_argument("--group", help="beta group id")
    ap.add_argument("--text", help="'What's New' notes for the build")
    args = ap.parse_args()
    token = make_token()

    if args.action == "groups":
        data = api(token, "GET", f"/apps/{APP_ID}/betaGroups")
        for g in data.get("data", []):
            a = g["attributes"]
            print(f"{g['id']} | {a.get('name')} | isInternal={a.get('isInternalGroup')}"
                  f" | state={a.get('betaGroupState')} | testers={a.get('betaTesters')}")

    elif args.action == "get-build":
        data = api(token, "GET", f"/builds/{BUILD_ID}")
        b = data["data"]
        rel = b.get("relationships", {}).get("betaGroups", {}).get("data", [])
        print("id:", b["id"])
        print("version:", b["attributes"].get("version"))
        print("processingState:", b["attributes"].get("processingState"))
        print("betaGroups:", [x["id"] for x in rel])

    elif args.action == "add-to-group":
        body = {
            "data": [
                {"type": "betaGroups", "id": args.group},
            ]
        }
        api(token, "POST", f"/builds/{BUILD_ID}/relationships/betaGroups", body)
        print(f"Associated build {BUILD_ID} with beta group {args.group}")

    elif args.action == "submit":
        body = {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"id": BUILD_ID, "type": "builds"}},
                },
            }
        }
        data = api(token, "POST", "/betaAppReviewSubmissions", body)
        sub = data.get("data", {})
        print(json.dumps({
            "id": sub.get("id"),
            "state": sub.get("attributes", {}).get("betaReviewState"),
        }, indent=2))

    elif args.action == "whats-new":
        if not args.text:
            ap.error("--text is required for whats-new")
        locs = api(token, "GET", f"/builds/{BUILD_ID}/betaBuildLocalizations")
        items = locs.get("data", [])
        if items:
            loc_id = items[0]["id"]
            api(token, "PATCH", f"/betaBuildLocalizations/{loc_id}",
                {"data": {"id": loc_id, "type": "betaBuildLocalizations",
                          "attributes": {"whatsNew": args.text}}})
            print(f"Updated What's New for build {BUILD_ID}")
        else:
            data = api(token, "POST", "/betaBuildLocalizations",
                       {"data": {"type": "betaBuildLocalizations",
                                 "attributes": {"whatsNew": args.text},
                                 "relationships": {"build": {"data": {"id": BUILD_ID, "type": "builds"}}}}})
            print("Created beta build localization", data.get("data", {}).get("id"))


if __name__ == "__main__":
    main()