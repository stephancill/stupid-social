#!/bin/sh
# Builds the stupid-social CLI and publishes it as GitHub release cli-v<version>, the version in
# cli/Sources/stupid-social/main.swift. cli/install.sh installs the newest such release.
#   scripts/release-cli.sh 0.1.0
set -eu

fail() {
    echo "error: $*" >&2
    exit 1
}

version=${1:-}
[ -n "$version" ] || fail "usage: scripts/release-cli.sh <version>"
tag="cli-v$version"
root=$(git rev-parse --show-toplevel)
cd "$root"

grep -q "^let version = \"$version\"$" cli/Sources/stupid-social/main.swift ||
    fail "cli/Sources/stupid-social/main.swift doesn't say version $version"
git diff --quiet HEAD -- cli || fail "cli/ has uncommitted changes"
[ -z "$(git ls-files --others --exclude-standard cli)" ] || fail "cli/ has untracked files"
git merge-base --is-ancestor HEAD origin/main || fail "HEAD isn't pushed to origin/main"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"

swift build -c release --package-path cli
binary=cli/.build/release/stupid-social
[ "$(lipo -archs "$binary")" = arm64 ] || fail "expected an arm64 binary"
[ "$("$binary" --version)" = "$version" ] || fail "the built binary isn't version $version"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
asset=stupid-social-macos-arm64.tar.gz
cp "$binary" "$work/stupid-social"
tar -czf "$work/$asset" -C "$work" stupid-social
(cd "$work" && shasum -a 256 "$asset" >"$asset.sha256")

git tag -a "$tag" -m "stupid-social CLI $version"
git push origin "$tag"
gh release create "$tag" "$work/$asset" "$work/$asset.sha256" \
    --title "stupid-social CLI $version" \
    --notes "Command line for stupid social's chats on an Apple silicon Mac. Install with:

\`\`\`
curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-social/main/cli/install.sh | sh
\`\`\`

Needs a stupid social build with Settings → Command Line. See skills/stupid-social/SKILL.md."
