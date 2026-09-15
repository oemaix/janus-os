# 04 — System Architecture

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

## 1. Architectural drivers

1. **Build/run separation** (G3, C-001): everything that needs compilers or
   unrestricted network lives on the build host; the Board only executes.
2. **Immutability** (G2, G3): read-only root and store; one small rw state
   partition.
3. **Router vocabulary** (G1): a thin, opinionated option layer (`janus.*`)
   that *lowers* into standard NixOS mechanisms rather than reinventing them.
4. **Engine neutrality** (G4): circumvention configuration is expressed
   once and rendered for sing-box or Xray.
5. **Slimness** (G5): systemd-networkd + nftables + one proxy engine + one
   DNS path; nothing else by default.

## 2. Layered view

```
┌────────────────────────────────────────────────────────────────────────┐
│  User configuration        configuration.nix  (janus.* + raw NixOS)    │
├────────────────────────────────────────────────────────────────────────┤
│  Janus option layer        modules/janus/*  — types, defaults,          │
│                            assertions, documentation                    │
├────────────────────────────────────────────────────────────────────────┤
│  Lowering layer            renders janus.* into:                        │
│    network   → systemd.network (netdev/network/link), pppd, udhcpc/    │
│                networkd DHCP, kea/dnsmasq (DHCPv4/6), radvd/networkd RA │
│    firewall  → networking.nftables ruleset (zones, NAT, tproxy/tun)     │
│    proxy     → engine config JSON (sing-box | xray) + rule-sets         │
│    dns       → engine DNS section (+ optional local forwarder)          │
│    storage   → fileSystems, systemd-repart/image builder inputs         │
│    hardware  → board profile, kernel, firmware, udev, usb_modeswitch    │
│    monitoring→ nftables counters, vnstat/softflowd, exporters           │
│    access    → openssh, users, janus CLI                                │
├────────────────────────────────────────────────────────────────────────┤
│  NixOS base                systemd, networkd, nftables, kernel, initrd  │
├────────────────────────────────────────────────────────────────────────┤
│  Board profile             kernel/DTB/firmware/u-boot, boot layout      │
└────────────────────────────────────────────────────────────────────────┘
```

## 3. Component view

### 3.1 Build host components

| Component | Responsibility |
|-----------|----------------|
| `flake.nix` | Inputs (nixpkgs pinned, janus-os), outputs (`nixosModules`, `nixosConfigurations`, `images`, `templates`, `checks`). |
| `lib.mkRouter` | Helper that turns `{ board, modules }` into a `nixosConfiguration` plus an image derivation. |
| **Subscription snapshotter** | Fixed-output or impure derivation that fetches configured subscription URLs at build time, normalizes them to Janus node JSON, and embeds the snapshot. Pinning by hash is optional (FR-BLD-006). |
| **Geo data fetcher** | Fetches GeoIP/GeoSite in the engine's native format (`.srs` for sing-box, `.dat` for Xray) plus a Janus-normalized domain list for DNS. |
| **Node normalizer** | Janet program that parses share links / Clash YAML / sing-box JSON into a canonical node schema; also evaluates matchers (regex, glob, PEG) to compute group membership at build time and to validate PEG syntax. |
| **Engine renderer** | Nix functions producing the engine configuration from the canonical model. Two backends; unsupported features raise assertions. |
| **Image builder** | Creates the partition table and file systems (mkfs.f2fs + sload.f2fs, mkfs.vfat + mcopy), installs board firmware/U-Boot at required offsets, writes the image. |
| **Checks** | Evaluation tests, renderer golden tests, VM boot tests for x86_64 test target, board build tests. |

### 3.2 Runtime components (on the Board)

| Component | Implementation | Notes |
|-----------|----------------|-------|
| Init / service manager | systemd (initrd and main) | `boot.initrd.systemd.enable = true` for ordered mounts, fsck of state partition and `/etc` overlay. |
| Network | systemd-networkd | Bridges, VLANs, DHCP client, static, RA/PD client. |
| PPPoE | pppd (`rp-pppoe` plugin) | Managed by a systemd unit per PPPoE WAN; publishes state to `/run/janus/wan/<name>`. |
| WWAN | ModemManager **or** minimal `mmcli`-less path (usb_modeswitch + networkd for ECM/NCM; `qmicli`/`mbimcli` for QMI/MBIM) | Chosen per peripheral; ModemManager is optional to keep slim. |
| DHCPv4/v6 server, RA | Kea **or** dnsmasq (DHCP only) | Decision pending (ADR-0009). Leases persisted on state partition. |
| Firewall / NAT | nftables | Single ruleset generated from zones, rules, forwards, tproxy/tun redirection. |
| Proxy engine | sing-box (default) or Xray | Runs as an unprivileged user with `CAP_NET_ADMIN`/`CAP_NET_BIND_SERVICE`; TUN or TPROXY inbound. |
| DNS | Engine's DNS server (sing-box: built-in; Xray: built-in) exposed on LAN; optional local forwarder for hosts/static leases | Avoids a second resolver daemon where possible. |
| Data refresh | `janus-refresh-subscriptions.timer`, `janus-refresh-geodata.timer` | Fetch via engine SOCKS inbound, validate, atomic rename, `systemctl reload`. |
| Monitoring | nftables named counters; `vnstat` for history; optional `softflowd` (IPFIX); optional `prometheus-node-exporter` | Data under `/var/lib/janus/monitoring`. |
| Remote access | WireGuard (kernel) ; optional Tailscale | Interfaces in `mgmt` zone. |
| Management | OpenSSH; `janus` CLI (shell + Janet) | CLI is the operator UI. |
| HMI | `janus-hmi` daemon | Renders status pages to framebuffer/e-ink; button events → actions. |

## 4. Data model (canonical)

The proxy subsystem is engine-neutral because everything is first mapped to a
canonical model in Nix (and mirrored in JSON for Janet tools):

```
Node        { id, name, source: subscription:<name> | manual,
              protocol: vless|trojan|shadowsocks|…, server, port,
              tls: { enabled, sni, alpn, utls, reality:{publicKey, shortId} },
              flow: xtls-rprx-vision | null,
              transport: tcp|ws|grpc|http-upgrade|…,
              credentials: {…}, plugin: { name, options } }

Group       { name, members: [NodeRef|GroupRef], strategy,
              strategyOptions: { url, interval, tolerance } }

Rule        { match: { domains, geosite, ipCidr, geoip, port, protocol,
                       sourceLan, sourceIp }, target: group:<n>|direct|block }

DnsPolicy   { domesticResolver, remoteResolver, carrierResolvers: never|
              fallback-only|domestic-only, encryption: prefer|require,
              fakeIp: { enabled, range, exclude }, domesticDomains: [set…] }
```

Renderers consume this model. Anything the target engine cannot express is
an evaluation-time assertion, not a silent drop.

## 5. Key runtime flows

### 5.1 Boot

1. Board firmware → U-Boot / RPi firmware → kernel + initrd from the
   read-only boot partition.
2. systemd-initrd: mounts `/` (ro), `/nix` (ro); fsck + mount `/var`
   (state, rw); mounts tmpfs `/run`, `/tmp`; sets up `/etc` overlay (lower =
   store-generated `/etc`, upper = tmpfs, with selected paths bind-mounted
   from `/var/lib/janus/etc` e.g. `machine-id`, SSH host keys).
3. Seed check: if `/var/lib/janus` is empty or fails validation, copy the
   embedded snapshot (subscriptions, Geo data) from the store.
4. networkd brings up ports, bridges, VLANs, WANs; PPPoE units start.
5. nftables ruleset loads (before any WAN is up — default-deny from the
   start).
6. Engine starts with generated config + data files; DNS begins answering.
7. DHCP server, RA start; refresh timers armed; monitoring starts.
8. Remote-access tunnel dials out once a WAN has a default route.

### 5.2 Packet path (rule-based mode)

```
LAN host → bridge → nftables prerouting:
   DNS (udp/tcp 53) → redirect to engine DNS
   marked "proxied LAN" traffic → TPROXY/TUN → engine
       engine: match rules → group → node → WAN (via engine's bound
       interface / fwmark-based routing table that bypasses TUN)
   else → forward → nftables zone rules → SNAT → WAN
```

Return traffic and IPv6 follow identical rules; engine outbound traffic is
marked so it is never re-intercepted.

### 5.3 Subscription refresh

```
timer → janus-refresh: for each subscription:
   fetch via engine SOCKS (or direct if policy says so) with timeout
   → normalize (Janet) → validate schema & minimum node count
   → write tmp → fsync → rename into /var/lib/janus/subscriptions/<name>.json
→ if any changed: re-render engine config (runtime renderer, Janet)
→ systemctl reload engine → verify health → else roll back file and log
```

### 5.4 Configuration change

```
edit configuration.nix on build host → nix build (.#images.<host> or
.#nixosConfigurations.<host>) → deploy (flash | remote closure push)
```

The Board never evaluates Nix for configuration changes.

## 6. Module structure (repository layout)

```
janus-os/
├── flake.nix
├── lib/                      mkRouter, types, helpers
├── modules/
│   ├── janus/
│   │   ├── default.nix       imports + top-level assertions
│   │   ├── hardware/         board option, peripherals
│   │   ├── storage/          partitions, mounts, etc-overlay, seed
│   │   ├── network/          ports, wan, lan, vlan, ipv6, dhcp, igmp
│   │   ├── firewall/         zones, rules, nat, hooks
│   │   ├── proxy/            engine, nodes, subscriptions, groups, rules
│   │   ├── dns/              policy
│   │   ├── monitoring/
│   │   ├── remote-access/
│   │   ├── access/           ssh, cli
│   │   └── system/           hostname, time, journald limits
│   └── boards/               one profile per board
├── pkgs/                     janus-cli, janus-tools (Janet), image builder,
│                             renderers, pinned engines if nixpkgs lags
├── janet/                    node normalizer, matchers, runtime renderer
├── templates/default/        flake.nix + configuration.nix for users
├── tests/                    eval tests, golden files, VM tests
└── docs/
```

## 7. Cross-cutting concerns

* **Assertions and warnings** are the primary UX for configuration errors;
  messages name the offending option path and how to fix it.
* **Secrets:** inline values end up world-readable in `/nix/store`. The
  alternative `*.file` options point to files on the state partition
  (`/var/lib/janus/secrets/`), provisioned once over SSH. See *11 — Security*.
* **Logging:** journald with volatile storage by default; optional persistent
  journal with strict `SystemMaxUse`.
* **Time:** routers often boot without RTC; `systemd-timesyncd` via tunnel-
  aware NTP; engine TLS start is gated on time sync when REALITY/TLS is used
  (with a bounded wait).
* **Observability of the build:** every image embeds `/etc/janus/build.json`
  (flake revision, nixpkgs revision, board, subscription snapshot hashes,
  build date).

## 8. Technology choices (summary, see ADRs)

| Concern | Choice | ADR |
|---------|--------|-----|
| Base OS | NixOS stable, flakes | 0001 |
| Deployment model | Image-based, no on-device build | 0002 |
| Storage | One partition per FS, f2fs, ro root/store | 0003 |
| Network stack | systemd-networkd + nftables (not NetworkManager) | 0004 |
| Config surface | `janus.*` lowering to NixOS | 0005 |
| Proxy engine | Canonical model; sing-box default, Xray optional | 0006 |
| Management | SSH key-only, `janus` CLI | 0007 |
| Scripting | Janet for matchers and data tooling | 0008 |
