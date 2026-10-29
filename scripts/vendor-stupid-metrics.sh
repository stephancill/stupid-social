#!/bin/bash
# Vendors the StupidMetrics Swift package (github.com/stephancill/stupid-metrics, private) into
# Vendor/StupidMetrics at a release tag. stupid-app builds only local sources, not remote package products,
# so the sources are copied rather than resolved by SwiftPM.
set -euo pipefail

TAG="${1:-v0.2.1}"
REPO="git@github.com:stephancill/stupid-metrics.git"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/StupidMetrics"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO" "$WORK/repo"
commit="$(git -C "$WORK/repo" rev-parse HEAD)"

rm -rf "$OUT"
mkdir -p "$OUT/Sources"
cp -R "$WORK/repo/swift/Sources/StupidMetrics" "$OUT/Sources/StupidMetrics"
printf '%s %s\n' "$TAG" "$commit" > "$OUT/VERSION"
echo "Vendored StupidMetrics $TAG ($commit)"
