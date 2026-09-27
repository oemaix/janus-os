# 02 — Use Cases

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

## 1. Personas

| Persona | Description | Nix skill | Network skill |
|---------|-------------|-----------|---------------|
| **Mei** — home user in mainland China | Wants stable circumvention for the whole household, IPTV from the carrier must keep working, minimal maintenance. Builds on a laptop that has a working tunnel. | Low: copies and edits the example | Medium: knows PPPoE, VLAN for IPTV |
| **Jonas** — NixOS enthusiast | Runs a home lab, wants the router in the same flake as everything else, expects escape hatches to raw NixOS. | High | Medium |
| **Priya** — small-office operator | Router sits behind a carrier NAT she cannot configure; needs remote access, traffic visibility per VLAN. | Low | High |
| **Builder** — the project developer | Maintains board profiles, modules, tests, release images. | High | High |

## 2. Use cases

Each use case lists its primary actor, precondition, main flow and the
requirements it drives (see *03 — Requirements*).

### UC-01 First build and flash

* **Actor:** Mei, Jonas
* **Precondition:** Build host with Nix (flakes enabled) and unrestricted
  network; target Board and SD card/eMMC.
* **Flow:**
  1. Clone the Janus flake template (`nix flake init -t github:…/janus-os`).
  2. Edit `configuration.nix`: board, WAN mode, LAN subnet, SSH public key,
     subscription URL.
  3. Run `nix build .#images.<host>`; obtain `result/janus-<host>.img`.
  4. Flash to media; insert; power on.
  5. SSH into the router at the configured LAN address with the private key.
* **Drives:** FR-CFG-*, FR-BLD-*, FR-ACC-001

### UC-02 PPPoE data + DHCP IPTV on one uplink

* **Actor:** Mei
* **Release:** after 1.0 (WAN VLAN, `iptv` role, IGMP)
* **Precondition:** Carrier delivers Internet via PPPoE on untagged/VLAN X
  and IPTV via DHCP with vendor-class option on VLAN Y.
* **Flow:** Two WAN definitions on the same physical port with different
  VLAN tags; IPTV WAN is marked `role = "iptv"` and bound to a LAN or a set of
  LAN ports; IGMP proxy enabled between them; default route stays on PPPoE.
  The VLAN model is general; IPTV is one use of it, not a separate feature.
* **Drives:** FR-NET-005, FR-NET-020

### UC-03 Multiple LANs with different trust levels

* **Actor:** Priya
* **Flow:** Define `lan`, `guest`, `iot` LANs on VLANs of one trunk port;
  each gets its own subnet, DHCP range, static leases and firewall zone.
  Guest and IoT may reach WAN but not each other or `lan`.
* **Drives:** FR-NET-010..016, FR-FW-*

### UC-04 Publish an internal service

* **Actor:** Priya
* **Flow:** Add a port-forward from WAN TCP 443 to an internal host; Janus
  emits NAT rule and matching firewall accept.
* **Drives:** FR-NET-017, FR-FW-004

### UC-05 Subscription-based circumvention with automatic refresh

* **Actor:** Mei
* **Flow:** Configure two subscriptions with names and refresh intervals.
  At build time, the build host fetches the node lists and embeds a snapshot
  in the image. At runtime, a timer refreshes the lists through the current
  tunnel and reloads the Engine. Nodes from subscriptions are read-only in
  the configuration.
* **Drives:** FR-PRX-001..008

### UC-06 Group nodes by region and by application

* **Actor:** Mei, Jonas
* **Flow:** Define groups `JP`, `US`, `HK`, `SG` via regex over node names;
  define `Streaming` group as a manual list; assign a selection strategy
  (`url-test`) to each group. Example configuration ships commented-out
  templates for `Telegram`, `Gemini`, `Claude`, `Netflix`.
* **Drives:** FR-PRX-010..015

### UC-07 Rule-based routing with domestic bypass

* **Actor:** Mei
* **Flow:** Set traffic mode `rule-based`. Rules: `geosite:cn` and
  `geoip:cn` → `direct`; `geosite:netflix` → group `Streaming`;
  `geosite:category-ads` → `block`; default → group `Auto`.
* **Drives:** FR-PRX-020..025

### UC-08 DNS that does not trust the carrier

* **Actor:** Mei
* **Flow:** Domestic domains resolve via a domestic public encrypted
  resolver (CDN-friendly); everything else resolves through the tunnel via
  encrypted DNS or fake-IP; the carrier's DHCP/PPPoE-provided resolvers are
  ignored (or used only as an explicit fallback).
* **Drives:** FR-DNS-*

### UC-09 Change WAN and LAN port assignment

* **Actor:** Jonas
* **Flow:** Edit the interface mapping in `configuration.nix`, rebuild the
  image (or system closure) on the build host, deploy. No on-device build.
* **Drives:** FR-CFG-005, FR-BLD-004, FR-OPS-001

### UC-10 Survive power loss

* **Actor:** all
* **Flow:** Power is cut at an arbitrary moment. On next boot, read-only file
  systems mount unchanged; the state partition is fsck'd and mounted;
  services start with the last successfully written data.
* **Drives:** FR-STO-*, NFR-REL-*

### UC-11 Remote access from behind carrier NAT

* **Actor:** Priya
* **Flow:** Configure a WireGuard peer to a VPS (or a mesh backend); the
  router establishes an outbound tunnel at boot; SSH is reachable through it.
* **Drives:** FR-RA-*

### UC-12 Watch traffic per interface

* **Actor:** Priya
* **Flow:** Enable monitoring on `wan0`, `lan`, `guest`; view per-interface
  counters and top talkers via SSH tools; optionally export IPFIX to a
  collector.
* **Drives:** FR-MON-*

### UC-13 Add a 4G dongle as a backup uplink

* **Actor:** Jonas
* **Flow:** Declare a `wwan` Peripheral by USB ID; declare a WAN with
  `mode = "wwan"` and `role = "backup"`; Janus performs mode switch, brings
  up the link, and fails over when the primary WAN's health check fails.
* **Drives:** FR-HW-003, FR-NET-007

### UC-14 Bring up a new Board

* **Actor:** Builder
* **Flow:** Add a board profile module (kernel, firmware, boot partition
  layout, default interface names), add it to the support matrix, add a
  build-and-boot test.
* **Drives:** FR-HW-001, FR-BLD-005

### UC-15 IPv6 without leaks

* **Actor:** Mei
* **Flow:** Choose an IPv6 mode. In `tunnel-aware` mode, IPv6 is delivered
  to LAN but AAAA answers and IPv6 flows follow the same routing rules as
  IPv4, and stable-privacy addressing is enforced. In `disabled` mode no IPv6
  reaches LAN hosts.
* **Drives:** FR-NET-030..034, FR-SEC-010

### UC-16 Vendor rotates the subscription URL

* **Actor:** Mei
* **Flow:** The vendor replaces the URL. On the router, `janus override set
  proxy.subscriptions.providerA.url <new>`. The refresh runs with the new
  URL. `janus status` shows drift. Later, on the laptop, `janus override
  export` updates `secrets.yaml` and the next image has no drift.
* **Drives:** FR-OPS-007, FR-OPS-008, FR-SEC-002

### UC-17 Add a printer lease without rebuilding

* **Actor:** Mei
* **Flow:** `janus override set network.lans.home.dhcp.staticLeases.printer
  '{"mac":"…","ip":"192.168.10.6"}'`. The DHCP renderer reloads. The lease
  is in the override file and in the next backup.
* **Drives:** FR-OPS-007, FR-OPS-008

### UC-18 Check that DNS is not poisoned

* **Actor:** Mei
* **Flow:** `janus dns check` probes a domestic name, a foreign name, and a
  name commonly forged by pollution. It reports where each query went and
  whether the answer is usable. Mei switches `fakeIp.enable` only if an
  application breaks, not as a debugging guess.
* **Drives:** FR-DNS-010, FR-DNS-011

### UC-19 Several routers, one subscription

* **Actor:** Jonas
* **Flow:** One private git repo defines `potato` and `zero`. Both import
  `common/proxy.nix`, which holds the shared subscription. Each host file
  sets only the board, ports, and LAN. `git init` on the laptop is enough
  to build; pushing the repo to a remote is how the laptop can be replaced.
  When the vendor rotates the URL, Jonas edits that one secret, commits,
  and runs `janus-build fleet apply`. Both reachable routers refresh. He does
  not paste the URL into each router. An override made on one router
  comes back with `janus-build fleet pull` on the laptop, which writes the
  sops key and that host's `overrides.nix`.
* **Drives:** FR-CFG-010, FR-CFG-011, FR-OPS-012, ADR-0021

### UC-20 Log a LAN device for a few days

* **Actor:** Mei
* **Precondition:** `janus.monitoring.audit.enable = true` in the image.
* **Flow:** A device on the LAN may be reporting to a network the owner
  wants to see. `janus audit start` records connection metadata. After a
  few days, `janus audit stop` ends it without a rebuild. Mei copies the
  log off the router and reads it elsewhere. Payloads are not recorded.
* **Drives:** FR-MON-007
