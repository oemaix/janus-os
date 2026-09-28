# ADR-0012 — Impure subscription fetch, optional snapshot hash

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *07* §3.2, *09* §5 |

## Context

A subscription URL changes. A required hash on every build would make a
normal rebuild fail until someone pastes a new hash. A fully pure fetch
of a live URL is not possible.

## Decision

The build-time fetch is impure by default. `snapshot.hash`, when set, pins
that snapshot as a fixed-output derivation.

## Consequences

* A rebuild without a hash can see a new node list.
* A set hash makes that snapshot reproducible and refuses a different body.

## Alternatives considered

* **Hash required** — reproducible by force, and it blocks a rebuild
  whenever the provider republishes.
