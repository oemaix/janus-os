# 18 ÿÿÿ Decisions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-29 |

A row here is a choice that binds implementation and is not an ADR. The
cited requirement or design section is the text that binds. An accepted
ADR is the record for that choice and is not copied here. Questions that
only explain a choice are *19*.

Each choice is `D-nnnn`. The number is assigned once, in either section,
and it stays when a row moves from Undecided to Decided. A deleted number
is not reused.

Undecided rows are open. Implementation does not invent an answer for them.

## 1. Decided

| # | Choice | Where |
|---|--------|-------|
| D-0001 | One configuration file and a module list are both valid. The fleet template gives each router `hosts/<name>/configuration.nix`. `flake.nix` is the index. Shared modules are `common/default.nix`. | FR-CFG-006, FR-CFG-011, *09* ?3 |
| D-0002 | The flake tree that built the image is embedded at `/etc/janus/source`. | FR-CFG-008 |
| D-0003 | Mutable data lives on the `/var` state partition. | FR-STO-004 |
| D-0004 | Traffic modes are `bypass`, `rule-based`, and `proxy-all`. A rule target may be `direct`. | *01*, FR-PRX-020 |
| D-0005 | The computer is a Board. An add-on is a Peripheral. | *01* |
| D-0006 | A cellular module is one `wwan` Peripheral, including one that looks like Ethernet. | *10* ?4.2 |
| D-0007 | Wi-Fi dongles are the matrix in *10* ?4.3. Drivers are mainline only. | *10* ?4.3 |
| D-0008 | IPv6 is a per-LAN policy. The default is `disabled` when tunneling. | *06* ?9 |
| D-0009 | Remote access is Tailscale into the `mgmt` zone, SSH only. Advertising routes and an exit node are opt-in. A raw WireGuard peer is optional. Reverse SSH is not a backend. | FR-RA |
| D-0010 | Closed firmware is allowed when the blob is redistributable and required. Out-of-tree drivers are not added to widen support. | FR-HW-006 |
| D-0011 | WWAN is an allowlist. There is no best-effort bring-up. | FR-HW-007 |
| D-0012 | Management in 1.0 is the CLI. A later page covers status, maintenance actions, and hot overrides only. | FR-ACC-005 |
| D-0013 | The OS repository is public. User-facing text is English, then Russian, then Persian. There is no hosted builder. | *00* ?9 |
| D-0014 | Backup stores what git cannot recreate: the age key, and overrides that have not been pulled. | FR-OPS-011 |
| D-0015 | `docs/` is the definition suite. `manual/` is the user guide. `llms.txt` points at `ai.md`. | *14*, *16* |
| D-0016 | Tier 1 is Zero 2 W, Le Potato, NanoPi R4S, and Yanyu STX-R19F. Raspberry Pi 4 and Pi 400 are Tier 2. | *10* |
| D-0017 | The VLAN model is general. 1.0 implements LAN VLANs. WAN VLAN, the `iptv` role, and IGMP are after 1.0. | FR-NET-005, FR-NET-014, FR-NET-020 |
| D-0018 | A connection audit log is after 1.0, off unless configured, metadata only. | FR-MON-007 |
| D-0019 | RTL8188CUS is a 2.4 GHz access point on in-tree `rtl8192cu`. | *10* ?4.4 |
| D-0020 | The router shuts down on a low cell only while that cell is discharging, and only at the default voltages. | *10* ?4.5, FR-HW-008 |
| D-0021 | The Waveshare panel is a Janus HMI profile. | *10* ?4.6 |
| D-0022 | Pages and capabilities are one model. Panel size and the keys on the board are profiles. | *15* |
| D-0023 | A shared subscription secret is edited once and pushed with `janus-build fleet apply`. | FR-OPS-012, *16* |
| D-0024 | `fleet apply` prints non-override paths and changes nothing. `--only-overrides` pushes the allowlist only. | *16* ?4 |
| D-0025 | The router does not emit Nix. `janus-build fleet pull` writes the repo files. | FR-OPS-008, *16* ?5 |
| D-0026 | `janus-build` is the build-host life cycle. A later wizard is a front end for `init`. | *16* |
| D-0027 | `janus` runs on the router. `janus-build` runs on the build host. | *16* |
| D-0028 | The license is Apache-2.0. User-facing text is English, then Russian, then Persian. | `LICENSE`, *00* ?9 |
| D-0029 | The Yanyu Janus image uses Limine on legacy BIOS and GPT. The measured OpenWrt install uses GRUB. UEFI and systemd-boot do not apply. | *10* ?3.1, *05* ?2, *09* ?4 |

## 2. Undecided

None.
