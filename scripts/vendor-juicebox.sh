#!/bin/bash
# Vendors the Juicebox SDK (https://github.com/juicebox-systems/juicebox-sdk, MIT) into Vendor/JuiceboxSdk:
# the Swift wrapper sources, and an XCFramework of the prebuilt Rust FFI library for iOS devices and arm64
# simulators. The libraries come from juicebox-sdk-artifacts at the commit the SDK tag pins, are checked
# against that commit's checksums.txt, and are stripped of debug info (58 MB to about 5 MB each).
#
# XChat stores each user's private keys in Juicebox realms; the app recovers them once with the XChat PIN.
set -euo pipefail

TAG="0.3.7"
ARTIFACTS_COMMIT="49b2860fe1617cbc597bdffb3a2dbea7279afdd5" # the artifacts submodule at $TAG
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/JuiceboxSdk"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sdk="https://raw.githubusercontent.com/juicebox-systems/juicebox-sdk/$TAG"
artifacts="https://raw.githubusercontent.com/juicebox-systems/juicebox-sdk-artifacts/$ARTIFACTS_COMMIT"

curl -fsSL "$artifacts/checksums.txt" -o "$WORK/checksums.txt"

mkdir -p "$WORK/headers"
curl -fsSL "$sdk/swift/Sources/JuiceboxSdkFfi/juicebox-sdk-ffi.h" -o "$WORK/headers/juicebox-sdk-ffi.h"
curl -fsSL "$sdk/swift/Sources/JuiceboxSdkFfi/module.modulemap" -o "$WORK/headers/module.modulemap"

libraries=()
for target in "${TARGETS[@]}"; do
  mkdir -p "$WORK/$target"
  library="$WORK/$target/libjuicebox_sdk_ffi.a"
  curl -fsSL "$artifacts/ffi/$target/libjuicebox_sdk_ffi.a" -o "$library"
  expected="$(awk -v path="artifacts/ffi/$target/libjuicebox_sdk_ffi.a" '$2 == path { print $1 }' "$WORK/checksums.txt")"
  actual="$(shasum -a 256 "$library" | awk '{ print $1 }')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch for $target: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  strip -S -x "$library"
  libraries+=(-library "$library" -headers "$WORK/headers")
done

rm -rf "$OUT"
mkdir -p "$OUT/Sources/JuiceboxSdk"
xcodebuild -create-xcframework "${libraries[@]}" -output "$OUT/JuiceboxSdkFfi.xcframework" >/dev/null

for file in AuthToken AuthTokenGenerator Client Configuration Errors Extensions Identifable RealmId SecretId; do
  curl -fsSL "$sdk/swift/Sources/JuiceboxSdk/$file.swift" -o "$OUT/Sources/JuiceboxSdk/$file.swift"
done
curl -fsSL "$sdk/LICENSE" -o "$OUT/LICENSE"
printf 'Juicebox SDK %s, vendored by scripts/vendor-juicebox.sh. Do not edit; re-run the script.\n' "$TAG" >"$OUT/README.md"

du -sh "$OUT"
