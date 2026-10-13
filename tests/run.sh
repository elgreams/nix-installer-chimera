#!/bin/sh
# shellcheck disable=SC2016 # scenario bodies are expanded inside the container
# Integration tests: run install.sh inside a Chimera Linux container.
#
# Usage: tests/run.sh [scenario...]
#   Scenarios: daemon single uninstall reinstall-guard legacy-readme migrate
#              bad-version
#   Default: all of them.
#
# Needs docker (or podman via DOCKER=podman) and network access. A small dinit
# instance stands in for the system init so the service setup is exercised for
# real. Set IMAGE to test a different image, or PLATFORM (e.g. linux/arm64,
# linux/riscv64) to test another architecture under qemu-user binfmt.

set -eu

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-chimeralinux/chimera}"
PLATFORM="${PLATFORM:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Shared setup run inside every container: the packages a typical Chimera
# install has, an unprivileged user with doas, and dinit on /run/dinitctl.
SETUP='
set -eu
apk add --no-progress bash curl shadow opendoas libarchive-progs dinit-chimera >/dev/null
useradd -m -s /bin/sh tester
echo "permit nopass tester as root" >/etc/doas.conf
mkdir -p /etc/dinit.d/boot.d
printf "type = internal\nwaits-for.d: /etc/dinit.d/boot.d\n" >/etc/dinit.d/boot
printf "type = internal\n" >/etc/dinit.d/local.target
dinit -s -d /etc/dinit.d -p /run/dinitctl boot >/var/log/dinit.log 2>&1 &
i=0; while [ ! -S /run/dinitctl ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
as_tester() { su tester -c "cd ~ && $*"; }
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; FAILED=1; fi; }
daemon_pid() { for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = nix-daemon ] && { echo "${p#/proc/}"; return; }; done; }
cat >/tmp/build.nix <<EOF
derivation {
  name = "chimera-test";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "echo ok > \$out" ];
}
EOF
chmod 644 /tmp/build.nix
FAILED=0
'

run() {
    name="$1"
    body="$2"
    printf '\n### %s\n' "$name"
    if "$DOCKER" run --rm --privileged ${PLATFORM:+--platform "$PLATFORM"} -v "$REPO:/repo:ro" "$IMAGE" sh -c "$SETUP
$body
exit \$FAILED" >"$LOGDIR/$name.log" 2>&1; then
        grep -E '^  (ok|FAIL):' "$LOGDIR/$name.log" || true
        echo "PASS: $name"
    else
        grep -E '^  (ok|FAIL):' "$LOGDIR/$name.log" || tail -n 30 "$LOGDIR/$name.log"
        echo "FAIL: $name (full log: $LOGDIR/$name.log)"
        STATUS=1
    fi
}

scenario_daemon() {
    run daemon '
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add"
check "build group exists" "getent group nixbld >/dev/null"
check "32 build users" "[ \$(getent passwd | grep -c \"^nixbld\") -eq 32 ]"
check "build user shell is nologin" "getent passwd nixbld1 | grep -q :/sbin/nologin\$"
check "store is root:nixbld 1775" "[ \"\$(stat -f %u:%Sg:%Mp%Lp /nix/store)\" = 0:nixbld:1775 ]"
check "no store file owned by tester" "[ -z \"\$(find /nix/store -user tester | head -n 1)\" ]"
check "store verifies" "/nix/var/nix/profiles/default/bin/nix-store --verify --check-contents"
check "dinit service written" "grep -q \"Managed by nix-installer-chimera\" /etc/dinit.d/nix-daemon"
check "dinit service enabled" "[ -L /etc/dinit.d/boot.d/nix-daemon ]"
check "dinit reports started" "dinitctl is-started nix-daemon >/dev/null"
check "daemon fd limit raised" "grep -q \"open files  *1048576\" /proc/\$(daemon_pid)/limits"
check "profile.d hook" "grep -q nix-daemon.sh /etc/profile.d/nix.sh"
check "bashrc.d hook" "grep -q nix-daemon.sh /etc/bash/bashrc.d/nix.sh"
check "login shell finds nix" "su - tester -c \"nix --version\""
check "interactive bash finds nix" "su tester -c \"bash -i -c \\\"nix --version\\\"\" 2>/dev/null"
check "user talks to daemon" "su - tester -c \"nix --extra-experimental-features nix-command store info\" 2>&1 | grep -q \"Store URL: daemon\""
check "user builds via daemon" "out=\$(su - tester -c \"nix-build --no-out-link /tmp/build.nix\") && [ \"\$(cat \$out)\" = ok ] && [ \"\$(stat -f %u \$out)\" = 0 ]"
'
}

scenario_single() {
    run single '
as_tester "sh /repo/install.sh --no-daemon --yes --no-channel-add"
check "/nix owned by tester" "[ \"\$(stat -f %Su /nix)\" = tester ]"
check "no dinit service" "[ ! -e /etc/dinit.d/nix-daemon ]"
check "no build group" "! getent group nixbld >/dev/null"
check "user profile hooked" "grep -q \"added by Nix installer\" /home/tester/.profile"
check "login shell finds nix" "su - tester -c \"nix --version\""
check "store verifies" "su - tester -c \"nix-store --verify --check-contents\""
check "store mtimes normalised" "[ -z \"\$(find /nix/store -mindepth 1 -maxdepth 1 -newermt 1970-01-02 ! -name .links)\" ]"
as_tester "sh /repo/install.sh --uninstall --yes"
check "uninstall removed /nix" "[ ! -e /nix ]"
check "uninstall cleaned .profile" "[ -f /home/tester/.profile ] && ! grep -q \"added by Nix installer\" /home/tester/.profile"
'
}

scenario_uninstall() {
    run uninstall '
echo "# pre-existing" >/etc/bash.bashrc
cp /etc/bash.bashrc /tmp/orig.bashrc
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add"
check "bash.bashrc was hooked" "grep -q \"^# Nix\$\" /etc/bash.bashrc"
echo "# added after install" >>/etc/bash.bashrc
as_tester "sh /repo/install.sh --uninstall --yes"
check "/nix removed" "[ ! -e /nix ]"
check "/etc/nix removed" "[ ! -e /etc/nix ]"
check "dinit service removed" "[ ! -e /etc/dinit.d/nix-daemon ] && [ ! -L /etc/dinit.d/boot.d/nix-daemon ]"
check "daemon stopped" "! dinitctl is-started nix-daemon >/dev/null 2>&1"
check "build users removed" "! getent passwd nixbld1 >/dev/null"
check "build group removed" "! getent group nixbld >/dev/null"
check "profile.d hook removed" "[ ! -e /etc/profile.d/nix.sh ]"
check "bashrc.d hook removed" "[ ! -e /etc/bash/bashrc.d/nix.sh ]"
check "bash.bashrc keeps user edits" "grep -q \"pre-existing\" /etc/bash.bashrc && grep -q \"added after install\" /etc/bash.bashrc"
check "bash.bashrc Nix block gone" "! grep -q nix-daemon /etc/bash.bashrc"
check "no backups left" "[ -z \"\$(ls /etc/*.backup-before-nix /etc/profile.d/*.backup-before-nix 2>/dev/null)\" ]"
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add" >/dev/null 2>&1
check "reinstall after uninstall works" "dinitctl is-started nix-daemon >/dev/null && su - tester -c \"nix --version\""
'
}

scenario_reinstall_guard() {
    run reinstall-guard '
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add" >/dev/null
check "second install refuses" "! as_tester \"sh /repo/install.sh --daemon --yes\" 2>/tmp/err"
check "and says why" "grep -q \"already installed\" /tmp/err"
'
}

scenario_legacy_readme() {
    # A system set up with the old README: service file without our marker,
    # already enabled and running when the new installer is run.
    run legacy-readme '
printf "type = process\ncommand = /nix/var/nix/profiles/default/bin/nix-daemon\nrestart = true\n" >/etc/dinit.d/nix-daemon
ln -s ../nix-daemon /etc/dinit.d/boot.d/nix-daemon
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add"
check "old service file replaced" "grep -q \"Managed by nix-installer-chimera\" /etc/dinit.d/nix-daemon"
check "dinit reports started" "dinitctl is-started nix-daemon >/dev/null"
check "user talks to daemon" "su - tester -c \"nix --extra-experimental-features nix-command store info\" 2>&1 | grep -q \"Store URL: daemon\""
'
}

scenario_migrate() {
    # A real install made with the previous version of this project (patched
    # Nix 2.30.1 scripts + hand-written dinit service from the old README),
    # then: upgrade in place as the README says, uninstall, install fresh.
    run migrate '
OLD=https://raw.githubusercontent.com/elgreams/nix-installer-chimera/6945d2d9f41c33a3f1601f287f420cccc34ca283
as_tester "mkdir old && cd old && curl -fsSL https://releases.nixos.org/nix/nix-2.30.1/nix-2.30.1-x86_64-linux.tar.xz | tar -xJf - && cd nix-2.30.1-x86_64-linux && curl -fsSLO $OLD/install && curl -fsSLO $OLD/install-multi-user && chmod +x install install-multi-user && NIX_INSTALLER_YES=1 ./install-multi-user" >/tmp/old.log 2>&1 || { tail -n 20 /tmp/old.log; echo "  FAIL: old install"; exit 1; }
printf "type = process\ncommand = /nix/var/nix/profiles/default/bin/nix-daemon\nrestart = true\n" >/etc/dinit.d/nix-daemon
dinitctl enable nix-daemon >/dev/null
check "old install works" "su - tester -c \"nix --version\" | grep -q 2.30.1"
# The README upgrade command, run as root (what `doas` gives you).
su - root -c "nix-env --profile /nix/var/nix/profiles/default --install --file \"<nixpkgs>\" --attr nix cacert" >/tmp/upgrade.log 2>&1 || cat /tmp/upgrade.log
dinitctl restart nix-daemon >/dev/null
check "README upgrade command works" "[ \"\$(su - tester -c \"nix --version\")\" != \"nix (Nix) 2.30.1\" ]"
check "daemon runs upgraded nix" "su - tester -c \"nix --extra-experimental-features nix-command store info\" 2>&1 | grep Version: | grep -vq 2.30.1"
as_tester "sh /repo/install.sh --uninstall --yes"
check "uninstall removed old service" "[ ! -e /etc/dinit.d/nix-daemon ] && [ ! -L /etc/dinit.d/boot.d/nix-daemon ]"
check "uninstall removed /nix" "[ ! -e /nix ]"
check "uninstall removed build users" "! getent passwd nixbld1 >/dev/null"
as_tester "sh /repo/install.sh --daemon --yes --no-channel-add" >/dev/null 2>&1
check "fresh install works" "dinitctl is-started nix-daemon >/dev/null && su - tester -c \"nix-build --no-out-link /tmp/build.nix\" >/dev/null 2>&1"
'
}

scenario_bad_version() {
    run bad-version '
check "rejects malformed version" "! as_tester \"sh /repo/install.sh --yes --nix-version 2.x\" 2>/dev/null"
check "rejects missing release" "! as_tester \"sh /repo/install.sh --yes --nix-version 9.99.99\" 2>/tmp/err && grep -q \"real Nix release\" /tmp/err"
check "nothing installed" "[ ! -e /nix ]"
check "pinned old version works" "as_tester \"sh /repo/install.sh --daemon --yes --no-channel-add --nix-version 2.30.1\" >/dev/null 2>&1 && su - tester -c \"nix --version\" | grep -q 2.30.1"
'
}

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/nix-chimera-tests.XXXXXX")"
STATUS=0

"$DOCKER" pull -q ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE" >/dev/null

if [ $# -eq 0 ]; then
    set -- daemon single uninstall reinstall-guard legacy-readme migrate bad-version
fi
for scenario in "$@"; do
    case "$scenario" in
        daemon) scenario_daemon ;;
        single) scenario_single ;;
        uninstall) scenario_uninstall ;;
        reinstall-guard) scenario_reinstall_guard ;;
        legacy-readme) scenario_legacy_readme ;;
        migrate) scenario_migrate ;;
        bad-version) scenario_bad_version ;;
        *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
    esac
done

echo
if [ "$STATUS" -eq 0 ]; then
    echo "All scenarios passed. Logs: $LOGDIR"
else
    echo "Some scenarios failed. Logs: $LOGDIR"
fi
exit "$STATUS"
