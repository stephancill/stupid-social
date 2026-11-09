#!/usr/bin/env python3
"""Probe the Hypersnap Farcaster API the app reads from (https://haatz.quilibrium.com).

Hypersnap needs no credentials. Commands print summaries (types, hashes, fids), not cast text,
unless --show-text is given; --output saves the raw response for fixtures.

  scripts/farcaster-client.py notifications --fid 194 [--quotes]
  scripts/farcaster-client.py cast --hash <hash>
  scripts/farcaster-client.py thread --hash <hash>
"""

from __future__ import annotations

import argparse
import collections
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE_URL = "https://haatz.quilibrium.com"
# The app walks at most this many parents when loading a thread.
MAX_THREAD_DEPTH = 20


def get(path: str, params: dict[str, str]) -> Any:
    url = f"{BASE_URL}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        # Cast text can hold raw control characters, which strict JSON parsing rejects.
        return json.loads(response.read(), strict=False)


def save(output: str | None, value: Any) -> None:
    if output:
        Path(output).write_text(json.dumps(value, indent=1))
        print(f"saved {output}")


def describe_cast(cast: dict[str, Any], show_text: bool) -> str:
    parts = [
        f"hash={cast['hash'][:10]}",
        f"author={cast.get('author', {}).get('fid')}",
        f"parent={(cast.get('parent_hash') or '-')[:10]}",
        f"parent_author={(cast.get('parent_author') or {}).get('fid')}",
        f"mentions={[p.get('fid') for p in cast.get('mentioned_profiles') or []]}",
    ]
    quoted = [e["cast_id"] for e in cast.get("embeds") or [] if "cast_id" in e]
    if quoted:
        parts.append(f"quotes={[(q['fid'], q['hash'][:10]) for q in quoted]}")
    if show_text:
        parts.append(f"text={cast.get('text')!r}")
    return " ".join(parts)


def notifications(args: argparse.Namespace) -> None:
    params = {"fid": str(args.fid), "limit": str(args.limit)}
    # Without this flag Hypersnap leaves out quotes, recasts and replies deeper than the user's own casts
    # (observed 2026-11-09).
    if args.quotes:
        params["include_quotes_and_deep_replies"] = "true"
    response = get("/v2/farcaster/notifications", params)
    save(args.output, response)
    items = response["notifications"]
    print(collections.Counter(n["type"] for n in items))
    for item in items:
        if item["type"] in ("likes", "follows"):
            continue
        cast = item.get("cast")
        line = f"{item['type']:8} user={(item.get('user') or {}).get('fid')}"
        if cast:
            line += " " + describe_cast(cast, args.show_text)
        print(line)


def fetch_cast(cast_hash: str) -> dict[str, Any]:
    return get("/v2/farcaster/cast", {"identifier": cast_hash, "type": "hash"})["cast"]


def cast(args: argparse.Namespace) -> None:
    value = fetch_cast(args.hash)
    save(args.output, value)
    print(describe_cast(value, args.show_text))


def thread(args: argparse.Namespace) -> None:
    """Walks parent_hash up from a cast: Hypersnap's /cast/conversation returns no ancestors (observed 2026-11-09)."""
    started = time.monotonic()
    chain = [fetch_cast(args.hash)]
    while chain[-1].get("parent_hash") and len(chain) <= MAX_THREAD_DEPTH:
        chain.append(fetch_cast(chain[-1]["parent_hash"]))
    elapsed = time.monotonic() - started
    save(args.output, list(reversed(chain)))
    for depth, value in enumerate(reversed(chain)):
        print(f"{depth:2} {describe_cast(value, args.show_text)}")
    print(f"{len(chain)} casts in {elapsed:.2f}s")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--show-text", action="store_true", help="print cast text")
    parser.add_argument("--output", help="save the raw response as JSON")
    commands = parser.add_subparsers(dest="command", required=True)

    notifications_parser = commands.add_parser("notifications", help="GET /v2/farcaster/notifications")
    notifications_parser.add_argument("--fid", type=int, required=True)
    notifications_parser.add_argument("--limit", type=int, default=50)
    notifications_parser.add_argument("--quotes", action="store_true", help="include_quotes_and_deep_replies=true")
    notifications_parser.set_defaults(run=notifications)

    cast_parser = commands.add_parser("cast", help="GET /v2/farcaster/cast")
    cast_parser.add_argument("--hash", required=True)
    cast_parser.set_defaults(run=cast)

    thread_parser = commands.add_parser("thread", help="a cast and every cast above it")
    thread_parser.add_argument("--hash", required=True)
    thread_parser.set_defaults(run=thread)

    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
