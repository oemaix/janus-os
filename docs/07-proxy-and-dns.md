# 07 — Proxy and DNS Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-17 |

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
| VMess | yes | yes | included because subscription vendors still publish it; not the recommended protocol |
| REALITY | yes | yes | — |
| Trojan | yes | yes | — |
| Shadowsocks AEAD (incl. 2022) | yes | yes (2022 partial) | assertion on unsupported cipher |
| Shadowsocks + `simple-obfs` | yes (built-in `obfs-local` plugin) | via external plugin process | Xray: evaluation fails. No sidecar (ADR-0006). |
| Shadowsocks + `v2ray-plugin` | yes (built-in) | external process | as above |
| Hysteria2 / TUIC | yes | no | assertion when engine = xray |
| Transparent inbound | TUN, TPROXY, redirect | TPROXY, redirect, (TUN via external) | default: sing-box TUN with auto-route off (Janus owns routing); Xray TPROXY |
| Rule sets | binary `.srs` (remote/local) | `geosite.dat`/`geoip.dat` | fetched per engine format at build; refreshable |
| DNS server | built-in with fake-IP, per-LAN rules | one DNS module, per-domain servers | sing-box keeps a DNS policy per LAN. xray 26 has one policy for every LAN (§2.1) |
| Selector/URL-test groups | `selector`, `urltest` | `balancer` (leastPing, roundRobin) — no persistent manual selector | Xray: manual strategy emulated by regenerating config on `janus select` |
| Clash-API for runtime selection | yes | no | `janus select` uses Clash API on sing-box, config regen on Xray |

**Default engine: sing-box** (broader protocol coverage, native rule sets,
runtime selection API, single binary). Xray is offered for users who prefer
its XTLS implementation or have Xray-only nodes (ADR-0006).

### 2.1 Which engine to keep

Leave `janus.proxy.engine` at `sing-box` unless a row below names xray.
A setting the selected engine cannot express fails evaluation. It is not
dropped.

| Requirement | Keep |
|-------------|------|
| LANs that do not share one DNS policy: mode, resolvers, `recursive`, fake-IP, `ipv6Answers`, forwarders, name rules, or the same host name with two addresses | sing-box. xray 26 has one DNS module and matches names, not the LAN a query came from. A guest LAN on `bypass` beside a home LAN on `rule-based` fails evaluation. |
| Hysteria2, TUIC, `tls.insecure`, or a Shadowsocks plugin | sing-box |
| A DNS cache size other than 4096, or a written TTL other than 60 | sing-box. xray 26 has neither knob. Another value fails evaluation. The defaults are accepted and left to xray's own cache. |
| A blocked name answered by a DNS reject | sing-box. xray 26 has no reject code. The lookup is sent to a closed port on the router, and the client receives the failure. |
| Group strategy `load-balance` | xray. sing-box has no such group. |
| Nodes written for xray, with every LAN on one DNS policy | xray |

Address, port, and protocol rules may still differ per LAN on xray, because
those rules do not change the DNS decision. `url-test` and `manual` work on
both engines. On xray, `janus proxy select` rewrites the configuration. On
sing-box it uses the running API. Group strategy `fallback` fails on both.
`listen.lans` and `encryption` behave the same on both. Interception is TUN
on sing-box and TPROXY on xray (D-0031). Both still intercept.

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
  enable       = true;                             # false: this router does not use it (D-0044)
  url          = "https://…";
  format       = "auto" | "share-links" | "clash" | "sing-box";
  refresh      = "6h" | "30m" | "0 */6 * * *" | "0 4 * * 2,4,6";
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

`enable` defaults to true. `false` on one router drops that subscription
from the snapshot, the refresh timer, and the engine. `url` or `urlSecret`
stays set, so the host still names the secret file and remains a recipient
(D-0044). A cache file already at
`/var/lib/janus/subscriptions/<name>.json` is loaded only when `<name>` is
enabled in this image. The file stays on disk. A fleet declares every vendor in `common/` and sets `enable =
false` in the host file for the vendors that router does not take. A group
that names a disabled subscription fails evaluation. An empty
`fromSubscriptions` means every enabled subscription.

`refresh` and `geodata.refresh` accept `Nh`, `Nm`, `weekly`, `daily`,
`hourly`, or a five-field cron expression. The day-of-month and the month
are `*`. The day-of-week may be `*` or a comma-separated list such as
`2,4,6` or `1,5`. `0` and `7` are Sunday, and `1` is Monday. `0 4 * * 2,4,6`
is 04:00 on Tuesday, Thursday, and Saturday.

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
  fromSubscriptions = [ "provA" ];          # scope for matchers (default: every enabled subscription)
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

Implicit groups: every enabled subscription is a group `sub:<name>` with strategy
`url-test` unless overridden. `fallback` fails evaluation on both engines.
`load-balance` is xray only (§2.1). Every node is collected into a group
`Auto` unless the fleet defines `groups.Auto`.

`janus.proxy.groupsAuto = false` drops both implicit sets (ADR-0026). The
fleet then names every group it wants, and `defaultTarget` and every rule
must target a defined group, `direct`, or `block`; evaluation fails
otherwise. sing-box only — xray cannot express a fleet-only group set.
A fleet that wants one hand-picked group writes one `strategy = "manual"`
group and turns the option off, so the panel shows one group instead of
three.

## 5. Traffic mode and routing rules

```
janus.proxy.mode = "bypass" | "rule-based" | "proxy-all";   # inherited default
janus.proxy.defaultTarget = "group:Auto";
janus.proxy.rules = [
  { match = { geosite = [ "private" "cn" ]; };            target = "direct"; }
  { match = { geoip = [ "cn" "private" ]; };              target = "direct"; }
  { match = { geosite = [ "category-ads-all" ]; };        target = "block"; }
  { match = { domainSuffix = [ "netflix.com" "nflxvideo.net" ]; }; target = "group:Streaming"; }
  { match = { geosite = [ "telegram" ]; geoip = [ "telegram" ]; }; target = "group:Telegram"; }
  { match = { port = [ 853 ]; protocol = "tcp"; };        target = "block"; }
];
janus.proxy.exceptions = [ ... ];   # proxy-all: always direct (private, iptv)

janus.network.lans.<name>.proxy = {
  mode = "rule-based";              # unset inherits janus.proxy.mode
  rules = [ ... ];                  # unset inherits; a set list replaces
  defaultTarget = "group:Auto";     # unset inherits
  exceptions = [ ... ];             # unset inherits
};
```

`janus.proxy.mode`, `rules`, `defaultTarget`, and `exceptions` are the
values every LAN inherits (D-0042, FR-PRX-023). A LAN overrides any of
them. A set `rules` list replaces the inherited list. The renderer does
not append, because the winner would then depend on two orders. A LAN
that wants the same rules binds the same Nix list, or leaves `rules`
unset. Nodes, groups, and subscriptions stay on the router. One engine
matches the LAN by source address.

`bypass` is not intercepted. That LAN still has a path to WAN when a
firewall policy accepts it, including while the engine is down.
`rule-based` and `proxy-all` are intercepted. While the engine is down
and `failMode` is `closed`, those flows drop. `proxied` is not a second
switch.

A rule may still set `sourceLan`. In a LAN's effective list it may name
only that LAN. Another name fails evaluation. Selecting a whole LAN is
`proxy.mode` and `proxy.rules`, not a `sourceLan` row in the shared list.

Rule evaluation order is list order; the renderer emits engine rules in
the same order. `direct` means "leave via the normal WAN routing (default
route)". `block` means reject (TCP RST / ICMP unreachable) at the engine.

The block above is the rule language. The China, Russia, and Iran lists
are the templates in the example and in *21* §4. `janus.system.region` does not
insert them. An unset `janus.proxy.rules` stays empty, and a LAN that does
not set `proxy.rules` inherits that empty list.

Terminology (Glossary): the three modes are `bypass`, `rule-based`, and
`proxy-all`. A rule target may still be `direct`, meaning that one flow
leaves by the WAN. `proxy-all`
always has an exception list (private ranges, IPTV, the subscription hosts
themselves when `via = "direct"`).

## 6. Interception

* Source set: LANs whose mode is `rule-based` or `proxy-all` (nftables set
  `janus_proxied_src`). A `bypass` LAN is not in the set.
* TCP+UDP for IPv4 and IPv6 are redirected to the engine's transparent
  inbound (sing-box TUN with `auto_route = false` and Janus-managed `ip
  rule`/`ip route` to the TUN for marked traffic; or TPROXY on Xray).
  With Xray, that TPROXY target is port 12345 and mark `0x4a02` (D-0031).
* Engine egress is marked `0x4a` and routed via the WAN tables, never back
  into interception. The engine binds to no specific WAN by default;
  `janus.proxy.egressWan = "<wan>"` pins it.
* QUIC (UDP 443) to proxied destinations is passed through the tunnel by
  default. `janus.proxy.blockQuic = true` rejects it after the direct
  rules, in the engine, so a flow that matched `direct` keeps QUIC.
  nftables does not drop every UDP/443 from the LAN.
* Each LAN has its own mode, rules, and DNS policy (D-0042, FR-PRX-023).
  A guest LAN is `proxy.mode = "bypass"`. An agents LAN is `proxy-all`.
  The owner's LAN inherits `rule-based`.

## 7. DNS policy

DNS policy is rendered into the selected engine. mosdns and chinadns-ng are
not used. Both are capable split-DNS daemons, and chinadns-ng is aimed
directly at poisoning, but a second stack would keep its own domain lists
and would not share the engine's fake-IP table or sniffing. Leak checks
belong to a test command, not to a second resolver (ADR-0019).

### 7.1 Threats addressed

| Threat | Countermeasure |
|--------|----------------|
| Carrier resolver logs every query | Never use carrier resolvers by default; encrypted resolvers only |
| DNS pollution (forged A records for foreign names) | Foreign names never hit domestic/carrier resolvers; resolved remotely through the tunnel or answered with fake-IP; bogus-answer list |
| CDN mis-routing when domestic names are resolved abroad | Domestic name sets → domestic encrypted public resolver with ECS allowed |
| Plaintext DNS from LAN clients bypassing the router | Redirect all LAN udp/tcp 53 to the router; optionally block DoT (853) and known DoH endpoints |
| IPv6 AAAA leak | A proxied name gets no globally routable AAAA. An address in the configured IPv6 fake-IP range is not a leak. `ipv6Answers` is `strip-for-proxied` (default), `strip-all`, or `keep` (D-0038). |

### 7.2 Configuration

```
janus.dns = {
  listen = { lans = "all"; };           # router is the LAN resolver
  carrierResolvers = "never" | "fallback-only" | "domestic-only";
  encryption = "prefer" | "require";
  domestic = { resolvers = [ "https://dns.alidns.com/dns-query" "tls://dot.pub" ];
               domains = [ "geosite:cn" "geosite:geolocation-cn" ]; ecs = "allow"; };
  # The resolvers and domain sets above are the cn preset. ru and ir: *21*.
  remote   = { resolvers = [ "https://1.1.1.1/dns-query" "https://dns.google/dns-query" ];
               via = "tunnel"; ecs = "strip"; };
  fakeIp   = { enable = "auto"; v4Range = "198.18.0.0/15"; v6Range = "fc00::/18";
               exclude = [ "geosite:cn" "*.lan" "geosite:private" ]; };
  ipv6Answers = "strip-for-proxied";
  interceptPlaintext = true; blockDoT = true; blockKnownDoH = false;
  hosts = { "nas.lan" = "192.168.10.5"; };
  forwarders = { "corp.example" = [ "10.0.0.53" ]; };
  bogusAnswers = [ "geoip:cn-poisoned-list" ];   # optional; China forgeries. Not a ru/ir list.
  cache = { size = 4096; minTtl = 60; };
  # bootstrap is unset. It follows *21* (D-0040). An explicit list of IP
  # literals replaces the preset. The build does not look hostnames up.
};
```

`listen.lans` defaults to `all`. Those LANs are told to use the router.
dnsmasq option 6 carries that LAN's own IPv4 address. An RA in `ula-only`
names the ULA. An RA in `delegated` names the router's IPv6 link-local
(`DNS=_link_local`), because the delegated address is assigned at runtime
and an IPv4 literal is not an RDNSS address. A LAN left out of the list is
not told. Plaintext port 53 is still redirected on every LAN bridge.

`encryption` defaults to `prefer`. `require` accepts only `https://`,
`tls://`, and `quic://` for a resolver that answers a client. Bootstrap
addresses stay plaintext IP literals.

Each of `domestic.resolvers`, `remote.resolvers`, `forwarders`, and
`bootstrap` is a list, and the engine queries the first address only.
sing-box 1.13 puts one server on a DNS rule and has no failover group.
xray 26 matches names, and two servers that share one name list are not
ordered. Further addresses stay in the configuration and are not queried.
The render log names the address that is used.

`domestic.ecs` defaults to `allow` and `remote.ecs` to `strip`. Neither
engine attaches a client subnet, so the two values render the same query.
sing-box 1.13 disables the DNS cache for any query that carries a client
subnet, and `0.0.0.0/0` is a valid prefix, so sending the opt-out would
drop the cache on the remote path. xray 26 has no client-subnet field.
The resolver sees the source address of the query: the WAN for a direct
domestic query, the tunnel exit for a remote query.

`cache.size` defaults to 4096 and `cache.minTtl` to 60. sing-box keeps
that many answers and writes each routed answer's TTL to `minTtl`. It has
no floor-only TTL. `minTtl = 0` leaves the upstream TTL. xray 26 has
neither knob, so a size other than 4096 or a minimum other than 60 fails
evaluation.

`carrierResolvers` defaults to `never`. `domestic-only` places the first
learned WAN address at the front of the domestic list, and that address
is the one domestic server. `fallback-only` is not available: the same
one-server limit means a second address is not tried when the first
fails. The router logs that and leaves the list unchanged. `encryption =
require` keeps the carrier addresses out, because they are plaintext.

A blocked name is a DNS reject on sing-box. xray 26 has no reject code.
Those names are sent to `127.0.0.1` port 1 on the router, where nothing
listens. The client receives the lookup failure. It does not receive
`127.0.0.1` as the address of the name.

`fakeIp.enable` is a real choice, not an internal detail:

| Value | Meaning |
|-------|---------|
| `"auto"` | On in `rule-based` and `proxy-all`, off in `bypass`. Default. |
| `true` | Fake-IP for every name the router will proxy. |
| `false` | Real addresses only. Proxied names are resolved through the tunnel. Use this when an application breaks on the fake-IP range. |

`ipv6Answers`:

| Value | Meaning |
|-------|---------|
| `"strip-for-proxied"` | Default. A proxied name has no globally routable AAAA. A direct name keeps one. An answer in `fakeIp.v6Range` is not a leak (D-0038). |
| `"strip-all"` | Direct names lose AAAA as well. |
| `"keep"` | A proxied name may receive a globally routable AAAA. That is the leak. |

`janus.dns` is the policy every LAN inherits (D-0042, FR-DNS-014).
`janus.network.lans.<name>.dns` has the same shape. A field that is set
overrides the inherited field. A field that is unset stays inherited, so
a LAN reuses the household resolvers by leaving them alone. `recursive`
defaults to `true`. `recursive = false` answers hosts and static leases
only and does not ask an upstream. That is the IoT case: the router does
not look the wider Internet up for a LAN with no WAN path.

The LAN's mode picks the path for a name the policy does not answer as a
host or a forwarder:

| Mode | Unmatched name |
|------|----------------|
| `rule-based` | A name in the domestic sets uses the domestic encrypted resolver. A name the LAN will proxy is a fake-IP, or the remote resolver through the tunnel when fake-IP is off. |
| `proxy-all` | A name the LAN will proxy is a fake-IP, or the remote resolver. Exceptions and `fakeIp.exclude` stay direct and use the domestic resolver. The domestic set does not by itself make a name direct. |
| `bypass` | Every recursive name uses the domestic encrypted resolvers. Fake-IP is off. The remote resolver is not used unless `remote.via = "direct"`, which sends the names outside the domestic sets to the remote resolvers from the WAN, encrypted. A blocked foreign name gets the domestic answer, which may be forged or empty, and does not get the tunnel. |

A `bypass` LAN that sets `fakeIp.enable = true`, or sets
`remote.resolvers` without `remote.via = "direct"`, fails evaluation.
Inherited remote resolvers are not used unless `remote.via` is `direct`,
and inherited `fakeIp.enable = "auto"` is off. With `remote.via =
"direct"` the domestic sets keep the domestic resolvers and every other
name goes to the remote resolvers from the WAN: encrypted content, and a
resolver that sees the WAN address instead of the tunnel exit. A name that
`rule-based` or `proxy-all` will proxy must not be answered by the
domestic resolver. Putting such a name in `proxy-all` exceptions is how
it stays direct and may use the domestic resolver. `forwarders` sends
names under one domain to a specific resolver, such as a company DNS on
a VPN. It is not the carrier resolver.

`janus dns check` runs on the router (D-0041, FR-DNS-011). It does not
impersonate a LAN client, and it cannot show that a phone can still reach
another resolver. It may report whether the plaintext port-53 redirect is
installed. It does not send a packet as a LAN host. It repeats the probe
for each LAN's effective policy.

For a `rule-based` or `proxy-all` LAN it probes one domestic name and one
foreign name. The domestic name comes from the region: `www.baidu.com`,
`ya.ru`, or `nic.ir`. The foreign name is `example.com`. With fake-IP on,
the domestic answer must be a real address and not in `bogusAnswers`. The
foreign answer must be a fake-IP, or a remote answer that is not bogus and
was not taken from the domestic resolver. For a `bypass` LAN, and when
fake-IP is off, both answers are real addresses from that LAN's resolvers,
and a foreign answer in `bogusAnswers` fails. Under `strip-for-proxied` or
`strip-all`, a proxied name has no globally routable AAAA. The command
prints a pass or fail per probe and does not rewrite `janus.dns`.

China forges plaintext answers on the path, so `bogusAnswers` can name
those addresses. Russia and Iran more often lie in the ISP resolver and
block by SNI or address. A China bogon list is not a test for them. The
preset ships no such list (*21* §7). The foreign probe is the poison test:
the domestic resolver answered a foreign name, or the answer is in
`bogusAnswers`.

### 7.3 Resolution flow

Fake-IP applies to a name that LAN will proxy (D-0037). The same engine
sees the following connection and maps the address back to the name. A
`bypass` LAN is not intercepted, so it does not get that mapping, a
fake-IP, or an address from the remote resolver.

```
query from a LAN
 ├─ recursive = false              → hosts and static leases only
 ├─ hosts / static leases / forwarders → answer
 └─ mode
     ├─ bypass      → domestic encrypted resolvers, except names outside
     │                 the domestic sets when remote.via is direct
     ├─ proxy-all   → fake-IP or remote, except exceptions and fakeIp.exclude
     └─ rule-based
         ├─ name ∈ domestic sets   → domestic encrypted resolver (ECS allowed)
         ├─ rule target block      → reject
         ├─ rule target direct     → domestic resolver
         ├─ rule target group      → fake-IP, or the remote resolver through the tunnel
         └─ no rule matches        → the same as that LAN's defaultTarget
```

A group `defaultTarget` is proxied, so an unmatched name on a
`rule-based` LAN is a fake-IP when fake-IP is on. A name in
`fakeIp.exclude`, or a proxied name while fake-IP is off, is resolved
through the tunnel.

### 7.4 Bootstrap

DoH and DoT need their hostnames resolved before those resolvers can be
used. `janus.dns.bootstrap` is a list of IP addresses used only for that
lookup (D-0040, FR-DNS-013). Unset, the list follows the region preset:

| Region | Addresses |
|--------|-----------|
| `cn` | `223.5.5.5`, `223.6.6.6` |
| `ru` | `77.88.8.8`, `77.88.8.1` |
| `ir` | none |

An explicit list replaces the preset. The build does not look the
hostnames up, and no timer refreshes the list. A resolver written as an
IP (`https://223.5.5.5/dns-query`) does not need a bootstrap address. An
encrypted resolver whose host is a name, with an empty list, fails
evaluation. `1.1.1.1` is not the bootstrap. On the networks this preset
is for, that address is often blocked or forged, and the build host is
often outside the region, so a lookup there would not be the address the
router should keep.

## 8. Geo data

* Build-time fetch of engine-native rule sets for every `geosite:`/`geoip:`
  tag referenced anywhere (rules, DNS sets, exclusions). Unreferenced
  categories are not shipped (slimness). A tag is fetched at build time
  when it has a sha256 pin (`janus.proxy.geodata.hashes`, which overrides
  the built-in pins, including the reference-region tags in *21*). The sing-geoip rule-set branch does not
  publish `geoip-private`, so Janus compiles that set from the private
  ranges. A referenced tag with no pin is copied from the image when the
  image has it, and otherwise downloaded on the router.
* Runtime refresh (`janus.proxy.geodata.refresh = "weekly"`) downloads the
  same set via the tunnel, verifies the download is non-empty, replaces
  the live file only then, and reloads the engine. A failed download
  leaves the previous file in place.
* Source repositories are configurable (`janus.proxy.geodata.sources`),
  defaulting to the widely used community sets for the chosen engine.
  `geodata.sources.tags.<file>` is the full URL of one rule-set file.
  The `ir` preset uses that for Chocolate4U `geosite-ir` (*21* §4.3).

## 9. Operator interface

`janus status`, `janus proxy groups`, `janus proxy select <group>
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
