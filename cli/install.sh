#!/bin/sh
# Installs the stupid-social CLI from its GitHub release into ~/.local/bin.
#   curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-social/main/cli/install.sh | sh
# STUPID_SOCIAL_VERSION picks a version (default: the latest cli-v* release); STUPID_SOCIAL_INSTALL_DIR the directory.
set -eu

repo=stephancill/stupid-social
asset=stupid-social-macos-arm64.tar.gz
dir=${STUPID_SOCIAL_INSTALL_DIR:-$HOME/.local/bin}

fail() {
    echo "error: $*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "stupid-social runs on Apple silicon Macs only"

if [ -n "${STUPID_SOCIAL_VERSION:-}" ]; then
    tag="cli-v$STUPID_SOCIAL_VERSION"
else
    # Newest first; the repo's other releases aren't the CLI's.
    tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=100" |
        grep -o '"tag_name": *"cli-v[^"]*"' | head -n 1 | sed 's/.*"\(cli-v[^"]*\)"$/\1/') ||
        fail "couldn't list releases of $repo"
    [ -n "$tag" ] || fail "no cli-v* release in $repo"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base="https://github.com/$repo/releases/download/$tag"
curl -fsSL -o "$work/$asset" "$base/$asset" || fail "couldn't download $base/$asset"
curl -fsSL -o "$work/$asset.sha256" "$base/$asset.sha256" || fail "couldn't download $base/$asset.sha256"
(cd "$work" && shasum -a 256 -c "$asset.sha256" >/dev/null) || fail "checksum mismatch for $asset"
tar -xzf "$work/$asset" -C "$work"

mkdir -p "$dir"
install -m 0755 "$work/stupid-social" "$dir/stupid-social"
echo "Installed stupid-social $("$dir/stupid-social" --version) to $dir/stupid-social"
case ":$PATH:" in
*":$dir:"*) ;;
*) echo "note: $dir isn't on PATH; run $dir/stupid-social or add it to PATH" ;;
esac
