# ADR-0013 — Volatile journal

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *04* §7, *08* `journal.*`, *05* §6 |

## Context

The state partition is the only read-write filesystem, and it is small.
A persistent journal grows with every boot and every proxy event. The
router is expected to lose power.

## Decision

journald storage is volatile. `journal.persistent` stays available for an
operator who wants a capped journal on `/var`. The default is off.

## Consequences

* Logs do not survive reboot unless persistence is turned on.
* The state partition is not filled by the journal in the default image.

## Alternatives considered

* **Persistent with a cap** — useful after a crash, and it spends the
  partition we are trying to keep small.
