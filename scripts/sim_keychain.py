"""Reads one network's credentials for the probes' --simulator mode from the booted simulator.

Accounts come from the app's `accounts.entries` preference (each account's id is its credential item's
name). Credentials are read from the simulator keychain with scripts/sim-keychain-read.swift, built for the
simulator and ad-hoc signed with the app group into logs/, or from the UserDefaults fallback the app writes
only when a keychain write fails. Dependency-free apart from Xcode's command line tools.
"""

from __future__ import annotations

import json
import plistlib
import subprocess
from pathlib import Path
from typing import Any

BUNDLE_ID = "tech.stupid.StupidSocial"
APP_GROUP = "group.tech.stupid.StupidSocial"
SCRIPTS = Path(__file__).resolve().parent
HELPER_SOURCE = SCRIPTS / "sim-keychain-read.swift"
HELPER_BINARY = SCRIPTS.parent / "logs" / "sim-keychain-read"
ENTITLEMENTS = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>{APP_GROUP}</string></array>
</dict></plist>
"""


def load_credentials(network: str, account_id: str | None = None) -> dict[str, Any]:
    """The credentials JSON of the simulator's `network` account, or of `account_id` when several exist."""
    prefs = _preferences()
    account_id = account_id or _single_account_id(prefs, network)
    data = _keychain_item(account_id)
    if data is None:
        data = prefs.get(f"{BUNDLE_ID}.credentials.{account_id}.localFallback")
    if data is None:
        raise SystemExit(f"No credentials for account '{account_id}' in the booted simulator.")
    return json.loads(data)


def _preferences() -> dict[str, Any]:
    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", "booted", BUNDLE_ID, "data"], text=True
    ).strip()
    with open(Path(container) / "Library/Preferences" / f"{BUNDLE_ID}.plist", "rb") as handle:
        return plistlib.load(handle)


def _single_account_id(prefs: dict[str, Any], network: str) -> str:
    raw = prefs.get("accounts.entries")
    entries = json.loads(raw) if raw else {}
    ids = sorted(
        entry["account"]["id"]
        for entry in entries.values()
        if not entry.get("removed") and entry.get("account", {}).get("network") == network
    )
    if not ids:
        raise SystemExit(f"No {network} account in the booted simulator. Add one in the app first.")
    if len(ids) > 1:
        raise SystemExit(f"Several {network} accounts; pass --account-id ({', '.join(ids)}).")
    return ids[0]


def _keychain_item(account: str) -> bytes | None:
    result = subprocess.run(
        ["xcrun", "simctl", "spawn", "booted", str(_helper()), account], capture_output=True
    )
    if result.returncode == 2:
        return None
    if result.returncode != 0:
        raise SystemExit(f"Reading the simulator keychain failed: {result.stderr.decode().strip()}")
    return result.stdout


def _helper() -> Path:
    """Builds and signs the keychain reader when it's missing or older than its source."""
    if HELPER_BINARY.exists() and HELPER_BINARY.stat().st_mtime >= HELPER_SOURCE.stat().st_mtime:
        return HELPER_BINARY
    HELPER_BINARY.parent.mkdir(exist_ok=True)
    entitlements = HELPER_BINARY.with_suffix(".entitlements")
    entitlements.write_text(ENTITLEMENTS)
    subprocess.run(
        [
            "xcrun", "-sdk", "iphonesimulator", "swiftc", "-target", "arm64-apple-ios17.0-simulator",
            str(HELPER_SOURCE), "-o", str(HELPER_BINARY),
        ],
        check=True,
    )
    subprocess.run(
        ["codesign", "-f", "-s", "-", "--entitlements", str(entitlements), str(HELPER_BINARY)],
        check=True,
        capture_output=True,
    )
    return HELPER_BINARY
