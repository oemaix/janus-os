# ADR-0025 — tun runs the gvisor stack

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-10-28 |
| Affects | 07 §6; refines ADR-0011 |

## Context

Janus routes intercepted LAN traffic into sing-box with policy routing.
`auto_route` stays off. ADR-0011 gives Janus the `ip rule` and the route
to `tun0`.

sing-box's `system` stack answers flows that its own `auto_route` table
produced. A flow that reaches `tun0` from an external rule arrives at the
interface, and the system stack does not finish the TCP handshake. UDP is
unaffected, so DNS can look healthy while proxied TCP times out.

The field report is from wuxiao, 2026-10-18.

## Decision

The sing-box tun inbound renders `stack: gvisor`. Janet writes the field.
A fleet does not set it.

## Consequences

Proxied TCP completes under the policy routing ADR-0011 requires.

gvisor is a userspace TCP/IP stack. It is slower than the kernel stack.
On the boards this tree targets, that cost is the price of
`auto_route = false`.

xray does not expose the choice. ADR-0006 keeps one model, so the field
is sing-box only.

## Alternatives considered

`stack: system` with `auto_route = true` — rejected. It gives the engine
table 2022 and drops the split in ADR-0011.

`stack: system` with `auto_route = false` — rejected. Forwarded TCP does
not complete.
