#!/bin/sh
# Install (or uninstall) the Nix package manager on Chimera Linux.
#
# This downloads the official Nix binary tarball, verifies its checksum,
# swaps the GNU-only commands in the official installer for ones Chimera's
# FreeBSD-derived coreutils understand (see patch_official_installer), runs
# it, and then sets up a dinit service for the multi-user nix-daemon.
#
# Run `sh install.sh --help` for options.

{ # Braces make the shell read the whole file before running any of it, so a
  # truncated download can't execute half a script.

set -eu

if [ -n "${NIX_DEBUG:-}" ]; then
    set -x
fi

readonly REPO_URL="https://github.com/elgreams/nix-installer-chimera"
readonly SCRIPT_URL="https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh"
readonly RELEASES_URL="https://releases.nixos.org/nix"
readonly UPSTREAM_INSTALLER_URL="https://nixos.org/nix/install"
# Used only when the latest release can't be read from nixos.org.
readonly FALLBACK_NIX_VERSION="2.35.3"

readonly MARKER="Managed by nix-installer-chimera"
readonly DINIT_SERVICE="/etc/dinit.d/nix-daemon"
readonly DINIT_BOOT_LINK="/etc/dinit.d/boot.d/nix-daemon"
readonly BASH_DROPIN="/etc/bash/bashrc.d/nix.sh"
readonly NIX_PROFILE_BIN="/nix/var/nix/profiles/default/bin"
readonly NIX_DAEMON_PROFILE_SH="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

# Files the official multi-user installer edits, and its backup suffix.
readonly SYSTEM_PROFILE_TARGETS="/etc/bashrc /etc/profile.d/nix.sh /etc/zshrc /etc/bash.bashrc /etc/zsh/zshrc"
readonly SYSTEM_FISH_TARGETS="/etc/fish/conf.d/nix.fish /usr/local/etc/fish/conf.d/nix.fish"
readonly BACKUP_SUFFIX=".backup-before-nix"
# Files the official single-user installer edits in $HOME.
readonly USER_PROFILE_TARGETS=".bash_profile .bash_login .profile .zshenv .zshrc"

if [ -t 2 ]; then
    C_BOLD="$(printf '\033[1m')"
    C_BLUE="$(printf '\033[1;34m')"
    C_YELLOW="$(printf '\033[1;33m')"
    C_RED="$(printf '\033[1;31m')"
    C_RESET="$(printf '\033[0m')"
else
    C_BOLD="" C_BLUE="" C_YELLOW="" C_RED="" C_RESET=""
fi

info() { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Install the Nix package manager on Chimera Linux.

Usage: sh install.sh [options] [official installer options]

Options:
  --daemon              Multi-user install with a dinit-managed nix-daemon
                        (recommended; the default when there is no terminal).
  --no-daemon           Single-user install owned by the current user.
  --yes                 Don't ask questions; accept all defaults.
  --nix-version VER     Install Nix VER instead of the latest release.
  --no-dinit            Don't create or enable the dinit service.
  --uninstall           Remove Nix (either install mode) from this system.
  -h, --help            Show this help.

Anything else is passed to the official installer, e.g.:
  --no-channel-add            Don't subscribe to nixpkgs-unstable.
  --no-modify-profile         Don't edit shell profiles.
  --daemon-user-count N       Number of build users to create (default 32).
  --nix-extra-conf-file FILE  Prepend FILE to /etc/nix/nix.conf.

Environment:
  NIX_BECOME            Command used to gain root (default: doas, else sudo).
  NIX_DEBUG             Set to trace this script.

Examples:
  curl -fsSL $SCRIPT_URL | sh
  curl -fsSL $SCRIPT_URL | sh -s -- --daemon --yes
  curl -fsSL $SCRIPT_URL | sh -s -- --uninstall
EOF
}

# True if we can prompt the user, even when the script itself is piped in.
have_tty() {
    [ -t 0 ] || ( : </dev/tty ) 2>/dev/null
}

prompt() {
    printf '%s' "$1" >&2
    if [ -t 0 ]; then
        read -r REPLY || REPLY=""
    else
        read -r REPLY </dev/tty || REPLY=""
    fi
}

confirm() {
    if [ -n "${NIX_INSTALLER_YES:-}" ]; then
        return 0
    fi
    have_tty || die "no terminal to ask for confirmation; re-run with --yes"
    prompt "$1 [y/N] "
    case "$REPLY" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        # shellcheck disable=SC2086 # NIX_BECOME may contain arguments
        $NIX_BECOME "$@"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require() {
    have "$1" || die "'$1' is needed to $2. Install it with: ${NIX_BECOME:-doas} apk add $3"
}

pick_become() {
    if [ "$(id -u)" -eq 0 ]; then
        # The official installer still invokes $NIX_BECOME in a few places.
        NIX_BECOME="${NIX_BECOME:-env}"
    elif [ -z "${NIX_BECOME:-}" ]; then
        if have doas; then
            NIX_BECOME=doas
        elif have sudo; then
            NIX_BECOME=sudo
        else
            die "neither doas nor sudo was found; install opendoas or run this as root"
        fi
    fi
    export NIX_BECOME
}

# Ask for the password once up front instead of mid-install. Chimera's default
# doas.conf uses `persist`, so later calls won't prompt again.
authenticate() {
    if [ "$(id -u)" -ne 0 ]; then
        info "Root access is needed; authenticating with $NIX_BECOME"
        if ! as_root true; then
            die "'$NIX_BECOME' failed. On Chimera, your user needs to be in the 'wheel' group (doas usermod -aG wheel $(id -un)) and you need to log in again."
        fi
    fi
}

download() {
    # $1 = url, $2 = destination, $3 = "progress" to show a progress bar
    if have curl; then
        if [ "${3:-}" = progress ] && [ -t 2 ]; then
            set -- "$1" "$2" --progress-bar
        else
            set -- "$1" "$2" --silent
        fi
        curl --fail --location --proto '=https' --tlsv1.2 --show-error "$3" --output "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d ' ' -f 1
    elif have sha256; then
        sha256 -q "$1"
    else
        openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1
    fi
}

valid_version() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

detect_system() {
    [ "$(uname -s)" = Linux ] || die "this installer is for Chimera Linux; on $(uname -s) use the official installer"

    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) NIX_SYSTEM=x86_64-linux ;;
        aarch64|arm64) NIX_SYSTEM=aarch64-linux ;;
        riscv64) NIX_SYSTEM=riscv64-linux ;;
        armv7l|armv7*) NIX_SYSTEM=armv7l-linux ;;
        armv6l) NIX_SYSTEM=armv6l-linux ;;
        i?86) NIX_SYSTEM=i686-linux ;;
        *) die "Nix doesn't publish binaries for '$machine' (supported: x86_64, aarch64, riscv64, armv7l, armv6l, i686)" ;;
    esac

    if [ -r /etc/os-release ] && ! grep -q '^ID="\{0,1\}chimera"\{0,1\}$' /etc/os-release; then
        warn "this doesn't look like Chimera Linux; continuing anyway"
    fi
}

resolve_version() {
    if [ -n "$NIX_VERSION" ]; then
        valid_version "$NIX_VERSION" || die "'$NIX_VERSION' isn't a valid Nix version (expected e.g. 2.35.3)"
        return
    fi

    info "Looking up the latest Nix release"
    if download "$UPSTREAM_INSTALLER_URL" "$WORKDIR/upstream-install" 2>/dev/null; then
        NIX_VERSION="$(sed -n 's|.*releases\.nixos\.org/nix/nix-\([0-9][0-9.]*[0-9]\)/.*|\1|p' "$WORKDIR/upstream-install" | head -n 1)"
    fi
    if ! valid_version "${NIX_VERSION:-}"; then
        NIX_VERSION="$FALLBACK_NIX_VERSION"
        warn "couldn't determine the latest Nix release; using $NIX_VERSION (pass --nix-version to choose)"
    fi
}

fetch_and_unpack() {
    name="nix-$NIX_VERSION-$NIX_SYSTEM"
    url="$RELEASES_URL/nix-$NIX_VERSION/$name.tar.xz"
    tarball="$WORKDIR/$name.tar.xz"

    info "Downloading Nix $NIX_VERSION for $NIX_SYSTEM"
    download "$url.sha256" "$WORKDIR/expected.sha256" ||
        die "couldn't download $url.sha256 -- is '$NIX_VERSION' a real Nix release?"
    download "$url" "$tarball" progress || die "couldn't download $url"

    expected="$(cut -d ' ' -f 1 "$WORKDIR/expected.sha256" | head -n 1)"
    case "$expected" in
        *[!0-9a-f]*|'') die "unexpected checksum file contents from $url.sha256" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "unexpected checksum file contents from $url.sha256"
    actual="$(sha256_of "$tarball")"
    [ "$actual" = "$expected" ] || die "checksum mismatch for $name.tar.xz (expected $expected, got $actual)"
    note "sha256 verified: $actual"

    info "Unpacking"
    tar -xf "$tarball" -C "$WORKDIR" ||
        die "couldn't unpack $tarball (on Chimera, tar comes from: apk add libarchive-progs)"
    rm -f "$tarball"
    UNPACKED="$WORKDIR/$name"
    [ -x "$UNPACKED/install" ] || die "the tarball doesn't contain an installer at $name/install"
}

# Replace the GNU coreutils-only commands in the official installer with
# equivalents Chimera's FreeBSD-derived tools understand:
#   cp -RP --preserve=ownership,timestamps  ->  cp -RPp  (what upstream uses on
#                                               macOS/FreeBSD)
#   touch -hmd "@1"                         ->  touch -hmd 1970-01-01T00:00:01Z
#                                               (Nix >= 2.35.3; "@epoch" is a
#                                               GNU date extension)
patch_official_installer() {
    info "Adapting the official installer for Chimera"
    for script in "$UNPACKED/install" "$UNPACKED/install-multi-user"; do
        [ -f "$script" ] || die "the tarball is missing ${script##*/}; the official installer has changed, please report this at $REPO_URL/issues"
        sed -e 's/cp -RP --preserve=ownership,timestamps /cp -RPp /' \
            -e 's/touch -hmd "@1"/touch -hmd 1970-01-01T00:00:01Z/' \
            "$script" >"$script.new"
        # Write back through cat so the file keeps its executable bit.
        cat "$script.new" >"$script"
        rm -f "$script.new"
        if grep -n -e '--preserve' -e 'touch .*"@' "$script" >&2; then
            die "${script##*/} uses a GNU-only command this script doesn't know how to adapt; the official installer has changed, please report this at $REPO_URL/issues (or pass --nix-version with an older release)"
        fi
    done
}

# The single-user installer only hooks shell startup files that already exist,
# and new Chimera accounts start with an empty home directory. Create
# ~/.profile (read by Chimera's default login shell) so Nix ends up on PATH.
ensure_user_profile() {
    for arg in "$@"; do
        [ "$arg" = --no-modify-profile ] && return 0
    done
    for name in .bash_profile .bash_login .profile; do
        [ -e "$HOME/$name" ] && return 0
    done
    : >>"$HOME/.profile"
}

run_official_installer() {
    if [ "$MODE" = daemon ]; then
        set -- --daemon "$@"
    else
        ensure_user_profile "$@"
        set -- --no-daemon "$@"
    fi

    info "Running the official Nix installer"
    # When this script is piped into sh, stdin is the pipe; give the official
    # installer the terminal so its prompts work.
    if [ ! -t 0 ] && [ -z "${NIX_INSTALLER_YES:-}" ] && have_tty; then
        "$UNPACKED/install" "$@" </dev/tty
    else
        "$UNPACKED/install" "$@"
    fi
}

# Before Nix 2.35.3, the official multi-user installer copied the store as root
# while preserving ownership, so the initial store paths ended up owned by
# whoever unpacked the tarball -- who could then modify binaries the root
# daemon runs. Newer installers chown them; this covers older --nix-version
# picks and is a no-op otherwise.
fix_store_ownership() {
    set --
    for path in "$UNPACKED"/store/*; do
        set -- "$@" "/nix/store/${path##*/}"
    done
    as_root chown -Rh 0:0 "$@"
}

write_root_file() {
    # $1 = destination; contents on stdin
    cat >"$WORKDIR/root-file"
    as_root install -m 0644 "$WORKDIR/root-file" "$1"
}

# Chimera's bash reads /etc/bash/bashrc.d/*.sh in interactive non-login shells
# (the equivalent of /etc/bash.bashrc, which the official installer targets on
# other distros). Login shells already get Nix via /etc/profile.d/nix.sh.
install_bash_dropin() {
    [ -d "${BASH_DROPIN%/*}" ] || return 0
    write_root_file "$BASH_DROPIN" <<EOF
# $MARKER: loads Nix in interactive bash shells.
if [ -e '$NIX_DAEMON_PROFILE_SH' ]; then
  . '$NIX_DAEMON_PROFILE_SH'
fi
EOF
}

dinit_reachable() {
    have dinitctl && as_root dinitctl list >/dev/null 2>&1
}

# A service file we may manage: ours, or one written from this project's old
# README (which had no marker but ran the same binary).
is_nix_dinit_service() {
    [ -f "$DINIT_SERVICE" ] && grep -q -e "$MARKER" -e "$NIX_PROFILE_BIN/nix-daemon" "$DINIT_SERVICE"
}

wait_for_daemon() {
    profile="$(readlink -f /nix/var/nix/profiles/default)"
    tries=0
    while [ "$tries" -lt 15 ]; do
        if "$NIX_PROFILE_BIN/nix-store" --store daemon --query --hash "$profile" >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 1
    done
    return 1
}

setup_dinit_service() {
    if [ -n "$NO_DINIT" ]; then
        info "Skipping dinit setup (--no-dinit)"
        note "Start $NIX_PROFILE_BIN/nix-daemon as root to use Nix."
        return
    fi
    if ! have dinitctl || [ ! -d /etc/dinit.d ]; then
        warn "dinit wasn't found; configure your init system to run '$NIX_PROFILE_BIN/nix-daemon --daemon' as root"
        return
    fi
    if [ -e "$DINIT_SERVICE" ] && ! is_nix_dinit_service; then
        warn "$DINIT_SERVICE already exists and wasn't created by this installer; leaving it alone"
        return
    fi

    info "Setting up the nix-daemon dinit service"
    write_root_file "$DINIT_SERVICE" <<EOF
# $MARKER.
# Remove with: sh install.sh --uninstall
type = process
command = $NIX_PROFILE_BIN/nix-daemon --daemon
smooth-recovery = true
depends-on: local.target
log-type = buffer
# Matches LimitNOFILE in the official systemd unit; large builds need it.
rlimit-nofile = 1048576
EOF

    if dinit_reachable; then
        # If an older definition is loaded (e.g. from the old README), make
        # dinit re-read the file before starting.
        as_root dinitctl stop nix-daemon >/dev/null 2>&1 || true
        as_root dinitctl reload nix-daemon >/dev/null 2>&1 || true
        if [ -e "$DINIT_BOOT_LINK" ] || [ -L "$DINIT_BOOT_LINK" ]; then
            as_root dinitctl start nix-daemon
        else
            as_root dinitctl enable nix-daemon
        fi
        if wait_for_daemon; then
            note "nix-daemon is running and accepting connections."
        else
            warn "nix-daemon isn't responding; check '$NIX_BECOME dinitctl status nix-daemon' and '$NIX_BECOME dinitctl catlog nix-daemon'"
        fi
    else
        as_root mkdir -p "${DINIT_BOOT_LINK%/*}"
        as_root ln -sf ../nix-daemon "$DINIT_BOOT_LINK"
        warn "couldn't talk to dinit; nix-daemon is enabled and will start on next boot (or run: $NIX_BECOME dinitctl start nix-daemon)"
    fi
}

choose_mode() {
    if [ -n "$MODE" ]; then
        return
    fi
    if [ -n "${NIX_INSTALLER_YES:-}" ] || ! have_tty; then
        MODE=daemon
        return
    fi
    cat >&2 <<EOF

How should Nix be installed?
  1) Multi-user (recommended): a root nix-daemon builds for every user.
  2) Single-user: /nix is owned by $(id -un); no daemon.
EOF
    prompt "Choose [1/2] (default 1): "
    case "$REPLY" in
        ''|1) MODE=daemon ;;
        2) MODE=no-daemon ;;
        *) die "invalid choice '$REPLY'" ;;
    esac
}

install_nix() {
    if [ -e /nix/var/nix/db ]; then
        die "Nix is already installed (/nix/var/nix/db exists). To reinstall, first run this script with --uninstall. To upgrade, see $REPO_URL#upgrading"
    fi

    choose_mode

    require tar "unpack the Nix tarball" libarchive-progs
    if ! have curl && ! have wget; then
        die "curl is needed to download Nix. Install it with: ${NIX_BECOME:-doas} apk add curl"
    fi
    if ! have sha256sum && ! have sha256 && ! have openssl; then
        die "no SHA-256 tool (sha256sum, sha256 or openssl) was found"
    fi
    if [ "$MODE" = daemon ]; then
        require bash "run the multi-user installer" bash
        require useradd "create the Nix build users" shadow
        require groupadd "create the Nix build group" shadow
        require usermod "configure the Nix build users" shadow
        authenticate
    fi

    resolve_version
    fetch_and_unpack
    patch_official_installer
    run_official_installer "$@"

    if [ "$MODE" = daemon ]; then
        info "Making the initial store paths owned by root"
        fix_store_ownership
        install_bash_dropin
        setup_dinit_service
    fi

    cat >&2 <<EOF

${C_BOLD}Nix $NIX_VERSION is installed ($( [ "$MODE" = daemon ] && echo multi-user || echo single-user )).${C_RESET}

Open a new terminal (or log out and back in), then try:
  nix-shell -p nix-info --run "nix-info -m"
EOF
    if [ "$MODE" = daemon ] && [ -z "$NO_DINIT" ]; then
        cat >&2 <<EOF

The daemon is managed by dinit:
  $NIX_BECOME dinitctl status nix-daemon
  $NIX_BECOME dinitctl catlog nix-daemon
EOF
    fi
    cat >&2 <<EOF

To uninstall:
  curl -fsSL $SCRIPT_URL | sh -s -- --uninstall
EOF
}

# Remove the "# Nix ... # End Nix" block the multi-user installer added to a
# system file, restoring the installer's backup when nothing else changed.
restore_system_profile() {
    file="$1"
    backup="$file$BACKUP_SUFFIX"

    if [ -f "$file" ] && grep -q '^# Nix$' "$file"; then
        sed '/^# Nix$/,/^# End Nix$/d' "$file" >"$WORKDIR/stripped"
        if [ -f "$backup" ] && diff -B -q "$WORKDIR/stripped" "$backup" >/dev/null 2>&1; then
            as_root mv "$backup" "$file"
            note "restored $file"
        elif grep -q '[^[:space:]]' "$WORKDIR/stripped"; then
            # cp onto an existing file keeps its owner and mode.
            as_root cp "$WORKDIR/stripped" "$file"
            as_root rm -f "$backup"
            note "removed the Nix lines from $file"
        else
            as_root rm -f "$file" "$backup"
            note "removed $file"
        fi
    elif [ -f "$backup" ]; then
        warn "$backup exists but $file has no Nix block; leaving both for you to check"
    fi
}

remove_user_profile_lines() {
    for name in $USER_PROFILE_TARGETS; do
        file="$HOME/$name"
        if [ -f "$file" ] && grep -q '# added by Nix installer$' "$file"; then
            grep -v '# added by Nix installer$' "$file" >"$WORKDIR/stripped" || true
            cat "$WORKDIR/stripped" >"$file"
            note "removed the Nix line from $file"
        fi
    done
    fish="$HOME/.config/fish/conf.d/nix.fish"
    if [ -f "$fish" ] && grep -q 'added by Nix installer' "$fish"; then
        rm -f "$fish"
        note "removed $fish"
    fi
}

remove_build_users() {
    users="$(getent passwd | while IFS=: read -r name _ _ _ gecos _; do
        case "$name" in
            nixbld[0-9]*|_nixbld[0-9]*)
                case "$gecos" in "Nix build user"*) echo "$name" ;; esac ;;
        esac
    done)"
    if [ -n "$users" ]; then
        have userdel || die "userdel is needed to remove the Nix build users. Install it with: ${NIX_BECOME:-doas} apk add shadow"
        count=0
        for user in $users; do
            as_root userdel "$user"
            count=$((count + 1))
        done
        note "removed $count build users"
    fi
    if getent group nixbld >/dev/null 2>&1; then
        have groupdel || die "groupdel is needed to remove the nixbld group. Install it with: ${NIX_BECOME:-doas} apk add shadow"
        as_root groupdel nixbld
        note "removed group nixbld"
    fi
}

uninstall_nix() {
    if [ ! -e /nix ] && [ ! -e /etc/nix ] && [ ! -e "$DINIT_SERVICE" ] && ! getent group nixbld >/dev/null 2>&1; then
        info "Nix doesn't appear to be installed; nothing to do"
        return
    fi

    cat >&2 <<EOF
This will remove Nix from this system:
  - stop and remove the nix-daemon dinit service
  - delete /nix (every installed package), /etc/nix and Nix state in
    $ROOT_HOME and $HOME
  - remove the nixbld build users and group
  - remove the Nix lines from shell profiles
EOF
    confirm "Continue?" || die "aborted; nothing was changed"
    authenticate

    info "Stopping nix-daemon"
    if is_nix_dinit_service || [ -L "$DINIT_BOOT_LINK" ]; then
        if dinit_reachable; then
            as_root dinitctl disable nix-daemon >/dev/null 2>&1 || true
            as_root dinitctl stop nix-daemon >/dev/null 2>&1 || true
            as_root dinitctl unload nix-daemon >/dev/null 2>&1 || true
        fi
        as_root rm -f "$DINIT_BOOT_LINK"
        if is_nix_dinit_service; then
            as_root rm -f "$DINIT_SERVICE"
        fi
        note "removed the dinit service"
    elif [ -e "$DINIT_SERVICE" ]; then
        warn "leaving $DINIT_SERVICE alone; it wasn't created by this installer"
    fi
    if [ -S /nix/var/nix/daemon-socket/socket ] && ! dinit_reachable; then
        warn "a nix-daemon may still be running; reboot after uninstalling"
    fi

    info "Cleaning up shell profiles"
    for file in $SYSTEM_PROFILE_TARGETS; do
        restore_system_profile "$file"
    done
    if [ -f "$BASH_DROPIN" ] && grep -q "$MARKER" "$BASH_DROPIN"; then
        as_root rm -f "$BASH_DROPIN"
        note "removed $BASH_DROPIN"
    fi
    for file in $SYSTEM_FISH_TARGETS; do
        if [ -f "$file" ] && grep -q 'nix-daemon.fish' "$file"; then
            as_root rm -f "$file"
            note "removed $file"
        fi
    done
    remove_user_profile_lines

    info "Removing build users"
    remove_build_users

    info "Deleting Nix files"
    for home in "$ROOT_HOME" "$HOME"; do
        as_root rm -rf "$home/.nix-profile" "$home/.nix-defexpr" "$home/.nix-channels" \
            "$home/.local/state/nix" "$home/.cache/nix"
    done
    as_root rm -rf /etc/nix
    if ! as_root rm -rf /nix 2>/dev/null; then
        if [ -d /nix ] && [ -z "$(ls -A /nix)" ]; then
            warn "/nix is a mount point; its contents were deleted but the mount was left in place"
        else
            die "couldn't delete /nix"
        fi
    fi

    cat >&2 <<EOF

${C_BOLD}Nix has been uninstalled.${C_RESET}
Open a new terminal so your shell forgets the old environment. Other users
may still have dangling ~/.nix-profile and ~/.nix-defexpr links to delete.
EOF
}

# shellcheck disable=SC2317,SC2329 # invoked via trap
cleanup() {
    if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        chmod -R u+w "$WORKDIR" 2>/dev/null || true
        rm -rf "$WORKDIR"
    fi
}

main() {
    ACTION=install
    MODE=""
    NO_DINIT=""
    NIX_VERSION="${NIX_VERSION:-}"

    # Consume our own options; rotate everything else to the end of "$@" so it
    # can be passed to the official installer unchanged.
    remaining=$#
    while [ "$remaining" -gt 0 ]; do
        arg="$1"
        shift
        remaining=$((remaining - 1))
        case "$arg" in
            --daemon) MODE=daemon ;;
            --no-daemon) MODE=no-daemon ;;
            --yes) export NIX_INSTALLER_YES=1 ;;
            --no-dinit) NO_DINIT=1 ;;
            --uninstall) ACTION=uninstall ;;
            --nix-version)
                [ "$remaining" -gt 0 ] || die "--nix-version needs a value"
                NIX_VERSION="$1"
                shift
                remaining=$((remaining - 1))
                ;;
            --nix-version=*) NIX_VERSION="${arg#*=}" ;;
            -h|--help) usage; exit 0 ;;
            *) set -- "$@" "$arg" ;;
        esac
    done

    detect_system
    pick_become

    ROOT_HOME="$(getent passwd root | cut -d : -f 6)"
    ROOT_HOME="${ROOT_HOME:-/root}"
    HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d : -f 6)}"

    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/nix-chimera.XXXXXXXXXX")" ||
        die "couldn't create a temporary directory"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ "$ACTION" = uninstall ]; then
        [ $# -eq 0 ] || die "--uninstall doesn't take other options (got: $*)"
        uninstall_nix
    else
        install_nix "$@"
    fi
}

main "$@"
exit
}
