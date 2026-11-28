# ADR-0029 — Subscription protocols the engine cannot speak

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-11-28 |
| Affects | 03 FR-PRX-002, 04 §4, 07 §2, 07 §3.2, 07 §11.4, 08 §6; refines ADR-0006 and ADR-0028 |

## Context

ADR-0006 says a feature the selected engine cannot express fails
evaluation and is not dropped. ADR-0028 names the protocol label values
`vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`, and `tuic`.

A subscription mixes protocols. anytls, Hysteria2, and TUIC are sing-box
outbounds, and each one is TLS. xray has no outbound for them. Leaving
one in the file fails `xray run -test` for the VLESS and Trojan nodes,
and the refresh keeps the previous engine file.

Dropping those nodes and then treating the emptied selector as `direct`
does the opposite. The render exits 0, the check passes, and the refresh
installs a config that sends the tunnel's traffic out the WAN while the
engine is up.

An `ss://` link kept the protocol name `ss`. xray speaks Shadowsocks.
An allowlist of the canonical name then omitted the node. sing-box
rejected outbound type `ss`.

## Decision

anytls is a protocol label value. It is not a manual protocol. anytls,
Hysteria2, and TUIC are TLS, the same rule as Trojan. A share link, a
Clash item, and a sing-box outbound enable TLS without `security=tls` or
`tls.enabled`. A missing SNI is the server host. `sni`, `peer`, `fp`,
and `allowInsecure` still apply. The password is kept.

xray omits anytls, Hysteria2, and TUIC subscription nodes from that
render and from the labels written with it. The other nodes stay. A
manual Hysteria2 or TUIC node on xray still fails evaluation. A setting
the selected engine cannot express still fails evaluation. It is not
dropped.

When the omitted nodes were the only members of a selector that model
uses, the render fails. The refresh keeps the previous engine file. A
selector that is already empty on the full node list still warns and
uses `direct`.

An `ss://` link is protocol `shadowsocks` before that choice.

## Consequences

A mixed subscription refreshes on xray. VLESS and Trojan stay. anytls,
Hysteria2, and TUIC stay on sing-box, with TLS.

A subscription that is only those three protocols does not replace a
working xray config with `direct`. The same holds for a `defaultTarget`
or a rule selector that matched only those nodes.

Shadowsocks share links render as `shadowsocks` on both engines.

## Alternatives considered

Fail the whole subscription when any node is unspoken — rejected. One
anytls node would block the VLESS and Trojan nodes. That is the failure
this ADR splits from ADR-0006.

Install `direct` whenever the selector is empty — rejected. The engine
stays up, and traffic the selector was supposed to tunnel leaves by the
WAN.

Teach xray an anytls outbound — rejected. The binary has none.
