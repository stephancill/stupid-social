#!/usr/bin/env python3
"""Write Sources/StupidSocialCore/Resources/WhatsAppTokens.json from whatsmeow's token lists.

WhatsApp's binary XML encodes common strings as one- or two-byte tokens. The lists come from
third-party/whatsmeow/binary/token/token.go (clone https://github.com/tulir/whatsmeow there). The
Swift client and scripts/whatsapp-client.py both read the JSON, so a dictionary update is
regenerating the file.
"""

import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "third-party", "whatsmeow", "binary", "token", "token.go")
OUTPUT = os.path.join(ROOT, "Sources", "StupidSocialCore", "Resources", "WhatsAppTokens.json")


def string_list(body: str) -> list[str]:
    return [json.loads(f'"{item}"') for item in re.findall(r'"((?:[^"\\]|\\.)*)"', body)]


def main() -> None:
    with open(SOURCE) as file:
        source = file.read()
    version = int(re.search(r"const DictVersion = (\d+)", source).group(1))
    single = re.search(r"SingleByteTokens = \[\.\.\.\]string\{(.*?)\}\n", source, re.S).group(1)
    double = re.search(r"DoubleByteTokens = \[\.\.\.\]\[\]string\{(.*?)\n\}", source, re.S).group(1)
    dictionaries = [string_list(body) for body in re.findall(r"\{(.*?)\}", double, re.S)]
    tokens = {"dictVersion": version, "single": string_list(single), "double": dictionaries}
    with open(OUTPUT, "w") as file:
        json.dump(tokens, file, ensure_ascii=False, separators=(",", ":"))
        file.write("\n")
    print(f"dict v{version}: {len(tokens['single'])} single, {[len(d) for d in dictionaries]} double → {OUTPUT}")


if __name__ == "__main__":
    main()
