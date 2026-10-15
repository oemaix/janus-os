# 13 — Roadmap

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-16 |

This file is the implementation plan, the progress of the code, and the
notes for work that is specified but not started. Choices are *18*.
Explanations are *19*. Accepted ADRs are `docs/adr/`.

## 1. Phased roadmap

### Phase 0 — Foundations (repo skeleton)

* Flake, `mkRouter`, `x86_64-test` board, module skeleton with option
  types and assertions, options-doc generation, CI for eval tests.
* CLI specified in *14* and *16* before the commands are implemented.
* Storage: partition model, read-only root via `/etc` overlay, image
  builder with f2fs + FAT, VM boot test.

### Phase 1 — Router core (MVP, no proxy)

* LAN VLANs, WAN `dhcp`/`static`/`pppoe`, multi-WAN roles `default` /
  `backup` / `custom`, LANs with DHCPv4 + static leases, zone firewall,
  NAT, port forwards, IPv6 modes `disabled`/`ula-only`/`delegated`.
* SSH key-only, `janus` CLI as specified in *14*.
* `janus-build init`, `secret`, `check`, `build`, and `update` (*16*).
* sops-nix age key install path for PPPoE and Wi-Fi secrets.
* Boards (Tier 1): NanoPi R4S, Raspberry Pi Zero 2 W, Le Potato,
  Yanyu STX-R19F. 
* Monitoring: counters + vnstat. The connection audit is FR-MON-007.

### Phase 2 — Circumvention

* Canonical node model, Janet normalizer (share links, Clash, sing-box),
  matchers (regex, glob, PEG), groups, rules, traffic modes.
* sing-box renderer, TUN interception v4+v6, fail-closed.
* DNS policy layer (split, encrypted, fake-IP, carrier-resolver policy,
  plaintext interception).
* Build-time snapshot, runtime refresh with rollback, Geo data pipeline.
* Example configuration templates (regions, usages).
* VMess in the canonical model. Hot override for an existing subscription URL.
* `janus-build fleet`, `status`, and `backup` (*16*, FR-OPS-012).
* `janus dns check`.

### Phase 3 — Breadth

* Xray renderer with capability assertions.
* WWAN peripherals (ECM/NCM/RNDIS, QMI/MBIM), backup WAN failover.
* Wi-Fi AP peripherals.
* Remote access: Tailscale into the `mgmt` zone. Optional WireGuard to a user endpoint. No reverse SSH.
* Boards: RPi 3 (Tier 2).
* Hot overrides for static leases and Wi-Fi passphrase.
* Remote closure deployment (`janus-build deploy`).

### Phase 4 — Polish

* HMI daemon. The interaction model is *15*. The first profile is the Waveshare 1.3" OLED HAT (*10* §4.6). Implemented; see Progress.
* Flow export (IPFIX) and a Prometheus endpoint. Implemented; see Progress.
* VisionFive 2, RPi 2 (Tier 3). Implemented; see Progress.
* A/B image slots. Implemented; see Progress.
* Maintenance page limited to status, maintenance actions, and hot overrides (*20*). Implemented; see Progress.
* Operator manual in English, Russian, and Persian: build, flash, deploy, audit, A/B slots, the status panel, the maintenance page, Tier 3 boards, flow export, and the Prometheus endpoint. Implemented; see Progress.

### Future

* WAN VLAN, the `iptv` role, and IGMP proxy (*06*, FR-NET-003, FR-NET-020).
* Optional local configuration wizard, a front end for the build-host commands in *16*. No hosted build service.

## 2. Progress

The definition suite still describes the system to build. A file in the
tree does not mean that behavior exists. Stubs are not finished features.

### Done

* Apache-2.0 license at the repository root.
* Flake with `nixosModules.janus`, `nixosModules.boards`, `lib.mkRouter`,
  `templates.default`, and `devShells.default` (`nix develop`).
* `lib.mkRouter` reads `janus.hardware.board` and returns a NixOS
  configuration, including `system.build.janusImage`. Implemented boards
  are `x86_64-test`, `yanyu-stx-r19f`, `nanopi-r4s`, `le-potato`,
  `rpi-zero-2w`, `rpi3`, `rpi4`, `rpi2`, and `visionfive2`. It
  does not return an empty configuration. `armv7l` and `riscv64` default
  to a cross build (`janus.build.strategy`).
* `janus.*` option types, defaults, and the structural assertions in
  *08* §12. Storage is lowered: partition labels, read-only `/` and
  `/nix`, one read-write `/var`, and `system.etc.overlay` with
  `mutable = false`.
* `janus.network` lowers ports, LAN VLANs, WAN `dhcp`/`static`/`pppoe`,
  LAN bridges, DHCPv4, and the IPv6 modes into networkd, pppd, and
  dnsmasq. `janus.firewall` lowers zones, NAT, and port forwards into
  nftables. OpenSSH is key-only. vnstat keeps interface counters.
* `janus` and `janus-build` implement the phase 1 commands in *14* and
  *16* (`init`, `host add`, `secret keygen`, `secret set`, `check`,
  `build`, `update`, and the router status commands). The age private
  key path is `/var/lib/janus/secrets/age.key`. sops-nix decrypts to
  `/run/secrets` at activation. A PPPoE `passwordSecret` is YAML with
  `username` and `password`. A Wi-Fi `passphraseSecret` is one line.
  `janus-hostapd-<name>` reads a runtime passphrase file.
* Board profiles: `x86_64-test` (virtio, no raw firmware), NanoPi R4S
  (U-Boot at sector 64, `eth0`/`eth1`, no WAN chosen), Le Potato (U-Boot
  FIP, one `eth0`), Raspberry Pi Zero 2 W (FAT `config.txt`, no Ethernet
  port), Raspberry Pi 3 / 3+ (`rpi3`, FAT `config.txt`, one `eth0`),
  Raspberry Pi 4 and Compute Module 4 (`rpi4`, FAT `config.txt`, hybrid
  MBR, one `eth0`; the Pi 400 is not a board),
  Raspberry Pi 2 v1.1 (`rpi2`, 32-bit, hybrid MBR, one `eth0`; a v1.2
  uses `rpi3`), and StarFive VisionFive 2 (SPL and U-Boot in GPT
  partitions `2E54B353…` and `BC13C2FF…`, `eth0`/`eth1`, no WAN chosen).
  Yanyu names `lan1`–`lan4` by PCI path and installs Limine
  (D-0029). The image has not been booted on the lab AMI board. Tier 3
  images are not boot-tested here.
* Image builder: GPT, FAT boot, f2fs root, f2fs store, f2fs state.
  `nix build .#checks.x86_64-linux.vm-x86_64-test` boots that image.
* Options reference: `nix build .#docs-options`.
* Eval checks under `checks.<system>.eval-*`, and CI for those checks
  plus the options document.
* `janus-build` and `janus` binaries in the dev shell.
* User-facing text: root `README.md` and `manual/` in English, Russian,
  and Persian, in that order, plus `manual/llms.txt` and `manual/ai.md`.
* `janet/janus.janet` normalizes share links, Clash, and sing-box, matches
  with regex, glob, and PEG, and renders sing-box or Xray. The image
  build runs `sing-box check` or `xray run -test`.
* `janus.proxy.enable` installs the selected engine and redirects LAN DNS
  to it. sing-box marks proxied LAN traffic into table 2022 (D-0030).
  Xray tproxies that traffic to port 12345 (D-0031).
* Subscription refresh, Geo data download, and hot overrides for an
  existing subscription URL, a static lease on an existing LAN, and an
  existing Wi-Fi passphrase. `janus dns check` reports and does not
  change policy. `janus-build fleet`, `status`, `backup`, and `deploy`
  are the build-host commands in *16*.
* WWAN Ethernet modes are DHCP clients. QMI and MBIM run `qmicli` or
  `mbimcli` before networkd (ADR-0015). A backup WAN can fail over when
  its health targets fail.
* Tailscale and optional WireGuard join the `mgmt` zone. There is no
  reverse SSH.
* Connection audit (FR-MON-007) records metadata as JSON Lines on the
  state partition when `janus.monitoring.audit.enable` is set. `janus audit`
  starts and stops recording without a rebuild.
* `janus.storage.slots.enable` duplicates `ROOT` and `NIX`. `janus-build
  deploy` then writes the inactive slot and toggles the boot entry (*09* §8.4).
* The Waveshare 1.3" OLED HAT on `rpi-zero-2w`, `rpi3`, or `rpi4` is a status
  panel (*15*, *10* §4.6). It runs `janus proxy refresh`, `janus proxy
  select`, `janus reboot`, and `janus reset --state --yes`. It does not
  edit configuration, hot overrides, or secrets.
* `janus.access.web.enable` includes the maintenance page (*20*). It is
  off unless set. `janus web stop` pauses the listener without a rebuild.
  Login is a passphrase file, not the root password. The page calls the
  allowlisted `janus` commands and does not edit the rest of the configuration.
* A mcuzone INA219 at `0x40` reports the cell in `janus status` and powers
  the router off while the cell is discharging, at the thresholds in *10*
  §4.5. The Waveshare address `0x43` stays unarmed.
* `janus.monitoring.flows.export.collector` runs softflowd. `ipfix` is
  NetFlow version 10 and `netflow9` is version 9. The in-memory ring holds
  8192 flows. `janus.monitoring.interfaces` names WANs, LANs, ports, VLANs,
  or Wi-Fi networks, and flow export resolves them to kernel interfaces.
  `janus.monitoring.prometheus.enable` serves node exporter on port 9100
  for IPv4 and IPv6, plus engine metrics in the textfile collector. That
  port is accepted only on `prometheus.zones` (default `mgmt`) and dropped
  on every other interface.
* `eval-proxy-local` fetches a page on `127.0.0.1` through the rendered
  sing-box Shadowsocks outbound. The fixture server speaks the same method
  and password. The router's firewall mark is not applied on that hop.
* `vm-x86_64-net` boots the `x86_64-test` image with a WAN and a LAN. A
  second guest takes a DHCPv4 lease, reaches a host service through NAT,
  receives `vm.test` from the engine, reads the SSH banner on the LAN, and
  cannot open SSH on the WAN. The mount check remains `vm-x86_64-test`.

## 3. Notes for later implementation

* Accepted ADRs bind. They are listed in `docs/adr/` and are not restated here.
* Undecided choices, if any, are *18* §2. Do not invent an answer for one.
* The Yanyu profile names `lan1`–`lan4` by PCI address (*10* §3.1). It
  does not pick which jack is WAN. Limine on that image has not been
  booted on the lab AMI board.
* Battery shutdown arms on the mcuzone `0x40` profile, where a
  negative current means discharge. The Waveshare `0x43` profile stays
  unarmed.
* The CSR Bluetooth dongle `0a12:0001` stays on the allowlist. BlueZ stays
  off. No Bluetooth feature is assigned.
* The board image must not contain a compiler or `janus-build`. The `nix`
  binary stays for activation and for `nix-store --import` (*05*, *09*
  §8.2). `nix.enable = false`, nixpkgs sources are absent, and `/nix` is
  read-only except during that deploy, so the board does not evaluate.
  The dev shell is only for the build host.
* No MCP server is included. One would only repeat `janus-build` before
  that program exists, and a stub that returned invented data would be
  worse than no server.

## 4. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| NixOS read-only `/etc` overlay still maturing | boot issues on some releases | pin release; VM test; fallback to tmpfs `/etc` with copied tree |
| f2fs population without root in Nix sandbox (`sload.f2fs`) has edge cases (xattrs, symlinks) | broken images | golden tests mounting images in VM; erofs fallback for ro partitions |
| Emulated aarch64 builds are slow for user changes | poor UX | rely on binary cache; document native/cross options; keep Janus-specific packages tiny |
| Engine upstream churn (sing-box config format) | renderer breakage | pin engine version per release; golden tests |
| Subscription providers' formats vary wildly | parse failures | normalizer test corpus; `format` override; permissive parsing with warnings |
| armv7l/riscv64 without cache | hours-long builds | Tier 3, clearly labelled |
