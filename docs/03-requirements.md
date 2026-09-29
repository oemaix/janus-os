# 03 — Software Requirements Specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-29 |

Key words MUST / SHOULD / MAY follow RFC 2119. Priority: **P1** required for
1.0, **P2** planned, **P3** desirable.

## 1. Configuration (CFG)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-CFG-001 | The system shape MUST be described by a NixOS configuration consumed by a Nix flake. Runtime files outside the Nix store are authoritative only for *data* (FR-OPS-003) and *hot overrides* (FR-OPS-007). | P1 |
| FR-CFG-002 | All Janus-specific options MUST live under the `janus.*` namespace and MUST use router vocabulary (WAN, LAN, VLAN, zone, node, group, rule). | P1 |
| FR-CFG-003 | A user MUST be able to produce a working configuration by editing only values in the shipped example, without knowing the Nix language beyond literals, lists and attribute sets. | P1 |
| FR-CFG-004 | Every `janus.*` option MUST have a description, a type and, where sensible, a default and an example; the reference document MUST be generated from module definitions. | P1 |
| FR-CFG-005 | Physical ports MUST be referenced by stable, user-given names mapped to board-specific interface names; swapping WAN/LAN ports MUST be a configuration change only. | P1 |
| FR-CFG-006 | The configuration MAY be split across multiple files/modules; the flake MUST import them so that a single `nix build` produces the image. | P1 |
| FR-CFG-007 | Users MAY set arbitrary NixOS options alongside `janus.*` options; Janus MUST NOT silently override them and SHOULD emit an assertion on known conflicts. | P2 |
| FR-CFG-008 | The complete flake source tree used to build an image (`flake.nix`, `flake.lock`, `configuration.nix` and all imported modules, whether single-file or modular) MUST be embedded read-only in the image at `/etc/janus/source`, so the exact image can be rebuilt from the device alone. Sources outside the flake tree MUST produce an evaluation warning. Embedding MAY be disabled by the user. | P1 |
| FR-CFG-009 | Configuration MUST be validated at evaluation time with assertions producing actionable messages (e.g. overlapping subnets, unknown port name, node referenced by a rule but not defined). | P1 |
| FR-CFG-010 | The user's config project MUST be a local git repository, because flakes ignore uncommitted files. A remote git host is recommended and MUST NOT be required to build an image. | P1 |
| FR-CFG-011 | One private repo MUST be able to describe several routers (`nixosConfigurations.<host>`) and MUST be able to import shared modules (for example one subscription used by two routers). The entry file MUST be named `configuration.nix`. | P1 |

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
| FR-NET-003 | Multiple concurrent WANs MUST be supported, each with a role: `default`, `backup`, `custom`. Role `iptv` is specified and deferred until after 1.0. | P1 |
| FR-NET-004 | DHCP client WANs MUST allow custom options (vendor class, client ID, requested options) for carrier IPTV. | P1 |
| FR-NET-005 | WANs MUST be bindable to VLAN sub-interfaces of a physical port. This is the same VLAN mechanism as FR-NET-014, not an IPTV-only mode. Implementation is deferred until after 1.0. | P2 |
| FR-NET-006 | PPPoE MUST support username/password, MTU/MRU, LCP echo tuning and IPv6CP. | P1 |
| FR-NET-007 | WAN health checks and failover between `default` and `backup` MUST be supported. | P2 |
| FR-NET-010 | Multiple LANs MUST be supported; each LAN is a bridge of ports and/or VLAN sub-interfaces with its own IPv4 subnet. | P1 |
| FR-NET-011 | Each LAN MUST offer a DHCPv4 server with range, lease time, DNS/gateway options and static leases (MAC → IP, optional hostname). | P1 |
| FR-NET-012 | Static leases MUST also register in local DNS as `<hostname>.<lan-domain>`. | P2 |
| FR-NET-013 | Bridging of Wi-Fi peripherals into a LAN (AP mode) MUST be supported where the peripheral supports AP mode. | P2 |
| FR-NET-014 | 802.1Q VLANs MUST be supported on LAN ports in 1.0, tagged and untagged. | P1 |
| FR-NET-015 | Source NAT (masquerade) from LANs to WANs MUST be enabled by default and be disableable per LAN/WAN pair. | P1 |
| FR-NET-016 | Hairpin NAT (NAT reflection) SHOULD be supported for port forwards. | P2 |
| FR-NET-017 | Port forwards (DNAT) MUST be declarable with protocol, external port/range, internal host/port, optional source restriction. | P1 |
| FR-NET-020 | IGMP/MLD proxying between an IPTV WAN and selected LANs MUST be supported. Deferred until after 1.0, together with WAN VLAN and the `iptv` role. | P2 |
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
| FR-PRX-001 | Supported outbound protocols MUST include: VLESS (with XTLS-RPRX-Vision and REALITY), VMess, Trojan, Shadowsocks (AEAD; with `simple-obfs` and `v2ray-plugin` where the engine supports them). | P1 |
| FR-PRX-002 | The engine MUST be selectable: `sing-box` (default) or `xray`. Features unsupported by the chosen engine MUST fail at evaluation with a message. | P1 |
| FR-PRX-003 | Subscriptions MUST be declared with name, URL, refresh schedule (interval in minutes/hours or cron expression) and optional user-agent/headers. | P1 |
| FR-PRX-004 | Supported subscription formats MUST include base64 share-link lists (`ss://`, `vless://`, `vmess://`, `trojan://`), Clash/Clash.Meta YAML and sing-box JSON. | P1 |
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
| FR-PRX-020 | A traffic mode master switch MUST exist: `bypass`, `rule-based`, `proxy-all`. | P1 |
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
| FR-DNS-009 | DNS MUST be implemented by the selected proxy engine. A second DNS stack (mosdns, chinadns-ng, or a standalone forwarder that owns policy) MUST NOT be required. | P1 |
| FR-DNS-010 | Fake-IP MUST be a user-facing choice: `auto` (default), `on`, or `off`, independent of which engine is selected. | P1 |
| FR-DNS-011 | `janus dns check` MUST probe the live arrangement for leaks and poisoning: foreign name answered with a bogus or domestic-only address, domestic name failing closed, plaintext DNS bypass, unexpected AAAA on a proxied name. The command reports; it does not change policy. | P1 |

## 8. Monitoring (MON)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-MON-001 | Per-interface byte/packet counters MUST be available and persisted with bounded retention. | P1 |
| FR-MON-002 | The monitored interface set and scope (counters only, per-host accounting, flow export) MUST be configurable. | P1 |
| FR-MON-003 | Flow export (IPFIX/NetFlow v9) to a collector SHOULD be supported. | P2 |
| FR-MON-004 | A Prometheus-compatible metrics endpoint MAY be enabled on the management zone. | P3 |
| FR-MON-005 | Proxy engine health (group latency, selected node, last subscription refresh, last Geo refresh, and the error of a failed refresh) MUST be observable via the CLI. | P1 |
| FR-MON-006 | A failed node, a failed refresh, and drift of hot overrides MUST be visible in `janus status` without reading logs. | P1 |
| FR-MON-007 | A connection audit log MUST be available as a configuration switch, default off. When the configuration includes it, `janus audit stop` MUST disable recording without a rebuild and `janus audit start` MUST be able to turn it back on. Records are connection metadata (5-tuple, bytes, times, domain or SNI when the router already sees it), never payloads, one JSON object per line. Retention MUST be bounded and storage MUST be on the state partition. Reading and analysing the log happens off the board. | P2 |

## 9. Remote access (RA)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-RA-001 | An outbound-initiated remote-access tunnel MUST be supported so the router is reachable from behind upstream NAT. | P1 |
| FR-RA-002 | The remote-access backend MUST be Tailscale. The router joins the tailnet and dials out. `loginServer` MAY point at a Headscale the operator runs. A WireGuard tunnel to a user-controlled endpoint MAY be configured in addition. Reverse SSH is not a backend. | P1 |
| FR-RA-003 | Remote-access interfaces MUST belong to the `mgmt` zone by default and expose only SSH unless configured otherwise. | P1 |
| FR-RA-004 | A tailnet peer MUST reach SSH on the router. It MUST NOT be forwarded into `lan`, `guest`, or `iot`, and the router MUST NOT be an exit node, unless the configuration sets `advertiseRoutes` or `exitNode`. | P1 |

## 10. Access and management (ACC)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-ACC-001 | SSH MUST be the management interface; at least one authorized public key MUST be configured or evaluation fails. | P1 |
| FR-ACC-002 | Password authentication MUST be disabled by default; enabling it MUST require an explicit option and MUST NOT be possible without at least one key. | P1 |
| FR-ACC-003 | SSH MUST listen on LAN and `mgmt` zones only by default. | P1 |
| FR-ACC-004 | A `janus` CLI MUST exist on the router for status, group selection, data refresh and diagnostics. | P1 |
| FR-ACC-005 | A general configuration GUI is out of scope. A later maintenance page MAY expose status, maintenance actions, and the hot-override allowlist, and MUST NOT edit the rest of the configuration. | P3 |

## 11. Hardware (HW)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-HW-001 | Boards MUST be selected by a single option; a board profile MUST provide kernel, firmware, boot layout, default port mapping. | P1 |
| FR-HW-002 | Peripherals MUST be declared by class (`wifi`, `nic`, `wwan`, `bluetooth`, `hmi`, `power`) and identified by USB/PCI ID, I²C address, or bus path. | P1 |
| FR-HW-003 | `wwan` peripherals MUST support Ethernet-mode (ECM/RNDIS/NCM) and QMI/MBIM operation and MAY expose an AT control channel for status (signal, operator, SMS). | P2 |
| FR-HW-004 | `hmi` peripherals MUST display the pages in *15* and MUST map their controls onto the capabilities in *15*. A key MAY be bound to `refresh`, `reboot-hold`, or `factory-reset`. A missing control MUST hide the action that needed it, not a second interface. | P3 |
| FR-HW-005 | Unsupported peripherals MUST be reported at evaluation with a pointer to the support matrix. | P2 |
| FR-HW-006 | Redistributable closed-source firmware blobs required by a supported board or peripheral (Raspberry Pi wireless firmware, board boot firmware) MUST be allowed. Out-of-tree kernel drivers and device-specific mode-switch hacks MUST NOT be added to make an unlisted device work. | P1 |
| FR-HW-007 | WWAN support MUST be an allowlist of known devices and modes. A dongle that needs an undocumented or fragile setup MUST be rejected with a pointer to the matrix rather than given a best-effort configuration. | P1 |
| FR-HW-008 | A `power` peripheral class MUST support a TI INA219 on I²C. The mcuzone profile at `0x40` MUST expose readings in `janus status` and MUST shut down on a sustained low cell while discharging, at the thresholds in *10* §4.5. A negative current on that profile means discharge. The Waveshare address `0x43` is reserved. It MUST NOT expose readings or arm shutdown until a discharge measurement exists. Janus MUST NOT shut down while charging, when the sensor has failed, or because a threshold was set below those defaults. | P2 |

## 12. Operations (OPS)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-OPS-001 | Structural configuration MUST change only by rebuild-and-deploy from the build host. The board MUST NOT evaluate Nix or run `nixos-rebuild`. | P1 |
| FR-OPS-002 | Deployment methods MUST include full-image re-flash; SHOULD include remote closure deployment by `janus-build deploy` as in *09* §8.2 (`nix copy` or `nix-store --import`, with `/nix` remounted read-write for that session); MAY include A/B image slots. The board MUST NOT run `nixos-rebuild`. | P1/P2/P3 |
| FR-OPS-003 | *Data* (subscription cache, Geo data, leases, statistics) MUST live on the state partition and MUST be refreshable at runtime without rebuild. | P1 |
| FR-OPS-004 | The `janus` CLI MUST allow: `status`, `refresh subscriptions`, `refresh geodata`, `select <group> <node>`, `test <group>`, `wan restart <name>`, `logs`. | P1 |
| FR-OPS-005 | Boot MUST succeed with an empty or corrupted state partition (re-initialize from embedded snapshots). | P1 |
| FR-OPS-006 | A factory-reset action (wipe state partition) MUST be available via CLI and MAY be bound to an HMI button. | P2 |
| FR-OPS-007 | Hot overrides MUST be limited to an allowlist: subscription URL of an existing subscription, static DHCP leases of an existing LAN, Wi-Fi passphrase of an existing AP. Adding a subscription, a LAN, a port forward, or a routing rule MUST NOT be a hot override. | P1 |
| FR-OPS-008 | Hot overrides MUST be stored on the state partition, applied by a runtime renderer, included in backup, and reported as drift against the embedded configuration. The board MUST present the current set (`janus override show`) with secret values redacted, and MUST NOT emit Nix for it. There MUST NOT be a `janus override export`. `janus-build fleet pull` on the build host MUST write non-secret overrides into `hosts/<host>/overrides.nix`. It MUST name secret overrides without fetching them unless `--with-secrets` is given, in which case the router decrypts and the build host re-encrypts into the existing secret files. | P1 |
| FR-OPS-009 | Maintenance actions (refresh, temporary node selection, WAN restart, DNS check) MUST be available from the CLI and MUST NOT require a rebuild. Temporary node selection MUST survive reboot and MUST be reset when a rebuild changes that group's `default`. | P1 |
| FR-OPS-010 | The board MUST NOT store credentials for the config repo's git remote, MUST NOT push hot overrides itself, and MUST NOT fetch that repo to apply it. Pull runs on the build host over SSH. | P1 |
| FR-OPS-011 | `janus backup` is not a copy of the declarative configuration. It MUST contain the age private key and hot overrides not yet pulled. It SHOULD contain manual node selection and traffic statistics. Subscription cache, Geo cache, and logs MAY be included and MUST be recoverable without that archive by refresh or by a new boot. | P1 |
| FR-OPS-012 | `janus-build fleet apply` on the build host MUST push the committed hot-override projection over SSH and refresh a subscription whose URL changed. Secret values MUST be sent as ciphertext; the router MUST decrypt them with its own age key. Static leases in `hosts/<name>/overrides.nix` are not secrets. The build host MUST NOT decrypt. If the repo since the running image contains any other change, the command MUST change nothing unless `--only-overrides` is given, and that flag MUST still apply only the projection. An unreachable host MUST be reported and left unchanged. The board MUST NOT fetch the repo, and one board MUST NOT distribute values to another. | P2 |

## 13. Security (SEC)

| ID | Requirement | Prio |
|----|-------------|------|
| FR-SEC-001 | No services other than SSH (and configured remote-access) MUST listen on WAN. | P1 |
| FR-SEC-002 | Secrets MUST be managed with sops-nix and age (ADR-0014, ADR-0022): PPPoE password, Wi-Fi passphrase, subscription URL, manual node credentials, WireGuard private key, remote-access auth key. Each router MUST have its own age key. The build host MUST retain only the public keys and MUST NOT decrypt. One credential MUST be one file under `secrets/` as in *08* §11. Wi-Fi SSID and hostnames are not secrets. Plaintext in the Nix store MUST require `janus.security.allowInlineSecrets`. The age private key MUST NOT be produced by the image derivation. Secrets created only on the board MAY use `janus secrets put` instead of sops. | P1 |
| FR-SEC-003 | The system MUST run with a read-only root and store, no setuid helpers beyond what NixOS requires, and systemd hardening on Janus services. | P1 |
| FR-SEC-010 | IPv6 privacy controls (FR-NET-032/033) MUST be enabled by default. | P1 |
| FR-SEC-011 | Outbound telemetry from any bundled component MUST be disabled. | P1 |

## 14. Non-functional requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-001 | Image size (compressed) | ≤ 400 MiB for Tier-1 boards |
| NFR-002 | Boot to routing (power-on → first NAT'd packet) | ≤ 45 s on NanoPi R4S |
| NFR-003 | Idle RAM footprint | ≤ 256 MiB including the engine with 500 nodes, on boards with at least 2 GiB RAM. Zero 2 W and Le Potato are not 500-node targets. |
| NFR-004 | NAT throughput | Line rate for 1 GbE on NanoPi R4S |
| NFR-005 | Engine throughput (VLESS+Vision) | ≥ 300 Mbit/s on NanoPi R4S |
| NFR-REL-001 | Power-loss robustness | 100 random power cuts without re-flash |
| NFR-REL-002 | Subscription refresh failure tolerance | Router remains functional with last good data indefinitely |
| NFR-006 | Documentation | Every option documented; every board in the matrix has a tested image |
| NFR-007 | Supported architectures | `aarch64-linux` and `x86_64-linux` for the boards in *10*, including Tier 2 boards on those architectures. `armv7l-linux` and `riscv64-linux` are Tier 3. Tier is a per-board test obligation (*10*), not a property of the architecture, and not a promise that every Tier 1 board meets the NanoPi R4S throughput numbers. |
