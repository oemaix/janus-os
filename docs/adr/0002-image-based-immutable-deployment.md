# ADR-0002 — Image-based, immutable deployment; no on-device builds

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 00 §7 (C-001), 03 FR-BLD-004/007, FR-OPS-001..003, 09 §7–8, 12 §1 |

## Context

The system is almost static. It must not include build environments, and
any rebuild that needs a download or a compilation must fail. At the same time some things must change on the
device: relay-node lists from subscriptions, Geo data, and operator
selections. `nixos-rebuild` on the device would require a writable store,
the Nix daemon, evaluation time and, for any package change, a network
fetch or compilation — all of which contradict the constraints.

## Decision

1. The device never evaluates or builds Nix. `system.switch.enable = false`,
   `nix.enable = false`, `/nix` is read-only.
2. All changes to *configuration* are made on the build host and delivered
   as a new image (1.0) or a pushed closure (later), followed by a reboot.
3. *Data* — content that is expected to change without a configuration
   change (subscription node lists, Geo data, selections, leases, statistics,
   secrets) — lives on the state partition and is refreshed by runtime
   services. Its *definition* (URLs, schedules, groups, rules) remains
   configuration.
4. The image carries a build-time snapshot of all data so it is functional
   at first boot and after a state reset.

## Consequences

* The Board contains no compilers or package tooling; image stays slim.
* "Policy changes" listed in the note (swap ports, add/remove subscriptions
  or nodes) are rebuilds; "refreshes" (node lists, Geo data) are not.
* A runtime renderer is required to regenerate engine configuration from
  refreshed data without Nix; it must share semantics with the Nix-side
  renderer (solved by exporting the canonical model as JSON and using the
  same Janet code at build and run time, ADR-0008).
* Remote closure deployment needs a tool that temporarily remounts the store
  read-write and guarantees no build/fetch on target (`--max-jobs 0`,
  empty substituters).

## Alternatives considered

* **On-device `nixos-rebuild` with remote builders** — requires the device to
  evaluate Nix and reach a builder; slow, fragile in censored networks, and
  needs a writable store.
* **Mutable overlay for config (OpenWrt style)** — reintroduces drift and
  power-loss exposure.
* **Treating subscriptions as configuration only (rebuild per refresh)** —
  impractical for hourly refresh cadences.
