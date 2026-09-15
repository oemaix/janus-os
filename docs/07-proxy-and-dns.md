# 07 — Proxy and DNS Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

## 1. Scope

This document covers the circumvention subsystem (`janus.proxy`) and the DNS
policy layer (`janus.dns`). They are designed together because DNS is the
first place censorship acts and the first place a tunnel leaks.

## 2. Engine abstraction

Janus maintains a canonical model (see *04 — Architecture §4*) and renders it
for one engine:

| Capability | sing-box | Xray | Janus handling |
|------------|----------|------|----------------|
| VLESS + XTLS-RPRX-Vision | yes | yes | — |
| REALITY | yes | yes | — |
| Trojan | yes | yes | — |
| Shadowsocks AEAD (incl. 2022) | yes | yes (2022 partial) | assertion on unsupported cipher |
| Shadowsocks + `simple-obfs` | yes (built-in `obfs-local` plugin) | via external plugin process | Xray: Janus spawns `obfs-local` sidecar or asserts |
| Shadowsocks + `v2ray-plugin` | yes (built-in) | external process | as above |
| Hysteria2 / TUIC | yes | no | assertion when engine = xray |
| Transparent inbound | TUN, TPROXY, redirect | TPROXY, redirect, (TUN via external) | default: sing-box TUN with auto-route off (Janus owns routing); Xray TPROXY |
| Rule sets | binary `.srs` (remote/local) | `geosite.dat`/`geoip.dat` | fetched per engine format at build; refreshable |
| DNS server | built-in with fake-IP, per-rule servers | built-in DNS (fake-IP, per-domain servers) | both used as LAN resolver |
| Selector/URL-test groups | `selector`, `urltest` | `balancer` (leastPing, roundRobin) — no persistent manual selector | Xray: manual strategy emulated by regenerating config on `janus select` |
| Clash-API for runtime selection | yes | no | `janus select` uses Clash API on sing-box, config regen on Xray |

**Default engine: sing-box** (broader protocol coverage, native rule sets,
runtime selection API, single binary). Xray is offered for users who prefer
its XTLS implementation or have Xray-only nodes (ADR-0006).

## 3. Nodes

### 3.1 Sources

* **Subscriptions** (`janus.proxy.subscriptions.<name>`): fetched on the
  build host at build time (snapshot embedded) and refreshed on the router
  on a schedule. Resulting nodes are named `<subscription>/<node-name>` and
  are immutable to the user (FR-PRX-007). If a user needs to alter a node
  from a subscription, the answer is a manual node (copy) — the design
  refuses partial overrides to keep refresh semantics simple.
* **Manual nodes** (`janus.proxy.nodes.<name>`): full protocol option set,
  validated by type.

### 3.2 Subscription definition

```
janus.proxy.subscriptions.<name> = {
  url          = "https://…";
  format       = "auto" | "share-links" | "clash" | "sing-box";
  refresh      = "6h" | "30m" | "0 */6 * * *" | "never";
  userAgent    = "clash.meta";                     # many providers key on UA
  headers      = { };
  via          = "tunnel" | "direct" | "tunnel-then-direct";  # runtime fetch path
  snapshot     = { hash = null; }                  # pin build-time snapshot (reproducible builds)
  minimumNodes = 1;                                # refuse a refresh that yields fewer
  nameFilter   = null;                             # optional matcher to drop junk entries (e.g. "剩余流量")
};
```

The Node normalizer (Janet) converts every format into canonical node JSON
and rejects unknown protocols with a listed reason. Build-time fetch is an
impure derivation by default (`--impure` documented) or a fixed-output
derivation when `snapshot.hash` is set.

### 3.3 Refresh semantics

1. Timer fires per subscription schedule (systemd `OnCalendar` derived from
   interval or cron expression).
2. Fetch through `via` path; timeout 60 s; retries with backoff.
3. Normalize → validate (schema, `minimumNodes`, name filter).
4. Atomic replace of `/var/lib/janus/subscriptions/<name>.json`.
5. Runtime renderer (Janet, using the same group/rule definitions exported
   from Nix as JSON) regenerates the engine config into
   `/var/lib/janus/engine/config.json`.
6. `systemctl reload` engine; health check (DNS query via engine + URL test
   of default group). On failure: restore previous files, reload, log.

The engine config therefore lives in two places: the store copy (from the
build snapshot) used for first boot / recovery, and the runtime copy. The
service unit prefers the runtime copy when present and valid.

## 4. Groups

```
janus.proxy.groups.<name> = {
  # membership — exactly one of:
  fromSubscriptions = [ "provA" ];          # scope for matchers (default: all subscriptions)
  match  = { kind = "regex" | "glob" | "peg"; pattern = "…"; caseInsensitive = true; };
  members = [ "node:manual-jp1" "group:JP" "sub:provA" ];   # manual list; may nest

  strategy = "manual" | "url-test" | "fallback" | "load-balance";
  default  = "node:…";                       # manual: initial selection
  test     = { url = "https://www.gstatic.com/generate_204"; interval = "5m"; tolerance = 50; };
  emptyFallback = "direct" | "group:<other>";   # FR-PRX-015
};
```

Matcher kinds:

* `regex` — RE2-compatible (no backtracking), evaluated by Janet's PEG-based
  regex shim or engine-side where supported.
* `glob` — `*`, `?`, `[…]`, `{a,b}`; translated to a PEG.
* `peg` — a Janet PEG expression, e.g.
  `(peg/compile ~(* (any (if-not "JP" 1)) "JP"))` — for users who want
  structure-aware matching (emoji flags, `|` separated tags, bandwidth
  multipliers like `x0.5`). PEG syntax is validated at build time.

Groups are computed at build time (for the snapshot) and recomputed at every
refresh by the same Janet code, guaranteeing identical semantics.

Implicit groups: every subscription is a group `sub:<name>` with strategy
`url-test` unless overridden.

## 5. Traffic mode and routing rules

```
janus.proxy.mode = "direct" | "rule-based" | "proxy-all";
janus.proxy.defaultTarget = "group:Auto";     # rule-based: no rule matched; proxy-all: everything
janus.proxy.rules = [
  { match = { geosite = [ "private" "cn" ]; };            target = "direct"; }
  { match = { geoip = [ "cn" "private" ]; };              target = "direct"; }
  { match = { geosite = [ "category-ads-all" ]; };        target = "block"; }
  { match = { domainSuffix = [ "netflix.com" "nflxvideo.net" ]; }; target = "group:Streaming"; }
  { match = { geosite = [ "telegram" ]; geoip = [ "telegram" ]; }; target = "group:Telegram"; }
  { match = { sourceLan = [ "iot" ]; };                   target = "direct"; }
  { match = { port = [ 853 ]; protocol = "tcp"; };        target = "block"; }  # kill DoT from LAN
];
janus.proxy.exceptions = [ ... ];   # proxy-all mode: always direct (e.g. geosite:private, iptv)
```

Rule evaluation order is list order; the renderer emits engine rules in the
same order. `direct` means "leave via the normal WAN routing (default
route)". `block` means reject (TCP RST / ICMP unreachable) at the engine.

Terminology (Glossary): the three modes replace the Clash-era words
"Direct/Rule/Global" because "global" does not say what it does. `proxy-all`
always has an exception list (private ranges, IPTV, the subscription hosts
themselves when `via = "direct"`).

## 6. Interception

* Source set: LANs with `proxied = true` (nftables set `janus_proxied_src`).
* TCP+UDP for IPv4 and IPv6 are redirected to the engine's transparent
  inbound (sing-box TUN with `auto_route = false` and Janus-managed `ip
  rule`/`ip route` to the TUN for marked traffic; or TPROXY on Xray).
* Engine egress is marked `0x4a` and routed via the WAN tables, never back
  into interception. The engine binds to no specific WAN by default;
  `janus.proxy.egressWan = "<wan>"` pins it.
* QUIC (UDP 443) to proxied destinations is passed through the tunnel by
  default; `janus.proxy.blockQuic = true` rejects it so clients fall back to
  TCP where the tunnel handles it better.
* Per-LAN opt-out (`proxied = false`) and per-rule `sourceLan` cover mixed
  households (FR-PRX-023).

## 7. DNS policy

### 7.1 Threats addressed

| Threat | Countermeasure |
|--------|----------------|
| Carrier resolver logs every query | Never use carrier resolvers by default; encrypted resolvers only |
| DNS pollution (forged A records for foreign names) | Foreign names never hit domestic/carrier resolvers; resolved remotely through the tunnel or answered with fake-IP; bogus-answer list |
| CDN mis-routing when domestic names are resolved abroad | Domestic name sets → domestic encrypted public resolver with ECS allowed |
| Plaintext DNS from LAN clients bypassing the router | Redirect all LAN udp/tcp 53 to the router; optionally block DoT (853) and known DoH endpoints |
| IPv6 AAAA leak | AAAA for proxied domains handled by fake-IP (v6 range) or resolved remotely; policy `ipv6Answers = "keep"|"strip-for-proxied"|"strip-all"` |

### 7.2 Configuration

```
janus.dns = {
  listen = { lans = "all"; };           # router is the LAN resolver
  carrierResolvers = "never" | "fallback-only" | "domestic-only";
  encryption = "prefer" | "require";
  domestic = { resolvers = [ "https://dns.alidns.com/dns-query" "tls://dot.pub" ];
               domains = [ "geosite:cn" "geosite:geolocation-cn" ]; ecs = "allow"; };
  remote   = { resolvers = [ "https://1.1.1.1/dns-query" "https://dns.google/dns-query" ];
               via = "tunnel"; ecs = "strip"; };
  fakeIp   = { enable = "auto"; v4Range = "198.18.0.0/15"; v6Range = "fc00::/18";
               exclude = [ "geosite:cn" "*.lan" "geosite:private" ]; };
  ipv6Answers = "strip-for-proxied";
  interceptPlaintext = true; blockDoT = true; blockKnownDoH = false;
  hosts = { "nas.lan" = "192.168.10.5"; };
  forwarders = { "corp.example" = [ "10.0.0.53" ]; };
  bogusAnswers = [ "geoip:cn-poisoned-list" ];   # optional list of known poison IPs
  cache = { size = 4096; minTtl = 60; };
};
```

`fakeIp.enable = "auto"` means: on in `rule-based`/`proxy-all`, off in
`direct`.

### 7.3 Resolution flow (rule-based mode)

```
query from LAN
 ├─ hosts / static leases / forwarders → answer
 ├─ name ∈ domestic sets                 → domestic encrypted resolver (ECS allowed)
 ├─ name matches a rule with target group→ fake-IP (or remote resolver if excluded)
 ├─ name matches rule target direct      → domestic resolver
 └─ default                              → per defaultTarget: fake-IP / remote / domestic
```

Fake-IP answers are only meaningful because the same engine sees the
subsequent connection and maps it back to the domain; hence fake-IP is
disabled for any LAN with `proxied = false` (those LANs get real remote
resolution instead).

### 7.4 Bootstrap

Encrypted resolvers need their own names resolved: Janus pins bootstrap IPs
for configured DoH/DoT hostnames at build time (assertion if unresolvable on
the build host) and refreshes them with Geo data.

## 8. Geo data

* Build-time fetch of engine-native rule sets for every `geosite:`/`geoip:`
  tag referenced anywhere (rules, DNS sets, exclusions). Unreferenced
  categories are not shipped (slimness).
* Runtime refresh (`janus.proxy.geodata.refresh = "weekly"`) downloads the
  same set via the tunnel, verifies size/format, atomically replaces, and
  reloads the engine.
* Source repositories are configurable (`janus.proxy.geodata.sources`),
  defaulting to the widely used community sets for the chosen engine.

## 9. Operator interface

`janus proxy status`, `janus proxy groups`, `janus proxy select <group>
<node>`, `janus proxy test <group>`, `janus proxy refresh [<subscription>]`,
`janus dns query <name>`, `janus dns flush`. Manual selections persist in
`/var/lib/janus/engine/selection.json` and survive refresh and reboot; a
rebuild with a changed `default` for the group resets them.

## 10. Example templates shipped in the example configuration

Region groups (enabled): `JP`, `US`, `HK`, `SG`, `EU`, `UK`, `IN`, each a
`regex` matcher with common name variants (`(?i)japan|jp|日本|🇯🇵`), strategy
`url-test`. Usage groups (commented out): `Telegram`, `Gemini`, `Claude`,
`Netflix`, `YouTube`, `GitHub`, each with a suggested member group and the
matching rule block, so a user enables a feature by uncommenting two
stanzas.
