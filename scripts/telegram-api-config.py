#!/usr/bin/env python3
"""Writes Sources/NoFeedSocialCore/Resources/TelegramAPI.json (gitignored) from TELEGRAM_APP_ID and
TELEGRAM_APP_API_HASH in the environment or .env.local, so the build can sign in to Telegram.

Get both from https://my.telegram.org → API development tools. Builds without the file show Telegram as
unavailable.
"""

import json
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/NoFeedSocialCore/Resources/TelegramAPI.json"

env = dict(os.environ)
local = ROOT / ".env.local"
if local.exists():
    for line in local.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env.setdefault(key.strip(), value.strip().strip("'\""))
if "TELEGRAM_APP_ID" not in env or "TELEGRAM_APP_API_HASH" not in env:
    raise SystemExit("Set TELEGRAM_APP_ID and TELEGRAM_APP_API_HASH in the environment or .env.local")
OUTPUT.write_text(json.dumps({"apiId": int(env["TELEGRAM_APP_ID"]), "apiHash": env["TELEGRAM_APP_API_HASH"]}) + "\n")
print(f"Wrote {OUTPUT.relative_to(ROOT)}")
