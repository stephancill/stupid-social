#!/usr/bin/env python3
"""Import test sessions directly into a debuggable Android app without logging secrets."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', default='6552DF1D-95CE-48E3-801F-8F80F0AA8D29')
parser.add_argument('--serial', default='emulator-5554')
parser.add_argument('--container', type=Path, help='Existing simulator app data directory, including when shut down')
args = parser.parse_args()
container = args.container
if container is None:
    container = Path(subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', args.simulator, 'tech.stupid.StupidSocial', 'data'],
        check=True, capture_output=True, text=True,
    ).stdout.strip())
with (container / 'Library/Preferences/tech.stupid.StupidSocial.plist').open('rb') as handle:
    preferences = plistlib.load(handle)
selected = {}
# Bluesky requires a separate device-bound OAuth session and is not copied.
for provider in ('x', 'instagram', 'github', 'spotify'):
    raw = preferences.get(f'tech.stupid.StupidSocial.credentials.{provider}.localFallback')
    if raw:
        credentials = json.loads(raw)
        selected[provider] = {key: value for key, value in credentials.items() if isinstance(value, str)}
if not selected:
    raise SystemExit('No simulator fallback sessions available. Use Android login instead.')
subprocess.run(
    ['adb', '-s', args.serial, 'shell', "run-as net.stupidtech.socialvalidation sh -c 'mkdir -p files && cat > files/validation-seed.json && chmod 600 files/validation-seed.json'"],
    input=json.dumps(selected).encode(), check=True, capture_output=True,
)
print(f'Transferred {len(selected)} test sessions privately. Relaunch the Android app to import them.')
