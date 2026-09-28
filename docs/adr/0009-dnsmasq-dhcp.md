# ADR-0009 — dnsmasq for DHCP

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *06* §6, *04* §2, *05* §6 |

## Context

Each LAN needs DHCPv4, static leases, a few custom options, and a small
lease file on `/var`. Router advertisements stay with networkd
(`IPv6SendRA=`). Kea maps cleanly from Nix and has a durable lease file,
and it is a large package for that job.

## Decision

dnsmasq serves DHCP only. It is not a second DNS policy engine. DNS stays
inside the proxy engine (ADR-0019). RA stays with networkd.

## Consequences

* One small lease file on the state partition.
* A later need for Kea's lease database is a new ADR.

## Alternatives considered

* **Kea** — better lease tooling, more than this router needs.
* **networkd's built-in DHCP server** — fewer knobs for static leases and
  per-LAN options.
