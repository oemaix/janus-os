# ADR-0016 — Fail closed when the engine is down

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *07*, *11*, *12* §4 |

## Context

While sing-box or Xray is down, traffic that was supposed to be proxied
can either leave through the WAN or stop. Leaving through the WAN is a
leak of the flows the user meant to tunnel.

## Decision

Engine failure fails closed. Proxied traffic is dropped until the engine
is back. It is not sent out the WAN. `janus.proxy.failMode` may be set to
`open` by an operator who accepts that leak. The default is `closed`.

## Consequences

* A dead engine looks like a dead network for proxied LANs, which is the
  visible failure.
* Flows whose rule target is already `direct` are unchanged. This ADR
  covers traffic the engine was supposed to carry.

## Alternatives considered

* **Fail open** — the LAN keeps working, and the tunnel's purpose is
  silently dropped.
