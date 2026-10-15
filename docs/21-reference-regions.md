# 21 — Reference regions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-16 |

This document is the preset that makes one Janus router practical in
mainland China, Russia, or Iran. It is not implemented. *13* records that.
The choice is D-0034.

A total outage of the international link is out of scope. No client
preset helps when the uplink cannot reach a relay at all.

## 1. What is decided

The five proposed changes collapse to one option and a table of data.

| Proposal | Decision |
|----------|----------|
| Replace China/global lists with Russia/global or Iran/global | The split stays. Domestic names and domestic addresses go direct. Everything else follows `defaultTarget`. There is no list named global. `geosite:ru` and `geosite:ir` are not files on the SagerNet source this tree already uses. |
| Domestic DNS in the country of use | Yes. The preset names the resolvers. AliDNS is the China preset only. |
| A different routing template | Yes. One ordered list per reference region. The engine, the matchers, and the rule language stay. |
| A different implementation per censorship system | No. Active probing, DNS pollution, SNI filtering, and protocol-class throttling are met by the controls Janus already has (REALITY, uTLS, split DNS, fail-closed, QUIC policy). A second renderer would rot. |
| An explicit target region `cn`, `ru`, or `ir` | Yes. `janus.region`. |

`janus.region` is the censorship environment the router is built for. It
is not a language, not a time zone, and not an exit-node country. Exit
groups such as JP, US, and HK stay FR-PRX-014.

## 2. Option

```
janus.region = "cn" | "ru" | "ir";   # default "cn"
```

* One region per router. A household is in one of these networks.
* An unknown value fails evaluation.
* Changing it is a rebuild. It is not a hot override.
* The default `cn` keeps today's China DNS defaults and the China
  reference in the example.

Explicit configuration wins, and it wins as a whole:

* An explicit `janus.proxy.rules` list replaces the preset rule list. It
  is not merged with the preset.
* An explicit `janus.dns.domestic.resolvers`, `domestic.domains`, or
  `fakeIp.exclude` replaces that field of the preset.
* An explicit `janus.proxy.blockQuic` replaces the preset default.

If `region` is `ru` or `ir` and an explicit rule or domestic domain entry
still mentions `cn` or `geolocation-cn`, evaluation warns. The build does
not fail: a user may add a China rule on purpose. The warning exists
because copying the example and only changing `region` leaves Chinese
direct rules in place.

## 3. Shared behavior

These do not vary by region:

* Protocols, engines, subscriptions, groups, and transparent interception.
* `failMode` default `closed`.
* Remote resolvers stay `https://1.1.1.1/dns-query` and
  `https://dns.google/dns-query`, reached through the tunnel.
* Foreign names are not sent to the domestic resolvers.
* IPv6 policy stays `strip-for-proxied`.
* Fake-IP stays `auto`.
* Carrier resolvers stay `never`.

The region changes only the domestic half of split routing, the domestic
resolvers, the fake-IP exclusions that match that half, and the `blockQuic`
default.

## 4. Presets

Rule order in every preset:

1. `geosite:private` and `geoip:private` → `direct`
2. Domestic suffixes → `direct`
3. Domestic GeoSite → `direct`
4. Domestic GeoIP → `direct`
5. `geosite:category-ads-all` → `block`

The default target is unchanged (`group:Auto` unless the user set it).
Domestic names are the same set in routing, in `domestic.domains`, and in
`fakeIp.exclude`, so a name that goes direct is also resolved on the
domestic resolver. A suffix in `domestic.domains` is already rendered as
a domain suffix. Fake-IP exclusion writes the same suffix as `*.example`.

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
| `blockQuic` | `false` |
| Source | SagerNet sing-geosite and sing-geoip, as today |

`geolocation-cn` is on the DNS domestic set today and is on the routing
preset as well, so those names are not resolved inland and then proxied.

### 4.2 `ru`

| Field | Value |
|-------|-------|
| Suffixes | `ru`, `su`, `xn--p1ai` (`.рф`) |
| GeoSite | `category-ru` |
| GeoIP | `ru` |
| Domestic resolvers | `https://common.dot.dns.yandex.net/dns-query`, `tls://common.dot.dns.yandex.net` |
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
| Domestic resolvers | none. Evaluation fails until the user sets them. |
| `blockQuic` | `false` |
| GeoSite source | Chocolate4U `geosite-ir.srs` |
| GeoIP source | SagerNet sing-geoip `geoip-ir.srs` |

Checked on 2026-10-16: SagerNet `geosite-category-ir.srs` is about 1.6 KiB
and `geosite-ir.srs` is not published there (404). Chocolate4U
`geosite-ir.srs` is about 300 KiB and includes `.ir`. That is the domain
list this preset uses. `geoip-ir.srs` on sing-geoip is about 13 KiB and
stays the address list.

`geodata.sources` today is one base URL for every GeoSite tag. The `ir`
file does not live on that base. Implementation adds a per-tag URL,
`janus.proxy.geodata.sources.tags.<file>`, which replaces
`<base>/<file>.srs` for that file only. The built-in value is:

```
geosite-ir = "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs";
```

The tag is fetched only when the configuration references `geosite:ir`.
The implementation records its sha256 next to the other built-in pins.
This document does not invent that hash.

There is no built-in Iranian resolver. Shecan, Electro, Begzar, and 403
are anti-filter resolvers: they answer names the filter blocks. Janus
already sends those names through the tunnel. Putting one of them in
`domestic.resolvers` would answer foreign names on the direct path. The
operator sets an encrypted resolver (DoH or DoT) that returns inland
addresses for inland names. Plaintext ISP DNS does not satisfy
FR-DNS-004. An empty `domestic.resolvers` with `region = "ir"` fails
evaluation and names this distinction. It does not suggest a URL.

## 5. Work to do

Not started. When it is done, the code follows this document.

* `janus.region` on the module, default `cn`, enum `cn`, `ru`, `ir`.
* Default rules, domestic DNS fields, fake-IP exclusions, and `blockQuic`
  come from the preset unless the option is set.
* The `cn` default rule list grows the domestic rows in §4.1. Today the
  module default is only private networks, and the example carries the
  China rows. After this change, an unset `rules` list is the preset.
* Per-tag Geo data URL as in §4.3, plus a sha256 pin for `geosite-ir`
  measured at implementation time.
* Assertion: `region = "ir"` and empty `domestic.resolvers`.
* Warning: `ru` or `ir` combined with a `cn` or `geolocation-cn` entry.
* Example: set `janus.region = "cn"` and do not repeat the China lists, so
  switching the region is the edit. A comment shows the expanded `cn` list.
* Eval tests: `ru` renders `category-ru`, the Yandex resolvers, and
  `blockQuic`; `ir` without resolvers fails; `ir` with a resolver
  references the Chocolate4U URL; an explicit rule list is not merged.

The manual stays unchanged until the option exists. User-facing text
describes what the router already does.

## 6. Use cases the preset does not change

Kirill and Niloofar use the same household flow as Mei: one subscription,
split DNS, fail-closed, IPv6 not leaking, and a build host that can fetch.
UC-02 (carrier IPTV on a second VLAN) stays the China case. It is not a
Russia or Iran requirement.

What remains different is small, and it is not another subsystem.

* **Iran, one more setting.** `region = "ir"` is not enough. Domestic
  resolvers are empty until the operator sets them (§4.3).
* **Russia, Telegram.** The preset sends Telegram to `defaultTarget`, so it
  is proxied, which is what China and often Iran want. In Russia Telegram
  is usually left direct. That is one extra rule, not a region value. An
  explicit `rules` list replaces the preset, so the domestic rows have to
  be copied into that list. The preset does not grow a Telegram exception.
* **Names outside the country suffix.** `vk.com` and other Russian services
  on `.com` are direct only when `category-ru` contains them. Iranian shops
  and payment names on `.com` are direct only because the Chocolate4U list
  contains them. `.ru` and `.ir` do not cover those names.
* **Why the tunnel exists.** In Russia and Iran a foreign site may also
  refuse a domestic source address. The router answer is the same default
  path through the relay. There is no sanctions switch.
* **The node, not the region.** A REALITY `serverName` that is itself
  blocked is a bad node in that country. A relay whose transport is QUIC
  is a poor fit where QUIC is throttled. `blockQuic` only rejects QUIC
  from LAN clients; it does not rewrite the node's protocol.
* **Protocols this preset does not add.** FR-PRX-001 stays the list.
  A subscription that is only a WireGuard variant is out of scope for
  `janus.region`. Adding one would be a new protocol decision.
