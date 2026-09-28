# ADR-0015 — libqmi and libmbim command-line tools

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *10* §4.2 |

## Context

QMI and MBIM dongles need a control plane for connect and status.
ModemManager does that, and it is a large daemon. Ethernet-mode modules
(ECM, NCM, RNDIS) already present a DHCP link and do not need it.

## Decision

For a QMI device the control plane is `qmicli`. For an MBIM device it is
`mbimcli`. ModemManager is not used. Ethernet-mode WWAN stays a DHCP
client and does not run these tools.

## Consequences

* The image carries the two CLIs only when a QMI or MBIM peripheral is
  declared.
* Status (signal, operator, SIM) comes from those tools, not from
  ModemManager.

## Alternatives considered

* **ModemManager** — one daemon for every modem, more than the allowlist
  needs.
