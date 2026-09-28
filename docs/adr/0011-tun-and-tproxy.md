# ADR-0011 — sing-box TUN, Xray TPROXY

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *07* §2, *07* §5 |

## Context

Transparent proxying can use a TUN device or TPROXY. sing-box owns a TUN
inbound. Xray's transparent path is TPROXY. One default for both engines
would fight one of them.

## Decision

sing-box defaults to TUN, with `auto_route` off, and Janus owns the `ip
rule` and routes. Xray defaults to TPROXY.

## Consequences

* The two renderers do not share one interception implementation.
* A user can still select the engine. They do not pick the inbound; the
  engine's default applies.

## Alternatives considered

* **TPROXY for both** — extra work on sing-box for no gain.
* **TUN for both** — Xray does not take that path as its default.
