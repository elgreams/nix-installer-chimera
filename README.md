# nix-installer-chimera

A modified Nix package manager installer for Chimera Linux.

This version replaces GNU-specific commands like `cp --preserve=ownership,timestamps` with portable alternatives (e.g. `cp -a`) to support Chimera's musl-based environment, which does not include GNU coreutils by default.

The goal is to keep the installer functional on Chimera with minimal changes. This maybe also might work on Alpine (no guarantee).

## Quick Install

You can install Nix on Chimera directly via this one-liner in Bash:

```sh
sh <(curl -fsSL https://raw.githubusercontent.com/elgreams/nix-installer-chimera/main/chinera-nix-install.sh)
```

You'll be prompted to choose between single-user and multi-user install modes. Multi-user is recommended.


## Enabling the Nix Daemon on Chimera

After installing Nix, you'll need to enable the `nix-daemon` for multi-user support.

1. Create the dinit service file at `/etc/dinit.d/nix-daemon`:

   ```ini
   type = process
   command = /nix/var/nix/profiles/default/bin/nix-daemon
   restart = true
   ```

2. Enable the service at boot:

   ```sh
   ln -s /etc/dinit.d/nix-daemon /etc/dinit.d/boot.d/
   ```

3. Start the daemon immediately (optional):

   ```sh
   dinitctl start nix-daemon
   ```

Once running, you’ll have access to `nix profile install`, flakes, and multi-user package management.

---

## License

This project modifies the official Nix installer, which is licensed under the GNU LGPL 2.1 or later. See [LICENSE](LICENSE) for details.
