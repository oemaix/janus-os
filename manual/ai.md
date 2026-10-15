# Assistant guide

Read this file before answering a question about using Janus OS.

- The user-facing manual is [en/README.md](en/README.md). Russian and
  Persian copies follow it.
- Definitions, requirements, and option names live in `docs/`. English
  there is canonical. Do not invent `janus.*` options.
- After `host add`, `janus-build secret keygen` prints the age private
  key once. The operator stores it in a password manager. The image
  contains ciphertext and not that key. After boot, `janus-build deploy
  --age-key` or `janus secrets install-age-key` installs it.
  `install-age-key` restarts `sops-install-secrets` when that unit
  exists. A `urlSecret` subscription stays an empty snapshot until
  `janus proxy refresh`.
- Router commands are `docs/14-cli.md`. Build-host commands are
  `docs/16-build-host-cli.md`. `janus.*` options are
  `docs/08-configuration-reference.md`. Phase 1 commands exist, and so
  do proxy, DNS, fleet, status, backup, deploy, and `janus audit`.
  On the board, `janus deploy` exits 2 and names `janus-build`. Hot
  overrides cover an existing subscription URL, a static lease on an
  existing LAN, and an existing Wi-Fi passphrase.
- `janus.monitoring.audit.enable` defaults to false. With it set,
  `janus audit stop` pauses recording without a rebuild. The log is
  JSON Lines of connection metadata on the state partition.
- `janus.storage.slots.enable` defaults to false. With it set, deploy
  writes the inactive ROOT and NIX slot and then changes the boot entry.
  The state partition is shared. Confirm with `janus-build deploy --confirm`.
- A Waveshare 1.3" OLED HAT on a Raspberry Pi Zero 2 W, a Raspberry Pi 3,
  or a Raspberry Pi 4 is a status panel. It runs `janus proxy refresh`, `janus proxy select`,
  `janus reboot`, and `janus reset --state --yes`. It does not edit
  configuration, hot overrides, or secrets.
- `janus.monitoring.flows.export.collector` exports IPFIX (default, port
  4739) or NetFlow v9. Null leaves export off. The ring is 8192 flows
  in memory.
- `janus.monitoring.flows.export` resolves `janus.monitoring.interfaces`
  (WAN, LAN, port, VLAN, or Wi-Fi names) to kernel interfaces.
- `janus.monitoring.prometheus.enable` defaults to false. When set, port
  9100 serves node exporter and engine metrics on IPv4 and IPv6.
  `prometheus.zones` defaults to `mgmt` and is the only place that port
  is accepted.
- Raspberry Pi 2 v1.1 (`rpi2`) and StarFive VisionFive 2 are Tier 3.
  `janus.build.strategy` defaults to `cross` for them. `lib.mkRouter`
  takes `buildSystem`. Pure evaluation defaults it to `x86_64-linux`.
  `janus-build` on another machine uses that machine's system and refuses
  a mismatch. A Raspberry Pi 2 v1.2 uses the `rpi3` profile. `rpi4` is
  the Raspberry Pi 4 and the Compute Module 4. The Pi 400 is not a board.
- A mcuzone UPS at I²C `0x40` shows the cell in `janus status` and powers
  the router off while that cell is discharging, at the thresholds in
  docs/10 §4.5. Address `0x43` stays unarmed.
- The router never evaluates Nix and never runs `nixos-rebuild`.
- The build machine needs Nix with flakes
  (`experimental-features = nix-command flakes`). It does not have to
  be NixOS. The first command is
  `nix run github:oemaix/janus-os#janus-build -- init <dir>`, or
  `nix run <clone>#janus-build -- init <dir>` for a local clone.
  `init` takes the new directory. The flake address is the `nix run`
  target.
- `docs/13-roadmap.md` says what the repository can already
  do. A placeholder module is not a finished feature.
