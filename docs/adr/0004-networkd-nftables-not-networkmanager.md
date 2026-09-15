# ADR-0004 — systemd-networkd + nftables instead of NetworkManager

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 04 §3.2, 06 §1 |

## Context

The note asks whether Janus could reuse NixOS's NetworkManager network
definitions rather than inventing its own. Janus needs bridges, VLANs,
multiple WANs with per-WAN routing tables, PPPoE, DHCP client options,
RA/PD, and a firewall that is generated from the same model.

## Decision

Janus lowers its `janus.network.*` and `janus.firewall.*` options into
**systemd-networkd** units (`.link`, `.netdev`, `.network`), **pppd** units
for PPPoE, and a single generated **nftables** ruleset. NetworkManager is
not installed. Raw `systemd.network.*` and `networking.nftables.*` options
remain available to users as an escape hatch; Janus merges with them.

## Consequences

* Deterministic, file-based network configuration that matches the
  declarative model; no D-Bus policy layer, smaller image.
* Multi-WAN policy routing (`RoutingPolicyRule`, per-link tables) and VLAN/
  bridge handling are native to networkd.
* PPPoE is not handled by networkd; a pppd unit per PPPoE WAN publishes its
  state for the rest of the system.
* DHCP/RA server is a separate decision (ADR-0009).
* Users with NetworkManager habits must learn Janus vocabulary — which is
  the point: the vocabulary is router-shaped, not host-shaped.

## Alternatives considered

* **NetworkManager** — designed for roaming hosts; its NixOS module is
  imperative-friendly (`nmcli`, keyfiles), weak at multi-table policy
  routing and bridges-of-VLANs; pulls in ModemManager/wpa_supplicant
  machinery by default.
* **Legacy `networking.interfaces` scripts** — being phased out in NixOS;
  no PD/RA support.
* **iptables/firewalld** — nftables is the kernel's current framework and
  allows one atomic ruleset with sets and maps, which the generator relies on.
