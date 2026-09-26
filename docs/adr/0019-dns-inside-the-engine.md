# ADR-0019 — DNS policy inside the proxy engine

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-23 |
| Affects | 03 FR-DNS-009/010/011, 07 §7 |

## Context

Split DNS for a censored network is often done with mosdns or chinadns-ng
in front of a proxy. Both implement domestic/foreign forwarding and
poisoning fallbacks. The note also asks whether fake-IP should be optional,
and whether the arrangement must be tested for leaks even if the engine
owns DNS.

## Decision

The selected engine (sing-box by default, Xray when chosen) is the only
DNS policy implementation. Janus renders `janus.dns` into that engine.
mosdns and chinadns-ng are not dependencies.

Fake-IP is a user choice: `auto` (default), `true`, or `false`.

`janus dns check` probes the running path for pollution and leaks. It
does not change policy.

## Consequences

* Domain lists, fake-IP, and routing rules stay in one process, so a name
  and the connection that follows cannot disagree.
* Engine DNS bugs are Janus bugs. There is no second stack to paper over
  them.
* Users coming from OpenWrt lose a familiar mosdns config. The `janus.dns`
  options are the replacement.

## Alternatives considered

* **mosdns or chinadns-ng beside the engine** — a second policy language
  and a second set of domain lists, and no shared fake-IP table.
* **Engine DNS with fake-IP always on** — breaks the few applications that
  cannot tolerate 198.18.0.0/15, with no supported escape.
* **Fake-IP always off** — more leakage of the destination name's timing
  and a slower first connection, for every user, to avoid a rare breakage.
