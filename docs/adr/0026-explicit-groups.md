# ADR-0026 — Explicit groups omit the implicit Auto and subscription groups

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-10-28 |
| Affects | 03 FR-PRX-010; 07 §4; refines ADR-0006 |

## Context

The model always renders two implicit groups. `Auto` is a url-test over
every node. Each enabled subscription is `sub:<name>`, also url-test.
A fleet that names its own groups still receives both, and tunnel DNS
detours through the literal tag `Auto`.

That tag is the xray remote-DNS balancer. sing-box can detour one DNS
server through any outbound. xray 26 has one DNS module and one balancer
tag for the remote resolvers.

An empty group whose fallback is not an outbound, and a `manual` default
that is not a member, make sing-box refuse to start.

The field report is from wuxiao.

## Decision

`janus.proxy.groupsAuto` defaults to true. True keeps `Auto` and
`sub:<name>`, so a fleet that does not set the option is unchanged.

False omits both. It fails evaluation on xray. On sing-box, the router
default target, every router rule, and a LAN's own `defaultTarget` and
`proxy.rules` must name `direct`, `block`, or a group the fleet defined.
The same check accepts `Auto` while the implicit group exists, or when
the fleet defined `groups.Auto`. Tunnel DNS uses that default target.
A fleet group named `Auto` does not keep the detour on that tag.

`emptyFallback` must be `direct` or `group:<name>` for a group that
exists. sing-box renders that tag. xray renders `direct`, because a
balancer selector cannot name another group. A `members` entry
`sub:<name>` requires the implicit groups. `group:<name>` must name a
group on this router. A `manual` default must be a member when the group
has no matcher. A matcher that matches nothing stays a warning and uses the
fallback. A `manual` default that is not in the rendered member list is
a warning, and the first member is used.

## Consequences

A fleet can publish only the groups it named. Current fleets keep the
implicit groups.

xray keeps `Auto` as the remote-DNS balancer. Dropping it is a feature
that engine does not express (ADR-0006).

## Alternatives considered

Drop the implicit groups whenever `groups` is non-empty — rejected.
A fleet can define a group and still want `Auto` as the default target.

Let `groupsAuto = false` evaluate on xray and point the one DNS balancer
at the default group — rejected. The remote-DNS path on xray is the
implicit `Auto` group, and the option stays sing-box only.
