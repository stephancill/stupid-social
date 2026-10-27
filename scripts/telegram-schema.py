#!/usr/bin/env python3
"""Builds Sources/NoFeedSocialCore/Resources/TelegramSchema.tl from Telegram's published JSON schema.

Usage:
  python3 scripts/telegram-schema.py            # downloads https://core.telegram.org/schema/json and /mtproto-json
  python3 scripts/telegram-schema.py api.json mtproto.json

The output is plain TL, one combinator per line, with `---functions---` separating methods, and a first
line `// LAYER <n>` that the clients send in invokeWithLayer.
"""

import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/NoFeedSocialCore/Resources/TelegramSchema.tl"


def load(source: str) -> dict:
    if source.startswith("https://"):
        with urllib.request.urlopen(source) as response:
            return json.load(response)
    return json.loads(pathlib.Path(source).read_text())


def layer() -> int:
    with urllib.request.urlopen("https://core.telegram.org/schema") as response:
        html = response.read().decode()
    match = re.search(r"Layer (\d+)", html)
    if not match:
        raise SystemExit("Couldn't find the layer on core.telegram.org/schema")
    return int(match.group(1))


def line(entry: dict, name_key: str) -> str:
    combinator_id = int(entry["id"]) & 0xFFFFFFFF
    params = " ".join(f"{p['name']}:{p['type']}" for p in entry["params"])
    head = f"{entry[name_key]}#{combinator_id:08x}"
    return f"{head} {params} = {entry['type']};" if params else f"{head} = {entry['type']};"


def main() -> None:
    api_source, mtproto_source = (sys.argv[1], sys.argv[2]) if len(sys.argv) == 3 else (
        "https://core.telegram.org/schema/json",
        "https://core.telegram.org/schema/mtproto-json",
    )
    api, mtproto = load(api_source), load(mtproto_source)
    seen: set[int] = set()
    constructors, functions = [], []
    for schema in (mtproto, api):
        for entry in schema["constructors"]:
            if int(entry["id"]) & 0xFFFFFFFF in seen:
                continue
            seen.add(int(entry["id"]) & 0xFFFFFFFF)
            constructors.append(line(entry, "predicate"))
        for entry in schema["methods"]:
            if int(entry["id"]) & 0xFFFFFFFF in seen:
                continue
            seen.add(int(entry["id"]) & 0xFFFFFFFF)
            functions.append(line(entry, "method"))
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join([f"// LAYER {layer()}", *constructors, "---functions---", *functions]) + "\n")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(constructors)} constructors, {len(functions)} functions")


if __name__ == "__main__":
    main()
