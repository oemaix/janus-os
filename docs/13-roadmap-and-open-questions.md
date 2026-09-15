# 13 — Roadmap and Open Questions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

## 1. Phased roadmap

### Phase 0 — Foundations (repo skeleton)

* Flake, `mkRouter`, `x86_64-test` board, module skeleton with option
  types and assertions, options-doc generation, CI for eval tests.
* Storage: partition model, read-only root via `/etc` overlay, image
  builder with f2fs + FAT, VM boot test.

### Phase 1 — Router core (MVP, no proxy)

* Ports/VLANs, WAN `dhcp`/`static`/`pppoe`, multi-WAN roles, LANs with
  DHCPv4 + static leases, zone firewall, NAT, port forwards, IPv6 modes
  `disabled`/`ula-only`/`delegated`, IGMP proxy.
* SSH key-only, `janus` CLI (`status`, `wan`, `lan`, `fw`, `logs`).
* Boards: NanoPi R4S, RPi 4 (Tier 1).
* Monitoring: counters + vnstat.

### Phase 2 — Circumvention

* Canonical node model, Janet normalizer (share links, Clash, sing-box),
  matchers (regex, glob, PEG), groups, rules, traffic modes.
* sing-box renderer, TUN interception v4+v6, fail-closed.
* DNS policy layer (split, encrypted, fake-IP, carrier-resolver policy,
  plaintext interception).
* Build-time snapshot, runtime refresh with rollback, Geo data pipeline.
* Example configuration templates (regions, usages).

### Phase 3 — Breadth

* Xray renderer with capability assertions.
* WWAN peripherals (ECM/NCM/RNDIS, QMI/MBIM), backup WAN failover.
* Wi-Fi AP peripherals.
* Remote access: WireGuard; optional Tailscale.
* Boards: RPi 3, Le Potato (Tier 2).
* Remote closure deployment (`janus deploy`).

### Phase 4 — Polish

* HMI daemon (status pages, buttons).
* Flow export (IPFIX), Prometheus endpoint.
* VisionFive 2, RPi 2 (Tier 3).
* A/B image slots.
* Secrets integration (sops-nix/agenix).
* GUI exploration (read-only status page first).

## 2. Open questions from the requirement note — with proposed answers

| # | Question (from note) | Proposed answer | Status |
|---|----------------------|-----------------|--------|
| Q1 | Should `configuration.nix` be split into several modular files? | Support both. Template ships one file for beginners; `mkRouter` accepts a module list; docs show a split layout (`network.nix`, `proxy.nix`, `hardware.nix`) for larger setups. | Decided (FR-CFG-006) |
| Q2 | "`configuration.nix` (single file or modular set) should be copied into the image" | The complete flake source tree that produced the image — `flake.nix`, `flake.lock`, `configuration.nix` and every imported module — is embedded read-only at `/etc/janus/source` (`janus.system.embedSource`, default on). Whole-tree embedding is required because modular configurations import by relative path and reproducibility needs the lock file; with flakes it costs one store symlink. Files outside the flake tree are not captured (warning at evaluation); inline secrets become visible there, which is one more reason the example uses `…File` options. | Decided (FR-CFG-008) |
| Q3 | Where should mutable files live — `/run`, `/var`, other? | `/var` on a dedicated rw f2fs state partition. `/run` is tmpfs and lost at reboot, so it is wrong for subscriptions/Geo data. | Decided (FR-STO-004) |
| Q4 | Is "the only way to apply changes is nixos-rebuild" compatible with automatic subscription updates? | Split into *configuration* (rebuild) vs *data* (runtime refresh). See *12 — Operations §1*. `nixos-rebuild` on the Board is disabled entirely; rebuilds happen on the build host. | Decided (ADR-0002) |
| Q5 | Reuse NixOS NetworkManager network definitions? | No. NetworkManager is host-oriented. Janus lowers to systemd-networkd + nftables; raw `systemd.network.*` remains available as escape hatch. | Decided (ADR-0004) |
| Q6 | Better terms than direct / rule-based / global? | `direct`, `rule-based`, `proxy-all`. Alternatives considered: `bypass`/`split`/`tunnel-all`. | Proposed; confirm |
| Q7 | Which DNS policies could users ask for? | Enumerated in *07 §7.2*: carrier-resolver policy, encryption policy, domestic/remote resolver sets, fake-IP, AAAA handling, plaintext interception, DoT/DoH blocking, overrides, ECS. | Proposed |
| Q8 | sing-box or Xray — user-selectable? | Yes; canonical model with two renderers; sing-box default. | Decided (ADR-0006) |
| Q9 | What to call the device / the add-ons? | **Board** / **Peripheral**. | Proposed; confirm |
| Q10 | How to organize 4G dongles that act as Ethernet NICs but also speak AT? | One `wwan` Peripheral class with `mode` (ecm/ncm/rndis/qmi/mbim) and optional AT control channel; WAN `mode = "wwan"` references it. | Proposed (10 §4.2) |
| Q11 | Which Wi-Fi dongle models? | Initial matrix in *10 §4.3* (MT7612U, MT7921AU); mainline-driver-only policy. | Proposed |
| Q12 | IPv6 and carrier/government monitoring | Policy-driven IPv6 with `disabled` default when tunneling; stable-privacy; AAAA stripping; tunnel-aware interception; optional NPTv6. | Proposed (06 §9) |
| Q13 | Grouping by PEG in Janet — worth the dependency? | Yes: Janet is small (~1 MB), gives PEG + a real scripting language for normalizer and runtime renderer, replacing ad-hoc shell/jq. | Decided (ADR-0008) |
| Q14 | Remote access behind NAT — which mechanism? | WireGuard to a user endpoint as P1; Tailscale/Headscale P3; reverse SSH P3. | Proposed |

## 3. Undecided design points (need ADRs)

| ID | Topic | Options | Leaning |
|----|-------|---------|---------|
| ADR-0009 | DHCP/RA server | Kea vs dnsmasq (DHCP-only) vs networkd's built-in DHCP server | dnsmasq DHCP-only for size and RA maturity, unless Kea's lease durability proves necessary |
| ADR-0010 | Image assembly tool | custom f2fs builder vs `systemd-repart` | custom now; migrate when repart can populate f2fs |
| ADR-0011 | Transparent proxy inbound | TUN vs TPROXY | TUN (sing-box) for UDP simplicity; TPROXY on Xray |
| ADR-0012 | Subscription build-time fetch purity | impure by default vs require hash | impure default with `snapshot.hash` opt-in |
| ADR-0013 | Persistent journal default | volatile vs persistent capped | volatile |
| ADR-0014 | Secrets in flake | none vs sops-nix vs agenix | defer; file-based first |
| ADR-0015 | WWAN control plane | ModemManager vs libqmi/libmbim CLIs | CLIs (slimmer); ModemManager optional |
| ADR-0016 | Fail mode default when engine is down | closed vs open | closed |

## 4. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| NixOS read-only `/etc` overlay still maturing | boot issues on some releases | pin release; VM test; fallback to tmpfs `/etc` with copied tree |
| f2fs population without root in Nix sandbox (`sload.f2fs`) has edge cases (xattrs, symlinks) | broken images | golden tests mounting images in VM; erofs fallback for ro partitions |
| Emulated aarch64 builds are slow for user changes | poor UX | rely on binary cache; document native/cross options; keep Janus-specific packages tiny |
| Engine upstream churn (sing-box config format) | renderer breakage | pin engine version per release; golden tests |
| Subscription providers' formats vary wildly | parse failures | normalizer test corpus; `format` override; permissive parsing with warnings |
| armv7l/riscv64 without cache | hours-long builds | Tier 3, clearly labelled |
