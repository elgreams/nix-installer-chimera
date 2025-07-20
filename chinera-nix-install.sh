#!/bin/sh

set -eu

oops() {
    echo "$0:" "$@" >&2
    exit 1
}

require_util() {
    command -v "$1" >/dev/null 2>&1 ||
        oops "you do not have '$1' installed, which I need to $2"
}

require_util tar "unpack the binary tarball"
require_util xz "unpack the binary tarball"
require_util curl "download the binary tarball"

VERSION="2.30.1"
ARCH="x86_64-linux"
TARBALL="nix-${VERSION}-${ARCH}.tar.xz"
URL="https://releases.nixos.org/nix/nix-${VERSION}/${TARBALL}"

TMPDIR="$(mktemp -d -t nix-chimera.XXXXXXXXXX)"
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT INT QUIT TERM

echo "Downloading Nix ${VERSION} binary tarball..."
curl -L --fail "$URL" -o "$TMPDIR/$TARBALL" || oops "failed to download tarball"

echo "Extracting..."
tar -xf "$TMPDIR/$TARBALL" -C "$TMPDIR"

NIXDIR="$TMPDIR/nix-${VERSION}-${ARCH}"

# Fetch patched scripts from GitHub
echo "Fetching Chimera-modified install scripts..."
curl -L --fail -o "$NIXDIR/install" https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install
curl -L --fail -o "$NIXDIR/install-multi-user" https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install-multi-user
chmod +x "$NIXDIR/install" "$NIXDIR/install-multi-user"

echo "Which installation mode do you want?"
echo "1) Multi-user (recommended)"
echo "2) Single-user (not tested)"
printf "Select 1 or 2: "
read -r choice

case "$choice" in
    1)
        "$NIXDIR/install-multi-user"
        ;;
    2)
        "$NIXDIR/install"
        ;;
    *)
        oops "Invalid choice."
        ;;
esac
