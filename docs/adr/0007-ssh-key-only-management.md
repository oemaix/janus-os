# ADR-0007 — SSH public-key-only management, `janus` CLI, no GUI in 1.0

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 03 FR-ACC-*, 11 §4.1, 12 §3 |

## Context

The note requires SSH with the public key in the configuration, no password
login by default (optionally enabled after key login), and defers a GUI.
Operators still need a friendly way to see status, pick nodes and trigger
refreshes without memorising systemd unit names.

## Decision

* OpenSSH is the sole management entry point; at least one authorized key is
  required at evaluation; password authentication is opt-in and never
  sufficient on its own.
* SSH listens only on LAN and `mgmt` zones by default.
* A `janus` CLI provides all day-2 operations with human and JSON output.
* No GUI in 1.0; a read-only status page is a Phase-4 exploration.

## Consequences

* No web attack surface on the router; management is scriptable from the
  build host.
* Losing the private key means rebuilding the image — accepted by the note.
* The CLI is a first-class deliverable with its own tests.

## Alternatives considered

* **Web GUI (LuCI-like)** — large surface and effort; the declarative model
  makes on-device editing counterproductive anyway.
* **Password login by default** — rejected for brute-force exposure.
