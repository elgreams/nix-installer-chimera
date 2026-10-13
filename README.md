# nix-installer-chimera

Install the [Nix](https://nixos.org) package manager on [Chimera Linux](https://chimera-linux.org), with the multi-user daemon managed by dinit.

```sh
curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh | sh
```

You'll be asked whether you want a multi-user (recommended) or single-user install. That's it: when the script finishes, `nix-daemon` is running under dinit and starts on every boot.

## What it does

This is a thin wrapper around the **official** Nix installer, not a fork of it. The script:

1. Finds the latest Nix release (or the one you ask for with `--nix-version`) and downloads the official binary tarball for your architecture.
2. Checks the tarball against its published SHA-256.
3. Replaces the GNU-only commands in the official installer (see [Why](#why-is-this-needed)).
4. Runs the official installer.
5. For multi-user installs:
   - makes the initial store paths owned by root,
   - adds a hook so interactive bash shells load Nix (`/etc/bash/bashrc.d/nix.sh`),
   - writes, enables and starts a dinit service at `/etc/dinit.d/nix-daemon`.

Supported architectures: x86_64, aarch64, riscv64, armv7l, armv6l, i686.

## Requirements

A normal Chimera install already has most of these. If something is missing, the script tells you which package to install:

```sh
doas apk add curl libarchive-progs bash shadow
```

`bash` and `shadow` are only needed for multi-user installs. You need root access, either through `doas` (your user in the `wheel` group) or by running the script as root.

## Options

```sh
curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh | sh -s -- [options]
```

| Option | |
| --- | --- |
| `--daemon` | Multi-user install with a dinit-managed daemon (the default with no terminal) |
| `--no-daemon` | Single-user install owned by you |
| `--yes` | Don't ask questions |
| `--nix-version VER` | Install a specific Nix release instead of the latest |
| `--no-dinit` | Don't set up the dinit service |
| `--uninstall` | Remove Nix completely |
| `--no-channel-add`, `--no-modify-profile`, `--daemon-user-count N`, `--nix-extra-conf-file FILE` | Passed through to the official installer |

Set `NIX_BECOME` to use something other than `doas`/`sudo` to gain root.

## Managing the daemon

```sh
doas dinitctl status nix-daemon
doas dinitctl restart nix-daemon
doas dinitctl catlog nix-daemon    # recent daemon output
```

## Enabling flakes

Flakes and the `nix` command are still experimental upstream and are off by default. To turn them on:

```sh
echo 'experimental-features = nix-command flakes' | doas tee -a /etc/nix/nix.conf
doas dinitctl restart nix-daemon
```

## Upgrading

Nix upgrades itself; the installer isn't involved:

```sh
doas nix-env --profile /nix/var/nix/profiles/default --install --file '<nixpkgs>' --attr nix cacert
doas dinitctl restart nix-daemon
```

## Uninstalling

```sh
curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/install.sh | sh -s -- --uninstall
```

This stops and removes the dinit service and deletes the following:
- `/nix` and `/etc/nix`
- the `nixbld` users and group
- the Nix lines in shell profiles; the files are restored from the installer's backups when nothing else in them changed

It works for single-user installs too.

## Migrating from the old version of this project

Earlier versions shipped modified copies of the Nix 2.30.1 installer and told you to write `/etc/dinit.d/nix-daemon` by hand. You don't have to reinstall: that setup keeps working, and you can upgrade Nix with the command under [Upgrading](#upgrading).

If you'd like the improved service file (the old one lacks `depends-on: local.target` and the raised open-file limit), run `--uninstall` and then install again. The new uninstaller recognises the old service file. Uninstalling deletes your Nix store, so reinstall when you have time to re-download your packages.

## Why is this needed?

The official installer assumes GNU coreutils on Linux, but Chimera's core utilities come from FreeBSD. Two commands break:

| Official installer | Fails with | Replaced by |
| --- | --- | --- |
| `cp -RP --preserve=ownership,timestamps` | `cp: unrecognized option: preserve=ownership,timestamps` | `cp -RPp`, which the official installer already uses on macOS and FreeBSD |
| `touch -hmd "@1"` (single-user, Nix 2.35.3+) | `touch: out of range or illegal time specification` | `touch -hmd 1970-01-01T00:00:01Z`, the same time written in a format both GNU and BSD `touch` accept |

If a future official installer adds another GNU-only option the script knows about (`--preserve`, or `touch` with an `@` timestamp), it stops with an error rather than running a broken install. The weekly CI run against the latest release is there to catch other kinds of breakage early.

The official installer also doesn't know about dinit, so this script sets up the service. Before Nix 2.35.3, it left the files copied from the tarball owned by the user who ran it; the script makes them root-owned for older `--nix-version` choices.

## Testing

`tests/run.sh` runs the installer in `chimeralinux/chimera` containers, with a real dinit instance standing in for init. It covers multi-user and single-user installs, uninstalling, reinstalling, migrating from the old README setup, and pinned and invalid versions:

```sh
tests/run.sh                 # all scenarios
tests/run.sh daemon single   # just these
```

It needs Docker (or `DOCKER=podman`) and network access. `PLATFORM=linux/arm64` selects another architecture, but under qemu-user emulation `doas` loses setuid and Chimera's `cp -R` fails with "Function not implemented", so a full non-x86_64 install needs real hardware or a VM.

## License

The official Nix installer, which this script downloads and runs, is licensed under the GNU LGPL 2.1 or later. This project is released under the same license; see [LICENSE](LICENSE).
