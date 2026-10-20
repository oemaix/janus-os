# ADR-0025 — tun runs the gvisor stack

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-10-18 |
| Affects | 07 §2; refines ADR-0011 |

## Context

Janus routes intercepted LAN traffic into the engine with policy
routing, not with sing-box's own `auto_route`. The rules in
`modules/janus/proxy/lower.nix` mark proxied flows `0x4a01`, and
`ip rule` sends that mark to table 2022, whose default route is `tun0`.

sing-box's default `system` stack assumes it owns the routes it
installed. On Linux it answers the flows its own `auto_route` table
produces. Flow forwarded from the LAN onto `tun0` by an external rule
reaches the interface, but the system stack does not complete the
handshake: a four-hop nftables counter chain (prerouting, forward,
postrouting) showed every SYN arriving at `tun0` while the engine
logged no matching inbound connection. UDP was unaffected, which is why
DNS looked healthy while every proxied TCP flow timed out.

## Decision

The sing-box tun inbound renders `stack: gvisor`, in
`janet/janus.janet`. Janet writes the field; a fleet never sets it.

## Consequences

Positive: proxied TCP flows work with policy routing. This is the
configuration Janus's own architecture requires, so it is not a
workaround.

Negative: gvisor is a userspace TCP/IP stack and is slower than the
kernel's. On the reference board the difference is invisible at LAN
rates, and it is the price of `auto_route = false`.

Follow-up: xray does not expose the choice. ADR-0006 keeps the engines
behind one model, so the field lives in the sing-box branch only.

## Alternatives considered

`stack: system` with `auto_route = true` — rejected. It gives up the
policy-routing design of ADR-0011, forces the engine to own table 2022,
and reintroduces the route fights the current split avoids.

`stack: system` with `auto_route = false` — rejected. It is the
configuration this ADR replaces: forwarded SYN/ACK never completes.
