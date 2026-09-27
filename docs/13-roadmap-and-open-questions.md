# 13 — Roadmap and Open Questions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

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
  Yanyu STX-R19F, Raspberry Pi 4.
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
* Remote access: WireGuard; optional Tailscale.
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
* README translations (Chinese, Russian, Persian) at pre-release.
* User manual (`manual/`) and, with it, `manual/llms.txt` and `manual/ai.md`.
* Optional local configuration wizard, a front end for the build-host commands in *16*. No hosted build service.

## 2. Decisions

| # | Question | Answer | Status |
|---|----------------------|-----------------|--------|
| Q1 | Should `configuration.nix` be split into several modular files? | Support both. Template ships one file for beginners; `mkRouter` accepts a module list; docs show a split layout (`network.nix`, `proxy.nix`, `hardware.nix`) for larger setups. | Decided (FR-CFG-006) |
| Q2 | "`configuration.nix` (single file or modular set) should be copied into the image" | The complete flake source tree that produced the image — `flake.nix`, `flake.lock`, `configuration.nix` and every imported module — is embedded read-only at `/etc/janus/source` (`janus.system.embedSource`, default on). Whole-tree embedding is required because modular configurations import by relative path and reproducibility needs the lock file; with flakes it costs one store symlink. Files outside the flake tree are not captured (warning at evaluation); inline secrets become visible there, which is one more reason the example uses `…File` options. | Decided (FR-CFG-008) |
| Q3 | Where should mutable files live — `/run`, `/var`, other? | `/var` on a dedicated rw f2fs state partition. `/run` is tmpfs and lost at reboot, so it is wrong for subscriptions/Geo data. | Decided (FR-STO-004) |
| Q4 | Is "the only way to apply changes is nixos-rebuild" compatible with automatic subscription updates? | Three kinds: maintenance actions, hot overrides, and rebuilds on the build host. The board never evaluates Nix. See *12 — Operations §1* and ADR-0017. | Decided (ADR-0002, ADR-0017) |
| Q5 | Reuse NixOS NetworkManager network definitions? | No. NetworkManager is host-oriented. Janus lowers to systemd-networkd + nftables; raw `systemd.network.*` remains available as escape hatch. | Decided (ADR-0004) |
| Q6 | Better terms than direct / rule-based / global? | `direct`, `rule-based`, `proxy-all`. Alternatives considered: `bypass`/`split`/`tunnel-all`. | Proposed; confirm |
| Q7 | Which DNS policies could users ask for? | Enumerated in *07 §7.2*: carrier-resolver policy, encryption policy, domestic/remote resolver sets, fake-IP, AAAA handling, plaintext interception, DoT/DoH blocking, overrides, ECS. | Proposed |
| Q8 | sing-box or Xray — user-selectable? | Yes; canonical model with two renderers; sing-box default. | Decided (ADR-0006) |
| Q9 | What to call the device / the add-ons? | **Board** / **Peripheral**. | Proposed; confirm |
| Q10 | How to organize 4G dongles that act as Ethernet NICs but also speak AT? | One `wwan` Peripheral class with `mode` (ecm/ncm/rndis/qmi/mbim) and optional AT control channel; WAN `mode = "wwan"` references it. | Proposed (10 §4.2) |
| Q11 | Which Wi-Fi dongle models? | Initial matrix in *10 §4.3* (MT7612U, MT7921AU); mainline-driver-only policy. | Proposed |
| Q12 | IPv6 and carrier/government monitoring | Policy-driven IPv6 with `disabled` default when tunneling; stable-privacy; AAAA stripping; tunnel-aware interception; optional NPTv6. | Proposed (06 §9) |
| Q13 | Grouping by PEG in Janet — worth the dependency? Should tooling move to Go because the engines are Go? | Stay on Janet. Go can express rich matchers too; it does not give a runtime PEG interpreter, and the engines are not libraries we link. | Decided (ADR-0008, ADR-0020) |
| Q14 | Remote access behind NAT — which mechanism? | WireGuard to a user endpoint as P1; Tailscale/Headscale P3; reverse SSH P3. | Proposed |
| Q15 | Allow closed firmware for Raspberry Pi Zero 2 W Wi-Fi/Bluetooth? | Yes, when the blob is redistributable and required. No out-of-tree drivers to widen device support. | Decided (FR-HW-006) |
| Q16 | How far should 4G/5G support go? | Allowlist of known devices only. No best-effort bring-up for difficult dongles. | Decided (FR-HW-007) |
| Q17 | sops-nix for credentials? Are subscription URLs secrets? | Yes, sops-nix + age. Subscription URLs are secrets (they carry tokens). Wi-Fi SSID is not. Node-list contents stay volatile data. | Decided (ADR-0014) |
| Q18 | DNS by the engine, mosdns, or chinadns-ng? Fake-IP as a user choice? | Engine only. Fake-IP is `auto` / `on` / `off`. `janus dns check` tests leaks and poisoning. | Decided (ADR-0019) |
| Q19 | On-site `nixos-rebuild` for a new subscription URL? Does that rewrite the Nix store? Must config be a git repo users fork? | No on-site rebuild. The store is not rewritten; evaluation on the board is still the wrong trade. Users keep a private config repo that pins Janus OS. They do not fork the OS per device. | Decided (ADR-0017, ADR-0018) |
| Q20 | Web UI or CLI for maintenance? | CLI in 1.0. A later page may only expose status, actions, and hot overrides. | Decided (FR-ACC-005) |
| Q21 | Public repo, extra languages, a web page that builds images, a separate GitHub account? | Public repo. English canonical; zh/ru/fa READMEs at pre-release. Local wizard only, no hosted builder. A second account is not a safety measure; use mirrors. | Decided (*00* §9) |
| Q22 | Is backup important on a declarative router? | Only what git cannot recreate. Age key and unexported overrides are required. Caches and logs are optional. Subscription URLs go back via export, not via backup. | Decided (FR-OPS-011) |
| Q23 | Two document suites, a CLI spec, and `llms.txt`? | `docs/` is the definition suite. *14* specifies the CLI before code, including the override commands. `manual/` plus `llms.txt` / `ai.md` at pre-release. The guide text is U7. | Decided |
| Q24 | Which boards are Tier 1? | The owner's lab: Zero 2 W, Le Potato, NanoPi R4S, Yanyu STX-R19F, plus Raspberry Pi 4 from the original matrix. Tier is a test obligation, not one throughput number. | Decided (*10*) |
| Q25 | Must the config repo be on a remote? One file or modules? Several routers? Which file name? Does the device push overrides? | Local git is mandatory, remote is not. One repo, many hosts, shared modules, file name `configuration.nix`. The device does not push or pull. | Decided (ADR-0021) |
| Q26 | IPTV-only WAN VLAN, or a general VLAN, and when? | General VLAN model. 1.0 implements LAN VLANs only. WAN VLAN, the `iptv` role, and IGMP are after 1.0. | Decided (FR-NET-005, FR-NET-014, FR-NET-020) |
| Q27 | Connection audit log for a LAN device that may be reporting elsewhere? | Yes, after 1.0. Configuration includes it, default off; runtime start/stop when included. Metadata only, one JSON object per line, analysed off the board. | Decided (FR-MON-007) |
| Q28 | RTL8188CUS as an access point, given it already is one on OpenWrt? | Yes, 2.4 GHz, in-tree `rtl8192cu` only. OpenWrt's working AP is that driver. Desktop kernels often bind `rtl8xxxu` instead, which did not advertise AP before Linux 6.15 and is much slower in AP mode. No vendor `hostapd` fork. | Decided (*10* §4.4) |
| Q29 | Fibocom NL668 data plane? | USB `05c6:90b6`, product `Android`, appears as a USB Ethernet NIC. Ethernet-mode WWAN and a DHCP server on the module when the SIM and antennas are fitted. No APN from Janus. The ID is not unique to this module. | Decided (*10* §4.2) |
| Q30 | Low-battery behaviour for an INA219 UPS? | Shut down early, only while the cell is discharging. Do not shut down on mains charge, on a dead sensor, or below the default voltages. | Decided (*10* §4.5, FR-HW-008) |
| Q31 | Waveshare 1.3" OLED HAT as its own project? | No. The panel and its keys are a Janus HMI profile. The joystick navigates. The three keys are separate, and factory reset is unbound unless configured. | Decided (*10* §4.6) |
| Q32 | One UI for a 1.3" panel and for 2.x" or 3.x" panels, with different keys? | Yes. Pages and capabilities are fixed. The framebuffer size picks `compact`, `medium`, or `wide`. A profile maps whatever controls exist onto those capabilities. Missing controls hide the actions that needed them. | Decided (*15*) |
| Q33 | How does one rotated subscription URL reach several routers? | Edit the shared sops secret once. `janus-build fleet apply` pushes the hot-override projection over SSH. Down hosts wait for the next deploy of that commit. | Decided (FR-OPS-012, *16*) |
| Q34 | What does `janus-build fleet apply` do with a commit that also changes firewall, ports, or another structural option? | It prints those paths and changes nothing. `--only-overrides` pushes only the allowlist projection. Structural changes wait for `janus-build deploy`. | Decided (*16* §4) |
| Q35 | Should the router emit Nix for its overrides? | No. It does not know the module layout. `janus override show` is the current set, not a history. `janus-build fleet pull <host>` writes sops keys and `hosts/<host>/overrides.nix`. | Decided (FR-OPS-008, *16* §5) |
| Q36 | Is there a build-host CLI, and does a wizard replace it? | Yes. `janus-build` covers init, secrets, check, build, deploy, fleet, status, backup, and update (*16*). A later local wizard is a front end for `init`. | Decided (*16* §1) |
| Q37 | Same `janus` binary on the build host and on the router? | No. The router program is `janus`. The build-host program is `janus-build`. Nix remains the build system. `janus-build` drives the repo and calls `janus` over SSH. | Decided (*16*) |

## 3. Undecided

These stay open. Implementation does not invent an answer for them.

| ID | Question | Why it is open | Leaning, not a decision |
|----|----------|----------------|-------------------------|
| ADR-0009 | Which DHCP and RA server? | Kea, dnsmasq in DHCP-only mode, or networkd's built-in server. | dnsmasq, unless Kea's lease file proves necessary. |
| ADR-0010 | Which tool assembles the disk image? | A custom f2fs builder, or `systemd-repart`. | Custom builder until repart can populate f2fs. |
| ADR-0011 | Transparent proxy inbound? | TUN or TPROXY. | TUN for sing-box. TPROXY for Xray. |
| ADR-0012 | Are subscription fetches pure? | Impure by default, or a required hash. | Impure, with `snapshot.hash` as an option. |
| ADR-0013 | Is the journal persistent? | Volatile, or persistent with a cap. | Volatile. |
| ADR-0015 | Which WWAN control plane? | ModemManager, or `libqmi` / `libmbim` command-line tools. | The command-line tools. ModemManager stays optional. |
| ADR-0016 | What happens when the engine is down? | Fail closed, or fail open. | Closed. |
| U1 | Which case label on the Yanyu STX-R19F is which PCI port? | CPU, RAM, legacy AMI BIOS, 32 GB SATA SSD, serial console, and the four `e1000e` PCI paths are known (*10* §3.1). The silkscreen was not walked port by port. `01:00.0` had no link; the other three were up at 1 Gbit/s. | Do not assign WAN to `nic1`. Record the map when each jack is plugged alone. |
| U4 | Which INA219 current sign means the cell is discharging, on the mcuzone `0x40` board and the Waveshare `0x43` board? | The shutdown policy is decided. The shunt direction was not measured, and guessing it could power the router off while it is on mains. | Record the sign in the profile after one bench check. Until then the profile shows readings and does not arm shutdown. |
| U5 | What is the CSR Bluetooth dongle for? | `0a12:0001` is confirmed on Le Potato. No router feature was named. | BlueZ stays off by default. The dongle remains on the allowlist. |
| U7 | What does `manual/ai.md` tell an assistant? | The mechanism (`llms.txt` → `ai.md`) is decided. The sentences need a manual to point at. | Write it with the manual: follow *14* and the example config, do not invent options, do not suggest `nixos-rebuild` on the board. |
| U8 | Does Raspberry Pi 4 stay Tier 1 if it is not in the owner's lab? | The original matrix made it release-blocking. The new lab list does not include it. | Leave it Tier 1 until the owner says it cannot be tested. |

## 4. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| NixOS read-only `/etc` overlay still maturing | boot issues on some releases | pin release; VM test; fallback to tmpfs `/etc` with copied tree |
| f2fs population without root in Nix sandbox (`sload.f2fs`) has edge cases (xattrs, symlinks) | broken images | golden tests mounting images in VM; erofs fallback for ro partitions |
| Emulated aarch64 builds are slow for user changes | poor UX | rely on binary cache; document native/cross options; keep Janus-specific packages tiny |
| Engine upstream churn (sing-box config format) | renderer breakage | pin engine version per release; golden tests |
| Subscription providers' formats vary wildly | parse failures | normalizer test corpus; `format` override; permissive parsing with warnings |
| armv7l/riscv64 without cache | hours-long builds | Tier 3, clearly labelled |
