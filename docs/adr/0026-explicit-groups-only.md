# ADR-0026 — Explicit groups only

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-10-18 |
| Affects | 07 §4, 08 §6, 21 §2; refines ADR-0006 |

## Context

The renderer always generates two kinds of group. Every node lands in an
implicit `Auto` url-test group, and every subscription becomes a
`sub:<name>` url-test group over its own nodes. docs/07 §4 documents
both, and docs/08 §6 says `Auto` exists unless the fleet defines
`groups.Auto`.

A router that wants one hand-picked group pays for three. The panel
shows `Auto`, `sub:<name>`, and the fleet's own group. Two of them
re-select a node on a timer the operator did not ask for, and a url-test
group that flips under a stable NAT mapping is a support problem, not a
feature.

The tunnel DNS resolver used the literal tag `Auto` as its detour, so
removing the group would have left a dangling reference.

## Decision

`janus.proxy.groupsAuto` (default `true`) controls the implicit groups.
When `false`, the renderer emits neither `Auto` nor `sub:<name>`. The
fleet must then name its own groups, and `defaultTarget` and every rule
must target a defined group or `direct`/`block`. Evaluation fails
otherwise, and the option is refused for the xray engine, which cannot
express a fleet-only group set (ADR-0006).

The tunnel DNS detour follows the default target instead of the literal
`Auto`, so it stays correct whichever way the option is set.

## Consequences

Positive: a fleet that wants one manual selector states one group and
sees one group. No timer re-selects a node behind the operator's back.

Negative: `groupsAuto = false` puts the membership burden on the fleet.
A regex or an explicit member list must list every node the fleet wants,
and a subscription that renames its nodes silently shrinks the group.

Follow-up: the empty-group fallback and `emptyFallback` keep a
mistyped regex from producing an unroutable engine.

## Alternatives considered

Keep the implicit groups and tell operators to ignore them — rejected.
A visible group that re-selects nodes is indistinguishable from a
supported one, and the support cost lands on the fleet author.

Delete the implicit groups outright, no option — rejected. Existing
fleets rely on `Auto`, and docs/08 §6 promises it. The option keeps the
default and makes the reduction opt-in.
