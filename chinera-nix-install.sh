#!/bin/sh
# Old entry point, kept so existing links keep working. Use install.sh instead:
#   curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh | sh
{
set -eu
echo "note: chinera-nix-install.sh has been replaced by install.sh; running that instead" >&2
tmp="$(mktemp "${TMPDIR:-/tmp}/nix-chimera-install.XXXXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh -o "$tmp"
sh "$tmp" "$@"
}
