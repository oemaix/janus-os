# 13 — Roadmap

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-28 |

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
  Yanyu STX-R19F. Raspberry Pi 4 and Pi 400 are Tier 2.
* Monitoring: counters + vnstat. No connection audit yet.

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

### After 1.0

* WAN VLAN, `iptv` role, IGMP proxy.
* Connection audit log (FR-MON-007), JSON Lines.

### Phase 4 — Polish

* HMI daemon. The interaction model is *15*. The first profile is the Waveshare 1.3" OLED HAT (*10* §4.6).
* Flow export (IPFIX), Prometheus endpoint.
* VisionFive 2, RPi 2 (Tier 3).
* A/B image slots.
* Maintenance page limited to status, maintenance actions, and hot overrides.
* Expand `manual/` (English, Russian, Persian).
* Optional local configuration wizard, a front end for the build-host commands in *16*. No hosted build service.

## 2. Progress

The definition suite still describes the system to build. A file in the
tree does not mean that behavior exists. Stubs are not finished features.

### Done

* Apache-2.0 license at the repository root.
* Flake with `nixosModules.janus`, `nixosModules.boards`, `lib.mkRouter`,
  `templates.default`, and `devShells.default` (`nix develop`).
* Placeholder NixOS modules for the areas in *04* §6. They import and
  define no options.
* `janus-build` and `janus` binaries in the dev shell. Both exit 2.
* User-facing text: root `README.md` and `manual/` in English, Russian,
  and Persian, in that order, plus `manual/llms.txt` and `manual/ai.md`.

### Not done

* Every `janus.*` option in *08*, and every lowering into NixOS.
* `lib.mkRouter`. Calling it throws. It must not grow a silent empty
  configuration.
* Image build, partition layout, and board profiles, including
  `x86_64-test`.
* `janus` and `janus-build` behavior from *14* and *16*. The binaries are
  stubs.
* Subscription snapshot, Geo data, Janet normalizer, matchers, and both
  engine renderers. `janet/` only holds a note. Do not start this in Go.
* Checks, golden files, and VM tests.
* sops-nix wiring, age-key install, hot-override storage, and fleet push.
* HMI, battery shutdown, WWAN, and Wi-Fi AP.
* The local wizard. `janus-build init` is specified and not implemented.

## 3. Notes for later implementation

* Accepted ADRs bind. They are listed in `docs/adr/` and are not restated here.
* Undecided choices, if any, are *18* §2. Do not invent an answer for one.
* The Yanyu profile names `lan1`–`lan4` by PCI address (*10* §3.1). It
  does not pick which jack is WAN.
* Battery shutdown may arm on the mcuzone `0x40` profile, where a
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
