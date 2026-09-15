# 03 — Software Requirements Specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

Key words MUST / SHOULD / MAY follow RFC 2119. Priority: **P1** required for
1.0, **P2** planned, **P3** desirable.

## 1. Configuration (CFG)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-CFG-001 | The system MUST be fully described by a NixOS configuration consumed by a Nix flake; no runtime configuration files outside the Nix store are authoritative, except *data* (see FR-OPS-003). | P1 |
| FR-CFG-002 | All Janus-specific options MUST live under the `janus.*` namespace and MUST use router vocabulary (WAN, LAN, VLAN, zone, node, group, rule). | P1 |
| FR-CFG-003 | A user MUST be able to produce a working configuration by editing only values in the shipped example, without knowing the Nix language beyond literals, lists and attribute sets. | P1 |
| FR-CFG-004 | Every `janus.*` option MUST have a description, a type and, where sensible, a default and an example; the reference document MUST be generated from module definitions. | P1 |
| FR-CFG-005 | Physical ports MUST be referenced by stable, user-given names mapped to board-specific interface names; swapping WAN/LAN ports MUST be a configuration change only. | P1 |
| FR-CFG-006 | The configuration MAY be split across multiple files/modules; the flake MUST import them so that a single `nix build` produces the image. | P1 |
| FR-CFG-007 | Users MAY set arbitrary NixOS options alongside `janus.*` options; Janus MUST NOT silently override them and SHOULD emit an assertion on known conflicts. | P2 |
| FR-CFG-008 | The complete flake source tree used to build an image (`flake.nix`, `flake.lock`, `configuration.nix` and all imported modules, whether single-file or modular) MUST be embedded read-only in the image at `/etc/janus/source`, so the exact image can be rebuilt from the device alone. Sources outside the flake tree MUST produce an evaluation warning. Embedding MAY be disabled by the user. | P1 |
| FR-CFG-009 | Configuration MUST be validated at evaluation time with assertions producing actionable messages (e.g. overlapping subnets, unknown port name, node referenced by a rule but not defined). | P1 |

## 2. Build and deployment (BLD)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-BLD-001 | The flake MUST expose a flashable image per host (`images.<host>`), a system closure (`nixosConfigurations.<host>`) and a template (`templates.default`). | P1 |
| FR-BLD-002 | Building for aarch64 boards from an x86_64 build host MUST be supported (native builder, `binfmt` emulation or cross-compilation). | P1 |
| FR-BLD-003 | Build-time fetches that depend on unrestricted network access (subscriptions snapshot, Geo data, upstream sources) MUST happen on the build host only. | P1 |
| FR-BLD-004 | Any rebuild targeting the running Board that would require compiling or downloading on the Board MUST fail with a clear error. | P1 |
| FR-BLD-005 | Every supported Board MUST have an automated build test; Tier-1 boards MUST additionally have a boot/route test. | P2 |
| FR-BLD-006 | Images MUST be reproducible: two builds of the same flake revision with identical inputs MUST yield identical system closures. Subscription snapshots are excluded from this guarantee and MUST be pinned by hash when reproducibility is desired. | P2 |
| FR-BLD-007 | The image MUST NOT contain compilers, linkers, package managers' network fetchers or development headers. | P1 |

## 3. Storage (STO)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-STO-001 | `/` and `/nix` MUST be mounted read-only. | P1 |
| FR-STO-002 | Each mounted file system MUST reside on its own partition; overlay-over-shared-partition designs MUST NOT be used. | P1 |
| FR-STO-003 | Default file system type MUST be f2fs for all partitions except those the Board firmware requires otherwise (e.g. FAT boot partition). | P1 |
| FR-STO-004 | Exactly one persistent read-write partition (the state partition) MUST exist, mounted at `/var`. `/run`, `/tmp` MUST be tmpfs. | P1 |
| FR-STO-005 | Users MAY override partition sizes, file system types and the mount table via `janus.storage.*`, within constraints enforced by assertions. | P2 |
| FR-STO-006 | The state partition MUST be checked and repaired automatically at boot. | P1 |
| FR-STO-007 | Persistent writes MUST be bounded (journal size caps, log rotation, flow-data retention) so the state partition cannot fill. | P1 |

## 4. Networking (NET)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-NET-001 | WAN addressing modes MUST include `static`, `dhcp`, `pppoe`. | P1 |
| FR-NET-002 | WAN mode `wwan` (4G/5G peripheral) MUST be supported. | P2 |
| FR-NET-003 | Multiple concurrent WANs MUST be supported, each with a role: `default`, `iptv`, `backup`, `custom`. | P1 |
| FR-NET-004 | DHCP client WANs MUST allow custom options (vendor class, client ID, requested options) for carrier IPTV. | P1 |
| FR-NET-005 | WANs MUST be bindable to VLAN sub-interfaces of a physical port. | P1 |
| FR-NET-006 | PPPoE MUST support username/password, MTU/MRU, LCP echo tuning and IPv6CP. | P1 |
| FR-NET-007 | WAN health checks and failover between `default` and `backup` MUST be supported. | P2 |
| FR-NET-010 | Multiple LANs MUST be supported; each LAN is a bridge of ports and/or VLAN sub-interfaces with its own IPv4 subnet. | P1 |
| FR-NET-011 | Each LAN MUST offer a DHCPv4 server with range, lease time, DNS/gateway options and static leases (MAC → IP, optional hostname). | P1 |
| FR-NET-012 | Static leases MUST also register in local DNS as `<hostname>.<lan-domain>`. | P2 |
| FR-NET-013 | Bridging of Wi-Fi peripherals into a LAN (AP mode) MUST be supported where the peripheral supports AP mode. | P2 |
| FR-NET-014 | 802.1Q VLANs MUST be supported on any Ethernet port, tagged and untagged. | P1 |
| FR-NET-015 | Source NAT (masquerade) from LANs to WANs MUST be enabled by default and be disableable per LAN/WAN pair. | P1 |
| FR-NET-016 | Hairpin NAT (NAT reflection) SHOULD be supported for port forwards. | P2 |
| FR-NET-017 | Port forwards (DNAT) MUST be declarable with protocol, external port/range, internal host/port, optional source restriction. | P1 |
| FR-NET-020 | IGMP/MLD proxying between an IPTV WAN and selected LANs MUST be supported. | P2 |
| FR-NET-030 | IPv6 MUST be configurable per WAN: `disabled`, `dhcpv6-pd`, `slaac`, `static`, `passthrough` (PPPoE IPv6CP + PD). | P1 |
| FR-NET-031 | IPv6 on LAN MUST be configurable: `disabled`, `ula-only`, `delegated` (prefix from PD), with RA and DHCPv6 options. | P1 |
| FR-NET-032 | Stable-privacy (RFC 7217) and temporary addresses (RFC 8981) MUST be the default; EUI-64 MUST NOT be used by default. | P1 |
| FR-NET-033 | In `rule-based` and `proxy-all` modes, IPv6 flows MUST be subject to the same routing rules as IPv4 (no IPv6 bypass leak). | P1 |
| FR-NET-034 | Inbound IPv6 MUST be default-deny, with the same zone rule model as IPv4. | P1 |

## 5. Firewall (FW)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-FW-001 | The firewall MUST be zone-based; every interface belongs to exactly one zone. | P1 |
| FR-FW-002 | Default policies MUST be: `lan → wan` accept, `wan → *` drop, `lan → router` accept limited to configured services, inter-LAN drop unless allowed. | P1 |
| FR-FW-003 | Rules MUST be expressible as zone-to-zone with protocol, ports, source/destination sets, action `accept`/`drop`/`reject`. | P1 |
| FR-FW-004 | Port forwards MUST automatically create the necessary accept rules. | P1 |
| FR-FW-005 | Users MAY inject raw nftables snippets at defined hook points. | P2 |
| FR-FW-006 | Connection tracking helpers and SYN-flood/rate limits SHOULD be configurable. | P3 |

## 6. Proxy / circumvention (PRX)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-PRX-001 | Supported outbound protocols MUST include: VLESS (with XTLS-RPRX-Vision and REALITY), Trojan, Shadowsocks (AEAD; with `simple-obfs` and `v2ray-plugin` where the engine supports them). | P1 |
| FR-PRX-002 | The engine MUST be selectable: `sing-box` (default) or `xray`. Features unsupported by the chosen engine MUST fail at evaluation with a message. | P1 |
| FR-PRX-003 | Subscriptions MUST be declared with name, URL, refresh schedule (interval in minutes/hours or cron expression) and optional user-agent/headers. | P1 |
| FR-PRX-004 | Supported subscription formats MUST include base64 share-link lists (`ss://`, `vless://`, `trojan://`), Clash/Clash.Meta YAML and sing-box JSON. | P1 |
| FR-PRX-005 | The build MUST fetch each subscription on the build host and embed the snapshot in the image so the router is functional at first boot. | P1 |
| FR-PRX-006 | At runtime, a scheduled job MUST refresh subscriptions (through the active tunnel when necessary), validate, atomically replace the cache and reload the engine. Failed refreshes MUST keep the previous data. | P1 |
| FR-PRX-007 | Nodes originating from subscriptions MUST NOT be editable by the user; overrides are expressed as group/rule configuration. | P1 |
| FR-PRX-008 | Manually defined nodes MUST be supported with the full protocol option set. | P1 |
| FR-PRX-010 | Each subscription MUST implicitly form a group. | P1 |
| FR-PRX-011 | Groups by matcher MUST be supported with kinds `regex`, `glob`, `peg` (Janet PEG), scoped to one or more subscriptions or to all nodes. | P1 |
| FR-PRX-012 | Groups by manual node list MUST be supported and MAY nest other groups. | P1 |
| FR-PRX-013 | Group selection strategies MUST include `manual` (fixed default with SSH override), `url-test`, `fallback`, `load-balance`. | P1 |
| FR-PRX-014 | The example configuration MUST ship region templates (JP, US, HK, EU, UK, SG, IN) and commented-out usage templates (Telegram, Gemini, Claude, Netflix, …). | P1 |
| FR-PRX-015 | An empty group (matcher matched nothing) MUST be a warning at build time and a runtime fallback to `direct` or a configured alternative, never a crash. | P1 |
| FR-PRX-020 | A traffic mode master switch MUST exist: `direct`, `rule-based`, `proxy-all`. | P1 |
| FR-PRX-021 | Routing rules MUST be an ordered list of predicate → target, where predicates include domain (exact/suffix/keyword/regex), GeoSite category, IP CIDR, GeoIP country, destination port, source LAN, source IP, transport protocol, and targets include a group, `direct`, `block`. | P1 |
| FR-PRX-022 | Transparent interception MUST cover TCP and UDP from all LANs designated as proxied, for IPv4 and IPv6. | P1 |
| FR-PRX-023 | Per-LAN opt-out of proxying MUST be supported. | P2 |
| FR-PRX-024 | Geo data MUST be embedded at build and refreshable at runtime as data. | P1 |
| FR-PRX-025 | Rule sets in the engine's native compiled format SHOULD be used for performance. | P2 |

## 7. DNS (DNS)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-DNS-001 | The router MUST be the only resolver advertised to LAN clients and MUST intercept outbound plaintext DNS to enforce policy (configurable). | P1 |
| FR-DNS-002 | Carrier-provided resolvers (from DHCP/PPPoE) MUST NOT be used by default; a policy option MUST allow `never`, `fallback-only`, `domestic-only`. | P1 |
| FR-DNS-003 | Split resolution MUST be supported: domestic domain sets → domestic resolver; everything else → remote resolver via tunnel or fake-IP. | P1 |
| FR-DNS-004 | Encrypted transports (DoH, DoT, DoQ) MUST be supported for both domestic and remote resolvers, with a policy `prefer` or `require`. | P1 |
| FR-DNS-005 | Fake-IP for proxied domains MUST be supported and be the default in `rule-based` mode, with an exclusion list. | P1 |
| FR-DNS-006 | DNS pollution defenses MUST include: never sending foreign domains to domestic/carrier resolvers, ignoring answers from unexpected sources, and optional answer sanity checks (bogus IP list). | P1 |
| FR-DNS-007 | Local overrides (hosts entries, per-domain forwarders) and static-lease hostnames MUST be supported. | P2 |
| FR-DNS-008 | EDNS Client Subnet handling MUST be configurable to protect privacy while allowing CDN accuracy for domestic resolvers. | P3 |

## 8. Monitoring (MON)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-MON-001 | Per-interface byte/packet counters MUST be available and persisted with bounded retention. | P1 |
| FR-MON-002 | The monitored interface set and scope (counters only, per-host accounting, flow export) MUST be configurable. | P1 |
| FR-MON-003 | Flow export (IPFIX/NetFlow v9) to a collector SHOULD be supported. | P2 |
| FR-MON-004 | A Prometheus-compatible metrics endpoint MAY be enabled on the management zone. | P3 |
| FR-MON-005 | Proxy engine health (group latency, selected node) MUST be observable via SSH CLI. | P1 |

## 9. Remote access (RA)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-RA-001 | An outbound-initiated remote-access tunnel MUST be supported so the router is reachable from behind upstream NAT. | P1 |
| FR-RA-002 | Backends MUST include WireGuard to a user-controlled endpoint; MAY include a mesh service (Tailscale/Headscale) and reverse SSH. | P1/P3 |
| FR-RA-003 | Remote-access interfaces MUST belong to the `mgmt` zone by default and expose only SSH unless configured otherwise. | P1 |

## 10. Access and management (ACC)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-ACC-001 | SSH MUST be the management interface; at least one authorized public key MUST be configured or evaluation fails. | P1 |
| FR-ACC-002 | Password authentication MUST be disabled by default; enabling it MUST require an explicit option and MUST NOT be possible without at least one key. | P1 |
| FR-ACC-003 | SSH MUST listen on LAN and `mgmt` zones only by default. | P1 |
| FR-ACC-004 | A `janus` CLI MUST exist on the router for status, group selection, data refresh and diagnostics. | P1 |
| FR-ACC-005 | A GUI is out of scope for 1.0. | — |

## 11. Hardware (HW)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-HW-001 | Boards MUST be selected by a single option; a board profile MUST provide kernel, firmware, boot layout, default port mapping. | P1 |
| FR-HW-002 | Peripherals MUST be declared by class (`wifi`, `nic`, `wwan`, `bluetooth`, `hmi`) and identified by USB/PCI ID or bus path. | P1 |
| FR-HW-003 | `wwan` peripherals MUST support Ethernet-mode (ECM/RNDIS/NCM) and QMI/MBIM operation and MAY expose an AT control channel for status (signal, operator, SMS). | P2 |
| FR-HW-004 | `hmi` peripherals MUST be able to display status pages (WAN state, IP, tunnel health) and MAY bind buttons to actions (e.g. cycle group, reboot). | P3 |
| FR-HW-005 | Unsupported peripherals MUST be reported at evaluation with a pointer to the support matrix. | P2 |

## 12. Operations (OPS)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-OPS-001 | The only way to change *configuration* MUST be rebuild-and-deploy from the build host. | P1 |
| FR-OPS-002 | Deployment methods MUST include full-image re-flash; SHOULD include remote closure deployment (`nixos-rebuild --target-host`) with the store temporarily remounted read-write by the deployment tool; MAY include A/B image slots. | P1/P2/P3 |
| FR-OPS-003 | *Data* (subscription cache, Geo data, leases, statistics) MUST live on the state partition and MUST be refreshable at runtime without rebuild. | P1 |
| FR-OPS-004 | The `janus` CLI MUST allow: `status`, `refresh subscriptions`, `refresh geodata`, `select <group> <node>`, `test <group>`, `wan restart <name>`, `logs`. | P1 |
| FR-OPS-005 | Boot MUST succeed with an empty or corrupted state partition (re-initialize from embedded snapshots). | P1 |
| FR-OPS-006 | A factory-reset action (wipe state partition) MUST be available via CLI and MAY be bound to an HMI button. | P2 |

## 13. Security (SEC)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-SEC-001 | No services other than SSH (and configured remote-access) MUST listen on WAN. | P1 |
| FR-SEC-002 | Secrets (PPPoE password, node credentials, WireGuard keys) MUST be supported either inline (accepting they are world-readable in the store) or via a secrets file on the state partition referenced by path; the choice MUST be documented. | P1 |
| FR-SEC-003 | The system MUST run with a read-only root and store, no setuid helpers beyond what NixOS requires, and systemd hardening on Janus services. | P1 |
| FR-SEC-010 | IPv6 privacy controls (FR-NET-032/033) MUST be enabled by default. | P1 |
| FR-SEC-011 | Outbound telemetry from any bundled component MUST be disabled. | P1 |

## 14. Non-functional requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-001 | Image size (compressed) | ≤ 400 MiB for Tier-1 boards |
| NFR-002 | Boot to routing (power-on → first NAT'd packet) | ≤ 45 s on Raspberry Pi 4 |
| NFR-003 | Idle RAM footprint | ≤ 256 MiB including engine with 500 nodes |
| NFR-004 | NAT throughput | Line rate for 1 GbE on NanoPi R4S; ≥ 900 Mbit/s on RPi 4 |
| NFR-005 | Engine throughput (VLESS+Vision) | ≥ 300 Mbit/s on NanoPi R4S |
| NFR-REL-001 | Power-loss robustness | 100 random power cuts without re-flash |
| NFR-REL-002 | Subscription refresh failure tolerance | Router remains functional with last good data indefinitely |
| NFR-006 | Documentation | Every option documented; every board in the matrix has a tested image |
| NFR-007 | Supported architectures | aarch64-linux (Tier 1), armv7l-linux and riscv64-linux (Tier 2/3) |
