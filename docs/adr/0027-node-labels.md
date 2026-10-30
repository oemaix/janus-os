# ADR-0027 — The operator configures labels; the engine still receives a group

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-10-30 |
| Affects | 03 FR-PRX-029; 07 §11; *13* Future; refines ADR-0006 when that work lands |

## Context

A group is a named set of nodes plus a selection strategy. Membership is
one name matcher or a manual list. A routing rule then names that group.
A household that wants "region Japan, Korea, or Singapore, and latency
under 150 ms" has to pre-build a group for each combination.

sing-box accepts a `urltest` or `selector` outbound. xray accepts a
balancer. Neither engine matches a node by an arbitrary key at connection
time. ADR-0006 keeps one canonical model and two renderers. ADR-0026
keeps the implicit `Auto` group on xray because remote DNS has one
balancer tag.

The field request is labels: key-value pairs on the node, and a rule that
constrains several keys. The operator should not see a group.

## Decision

This ADR specifies that later model. It does not replace the current
group options. Until the *13* item is implemented, §4, FR-PRX-010 through
FR-PRX-015, a group target in FR-PRX-021, and ADR-0026 stay in force.
The module must not grow `janus.proxy.labels` before that work.

When the item lands, the operator configures labels and label constraints
only. The text that binds is *07* §11. In short:

* A label is a key and a value. The value is a string token or a
  non-negative integer. Predefined keys are `vendor`, `region`, and
  `latency`. The operator may add keys.
* `vendor` is the subscription name. A manual node uses the value set in
  its configuration, or `unknown` when unset.
* `region` and any custom key are set by an ordered labeling rule
  (name matcher, or GeoIP of the node's server address) or by an explicit
  value on a manual node. The explicit value wins. Subscription nodes stay
  immutable (FR-PRX-007).
* `latency` is the TCP-connect time in milliseconds, or a string band
  (`low`, `mid`, …) when the labeling rule says so. A missing sample does
  not match a latency constraint.
* A routing target is `direct`, `block`, or a selector. A selector
  constrains one or more keys. String keys take a set of values (any one
  matches). Number keys take `below` or `above`. Keys combine with AND.
  The operator does not name a group. Two rules that want the same
  constraint share one Nix value.
* The renderer emits one engine group per distinct selector: sing-box
  `urltest`, xray leastPing balancer, members a flat node list. The tag
  is generated. An empty match warns and uses `direct`.
* The engine url-test picks inside that set and moves when a member stops
  answering. `janus proxy select` and `load-balance` are not part of this
  operator model.

## Consequences

The operator writes node properties and constraints. sing-box and xray
still receive a group. Fake-IP treats a selector as a proxied target, the
same way D-0037 treats a group target.

ADR-0026 remains the rule for the group model. After this item replaces
that model, xray remote DNS uses the generated tag of the default
selector, and `groupsAuto` has no operator option.

`manual` selection, `load-balance`, and the tunnel pages that call
`janus proxy select` leave with the group names. The panel, the
maintenance page, and the CLI then show labels and the node the engine
picked.

The manual-node `tags` string list is a different field. This ADR does
not redefine it.

## Alternatives considered

Keep groups as the operator object and add labels only as a matcher —
rejected. The request is that the operator does not manage groups.

Let the engine match labels itself — rejected. sing-box and xray take a
named outbound set, not a key-value predicate.

Expose the generated group name for `janus proxy select` — rejected. That
name would be a group in the operator interface again.
