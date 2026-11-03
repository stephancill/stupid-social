#!/bin/sh
# Compares the app's WebM sticker decoder (Sources/StupidSocialCore/Stickers/WebMSticker.swift) with ffmpeg's
# libvpx-vp9 decode, alpha included, on the first, middle and last frame of each file.
#
#   scripts/webm-compare.sh logs/sticker-corpus-webm/*.webm
#
# The corpus comes from `scripts/telegram-client.py sticker-corpus --format webm`. Needs ffmpeg and ImageMagick.
set -eu
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS="$ROOT/logs/lottie-tools"
OUT="$ROOT/logs/webm-compare"
mkdir -p "$TOOLS/webm" "$OUT"
cp "$ROOT/scripts/stickers/webm.swift" "$TOOLS/webm/main.swift"
xcrun swiftc -O -o "$TOOLS/webm-decode" "$ROOT/Sources/StupidSocialCore/Stickers/WebMSticker.swift" "$TOOLS/webm/main.swift"
failed=0
for file in "$@"; do
    name=$(basename "$file" .webm)
    dir="$OUT/$name"
    rm -rf "$dir" && mkdir -p "$dir"
    count=$("$TOOLS/webm-decode" "$file" "$dir" 0 | sed 's/ frames.*//')
    last=$((count - 1))
    middle=$((count / 2))
    "$TOOLS/webm-decode" "$file" "$dir" 0 "$middle" "$last" > /dev/null
    for frame in 0 "$middle" "$last"; do
        ffmpeg -v error -c:v libvpx-vp9 -i "$file" -vf "select=eq(n\,$frame)" -frames:v 1 -pix_fmt rgba "$dir/$frame-ref.png"
        differing=$(magick compare -metric AE -fuzz 6% "$dir/$frame-ref.png" "$dir/$frame.png" "$dir/$frame-diff.png" 2>&1 >/dev/null | cut -d' ' -f1 || true)
        percent=$(echo "$differing" | awk '{printf "%.2f", $1 * 100 / (512 * 512)}')
        echo "$name frame $frame: $percent% differ"
        if awk "BEGIN {exit !($percent > 1)}"; then failed=$((failed + 1)); fi
    done
done
echo "$failed frames over 1%"
