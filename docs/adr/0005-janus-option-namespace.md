# ADR-0005 — Router-style `janus.*` option layer lowering to NixOS

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 03 FR-CFG-*, 08 |

## Context

The configuration must be "router config style rather than computer style",
accurate and comprehensible, powerful yet finishable by copying an example,
and documented without teaching Nix. Standard NixOS options are host-shaped
(`networking.interfaces.eth0.ipv4.addresses`) and spread the router's
concerns over many unrelated modules.

## Decision

All Janus configuration lives under one namespace, `janus.*`, organised by
router concern (`hardware`, `storage`, `network.{ports,vlans,wans,lans}`,
`firewall`, `proxy`, `dns`, `monitoring`, `remoteAccess`, `access`,
`system`). Named collections are attribute sets keyed by user-chosen names so
that objects reference each other by name. Every option carries a
description, type, default/example; the reference is generated from the
modules. The layer *lowers* into standard NixOS options; it never forks
them. Plain NixOS options remain usable next to `janus.*`.

## Consequences

* Users learn one coherent vocabulary; the example configuration is
  self-explanatory.
* Strong evaluation-time validation (types + assertions) replaces runtime
  surprises.
* Janus must maintain the lowering code against NixOS changes (mitigated by
  pinning stable releases and golden tests).
* Power users can still reach every NixOS knob.

## Alternatives considered

* **Directly exposing NixOS options with documentation** — comprehensible
  only to NixOS users; no router vocabulary; no cross-object validation.
* **A YAML/UCI-like config translated to Nix** — loses the module system's
  merging, typing and escape hatch; adds a second language.
