# 21 — Reference regions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-25 |

This document is the preset that makes one Janus router practical in
mainland China, Russia, or Iran. The module is `modules/janus/region.nix`.
The choice is D-0034.

A total outage of the international link is out of scope. No client
preset helps when the uplink cannot reach a relay at all.

## 1. What is decided

The five proposed changes collapse to one option and a table of data.

| Proposal | Decision |
|----------|----------|
| Replace China/global lists with Russia/global or Iran/global | The split stays. Domestic names and domestic addresses go direct. Everything else follows `defaultTarget`. There is no list named global. `geosite:ru` and `geosite:ir` are not files on the SagerNet source this tree already uses. |
| Domestic DNS in the country of use | Yes. The preset names the resolvers. AliDNS is the China preset only. |
| A different routing template | Yes. One ordered list per reference region, written in the example. An unset `janus.proxy.rules` stays empty. |
| A different implementation per censorship system | No. Active probing, DNS pollution, SNI filtering, and protocol-class throttling are met by the controls Janus already has (REALITY, uTLS, split DNS, fail-closed, QUIC policy). A second renderer would rot. |
| An explicit target region `cn`, `ru`, or `ir` | Yes. `janus.system.region`. |

`janus.system.region` is the censorship environment the router is built for. It
is not a language, not a time zone, and not an exit-node country. Exit
groups such as JP, US, and HK stay FR-PRX-014. The Wi-Fi regulatory
country defaults from the same letters and is a different option,
`janus.network.wifiCountry` (D-0054, *06* §11).

## 2. Option

```
janus.system.region = "cn" | "ru" | "ir";   # default "cn"
```

* One region per router. A household is in one of these networks.
* An unknown value fails evaluation.
* Changing it is a rebuild. It is not a hot override.
* The default `cn` keeps today's China DNS defaults and the China
  reference in the example.

`janus.proxy.rules` is empty when unset. The module does not insert the
lists in §4. The example writes the `cn` list and comments out `ru` and
`ir`, so changing region is also changing that list. Private addresses
still stay direct in nftables (D-0030). A private *name* stays direct only
when the written list says so.

Explicit DNS and QUIC settings win as a whole:

* An explicit `janus.dns.domestic.resolvers`, `domestic.domains`, or
  `fakeIp.exclude` replaces that field of the preset.
* An explicit `janus.proxy.blockQuic` replaces the preset default.

Evaluation does not compare the written rule list with `janus.system.region`.
A list for one country beside a region for another is the list the user
wrote.

## 3. Shared behavior

These do not vary by region:

* Protocols, engines, subscriptions, groups, and transparent interception.
* `failMode` default `closed`.
* Remote resolvers stay `https://1.1.1.1/dns-query` and
  `https://dns.google/dns-query`, reached through the tunnel. On a
  `rule-based` or `proxy-all` LAN, a name that LAN will proxy is not sent
  to the domestic resolvers. A `bypass` LAN sends every recursive name to
  the domestic resolvers and does not use the tunnel (D-0042).
* IPv6 policy stays `strip-for-proxied`. A fake-IP AAAA is not a leak
  (D-0038).
* Fake-IP stays `auto`. It covers names the router will proxy, including
  the default target when that target is a group (D-0037).
* Carrier resolvers stay `never`, including on a `domestic` LAN.

The region changes the domestic resolvers, the fake-IP exclusions that
match the domestic names, the bootstrap addresses, and the `blockQuic`
default. Unset `janus.dns.bootstrap` follows §4 (D-0040). There is no
build-time lookup and no refresh timer. The routing list changes only
when the configuration writes it.

## 4. Presets

The lists in this section are the example templates. They are not applied
while `janus.proxy.rules` is unset.

Rule order in every template:

1. `geosite:private` and `geoip:private` → `direct`
2. Domestic suffixes → `direct`
3. Domestic GeoSite → `direct`
4. Domestic GeoIP → `direct`
5. `geosite:category-ads-all` → `block`

The default target is unchanged (`group:Auto` unless the user set it).
Each template uses the same domestic names as `domestic.domains`.
`fakeIp.exclude` is those names, written as `*.example` for a suffix,
plus `*.lan` and `geosite:private`. A suffix in `domestic.domains` is
already rendered as a domain suffix. With the matching list written, a
domestic name is resolved on the domestic resolver and leaves direct.
With `janus.proxy.rules` empty, the module still resolves that name
domestically, and the connection follows `defaultTarget`.

Tags below are the category passed to `geosite:` / `geoip:`. The file name
is `geosite-<tag>.srs` or `geoip-<tag>.srs`, which is the rule this tree
already uses.

### 4.1 `cn`

| Field | Value |
|-------|-------|
| Suffixes | none. `geosite:cn` is the list, not "every `.cn` name". |
| GeoSite | `cn`, `geolocation-cn` |
| GeoIP | `cn` |
| Domestic resolvers | `https://dns.alidns.com/dns-query`, `tls://dot.pub` |
| Bootstrap | `223.5.5.5`, `223.6.6.6` |
| `blockQuic` | `false` |
| Source | SagerNet sing-geosite and sing-geoip, as today |

`geolocation-cn` is on the DNS domestic set, and on the `cn` list in the
example. Copying that list is what keeps those names from being resolved
inland and then sent through the tunnel.

### 4.2 `ru`

| Field | Value |
|-------|-------|
| Suffixes | `ru`, `su`, `xn--p1ai` (`.рф`) |
| GeoSite | `category-ru` |
| GeoIP | `ru` |
| Domestic resolvers | `https://common.dot.dns.yandex.net/dns-query`, `tls://common.dot.dns.yandex.net` |
| Bootstrap | `77.88.8.8`, `77.88.8.1` |
| `blockQuic` | `true` |
| Source | SagerNet sing-geosite and sing-geoip |

Checked on 2026-10-16: `geosite-category-ru.srs` on SagerNet is about 8 KiB
and `geosite-ru.srs` is not published there (404). `geoip-ru.srs` is about
50 KiB. Country suffixes cover banks and government names the small
category misses. `geoip:ru` catches a Russian address after the domestic
resolver has answered. Services on `.com` that are absent from
`category-ru` still need a later list; that list is not part of this preset.

Yandex DNS is the unfiltered "basic" endpoint. `safe.dot` and `family.dot`
rewrite answers and are not the preset. `blockQuic` is true because
throttling of QUIC is ordinary on this network, not a total outage. The
user can set `blockQuic = false`.

### 4.3 `ir`

| Field | Value |
|-------|-------|
| Suffixes | `ir` |
| GeoSite | `ir` |
| GeoIP | `ir` |
| Domestic resolvers | none. With the proxy enabled, evaluation fails until the user sets them. |
| Bootstrap | none. A DoH or DoT hostname needs `janus.dns.bootstrap`. |
| `blockQuic` | `false` |
| GeoSite source | Chocolate4U `geosite-ir.srs` |
| GeoIP source | SagerNet sing-geoip `geoip-ir.srs` |

Checked on 2026-10-16: SagerNet `geosite-category-ir.srs` is about 1.6 KiB
and `geosite-ir.srs` is not published there (404). Chocolate4U
`geosite-ir.srs` is about 300 KiB and includes `.ir`. That is the domain
list this preset uses. `geoip-ir.srs` on sing-geoip is about 13 KiB and
stays the address list.

One base URL still covers every other GeoSite tag. `geosite-ir` does not
live on that base. `janus.proxy.geodata.sources.tags.<file>` is the full
URL of one rule-set file and replaces `<base>/<file>.srs` for that file.
The built-in value is:

```
geosite-ir = "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs";
```

The tag is fetched only when the configuration references `geosite:ir`.
Its sha256 pin is in `modules/janus/proxy/lower.nix`, measured on
2026-10-16.

There is no built-in Iranian resolver. Shecan, Electro, Begzar, and 403
are anti-filter resolvers: they answer names the filter blocks. Janus
already sends those names through the tunnel. Putting one of them in
`domestic.resolvers` would answer foreign names on the direct path. The
operator sets an encrypted resolver (DoH or DoT) that returns inland
addresses for inland names. Plaintext ISP DNS does not satisfy
FR-DNS-004. An empty `domestic.resolvers` with `region = "ir"` fails
evaluation when the proxy is enabled, and names this distinction. It
does not suggest a URL. With the proxy off, the empty list is kept.

## 5. Implementation

`modules/janus/region.nix` applies domestic DNS, `blockQuic`, and the
bootstrap addresses in §4 (D-0040). It does not write `janus.proxy.rules`.
sing-box follows D-0037 through D-0042 per LAN. xray 26 follows the same
DNS decision for one shared policy and routes each LAN by source. A
household whose LANs do not share that policy stays on sing-box (*07*
§2.1). Per-tag URLs and the pins for the preset files, including
Chocolate4U `geosite-ir`, are in
`modules/janus/proxy/lower.nix`. The pins were measured on 2026-10-16.
The example writes the `cn` list and comments out `ru` and `ir`.
`eval-region-ru` checks that an unset rule list stays empty.

## 6. Use cases the preset does not change

Kirill and Niloofar use the same household flow as Mei: one subscription,
split DNS, fail-closed, IPv6 not leaking, and a build host that can fetch.
UC-02 (carrier IPTV on a second VLAN) stays the China case. It is not a
Russia or Iran requirement.

What remains different is small, and it is not another subsystem.

* **Iran, one more setting.** `region = "ir"` is not enough. Domestic
  resolvers are empty until the operator sets them (§4.3). Bootstrap is
  empty too. A DoH or DoT hostname also needs `janus.dns.bootstrap`.
* **Russia, Telegram.** The `ru` template sends Telegram to `defaultTarget`,
  so it is proxied, which is what China and often Iran want. In Russia
  Telegram is usually left direct. That is one extra row in the written
  list, not a region value. The template does not grow a Telegram exception.
* **Names outside the country suffix.** `vk.com` and other Russian services
  on `.com` are direct only when `category-ru` contains them. Iranian shops
  and payment names on `.com` are direct only because the Chocolate4U list
  contains them. `.ru` and `.ir` do not cover those names.
* **Why the tunnel exists.** In Russia and Iran a foreign site may also
  refuse a domestic source address. The router answer is the same default
  path through the relay. There is no sanctions switch.
* **The node, not the region.** A REALITY `serverName` that is itself
  blocked is a bad node in that country. A relay whose transport is QUIC
  is a poor fit where QUIC is throttled. `blockQuic` rejects QUIC that
  did not match a direct rule. It does not rewrite the node's protocol.
* **Protocols this preset does not add.** FR-PRX-001 stays the list.
  A subscription that is only a WireGuard variant is out of scope for
  `janus.system.region`. Adding one would be a new protocol decision.

## 7. What a poison check can see

`janus dns check` does not use one bogon list for all three regions
(D-0041).

* China forges A records on the path of plaintext DNS. `bogusAnswers` may
  name those addresses. The preset does not require that list.
* Russia and Iran more often lie in the ISP resolver, returning NXDOMAIN
  or a block page, and block by SNI or address. On-path forged answers are
  not the usual tool, and a China bogon list is not a test for them. The
  preset ships no Russia or Iran bogon list.
* The foreign probe fails when the domestic resolver answered that name,
  or when the answer is in `bogusAnswers`. Encrypted DNS to a resolver
  that is not the ISP often works until that resolver's address is blocked.
