# ADR-0006 — Engine-neutral proxy model; sing-box default, Xray optional

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 03 FR-PRX-001/002, 07 §2 |

## Context

Required protocols: VLESS with XTLS-RPRX-Vision and REALITY, Trojan,
Shadowsocks with `simple-obfs`/`v2ray-plugin`. The note suggests
implementing with sing-box *and* Xray, selectable by the user. Two engines
means two configuration formats, two rule-set formats and different runtime
control surfaces.

## Decision

Janus defines a canonical model (nodes, groups, rules, DNS policy) in Nix
and mirrors it as JSON for runtime tooling. Two renderers produce engine
configuration from this model. `janus.proxy.engine` selects one engine per
system; **sing-box is the default**. Features the selected engine cannot
express fail at evaluation with an explicit message rather than being
silently dropped.

## Consequences

* Users configure once, independent of engine; switching engines is one
  option change (subject to capability assertions).
* sing-box's native rule sets, built-in DNS with fake-IP, TUN inbound and
  Clash API give the most complete runtime experience; Xray users lose
  persistent manual selection via API (emulated by config regeneration) and
  need sidecars for SIP003 plugins.
* Janus maintains two renderers and two Geo data pipelines; golden tests are
  mandatory.

## Alternatives considered

* **sing-box only** — simplest; rejected because the note explicitly wants a
  choice and some users' nodes/tooling are Xray-centric.
* **Xray only** — lacks Hysteria2/TUIC, native TUN, runtime selection API.
* **Running both simultaneously** — doubles resource use, complicates
  interception; no benefit.
* **Clash.Meta/mihomo** — strong feature set, but a third format; may be
  revisited if demand appears.
