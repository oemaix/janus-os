# ADR-0028 — Label types, selectors, and region codes

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-11-12 |
| Affects | 03 FR-PRX-029; 07 §11; refines ADR-0027 |

## Context

ADR-0027 names a label as a key plus a string token or a non-negative
integer, and a selector as an AND of string sets and numeric `below` or
`above`. Predefined keys there are `vendor`, `region`, and `latency`.

The operator needs declared types, a presence label, country codes, and
OR and NOT, written as Nix literals. A SQL WHERE string or a Janet
snippet would be a program inside `configuration.nix`. FR-CFG-003 keeps
the operator on literals, lists, and attribute sets.

## Decision

The binding text is *07* §11. In addition to ADR-0027:

* A key starts with a Unicode letter or `_`. The rest is letters,
  digits, `_`, or `-`. A leading digit or hyphen fails evaluation.
  `any`, `all`, and `not` are not keys.
* The types are `string`, `number`, `bool`, `enum`, `empty`, and
  `region`. One key has one type. `number` is a number. A missing label
  is absent.
* `empty` is presence only. The only value that evaluates is the key
  written again as a string: `gemini = "gemini"`. Any other value fails
  evaluation.
* `janus.proxy.labels.<key>` is one attribute. It holds `type` and the
  labeling rules. An `enum` also holds `values`.
* `vendor` (`string`), `protocol` (`enum`), and `latency` (`number`) are
  present on every node. The operator does not redeclare them.
  `protocol` is the union `vless`, `vmess`, `trojan`, `shadowsocks`,
  `hysteria2`, `tuic`, taken from the node, and `labels.protocol` fails
  evaluation. Before the first latency sample the stored number is the
  timeout in milliseconds. A failed probe keeps the previous number.
* `region` is a built-in type, like `number`. The module does not
  declare a `region` key. A value evaluates when it is an officially
  assigned ISO 3166-1 alpha-2 code, or user-assigned in `qm`–`qz`,
  `xa`–`xz`, or `zz`. The operator chooses what a user-assigned code
  means. `uk` fails evaluation. The United Kingdom is `gb`. `eu` fails
  evaluation. The officially assigned list is not copied here. A later
  update replaces it when ISO assigns or withdraws a code.
* Kind `geoip` is legal only on type `region`. It writes the officially
  assigned code of the node address and never a user-assigned code. No
  database row, a failed lookup, or a code outside the shipped official
  set leaves the key absent unless a later rule sets it.
* Kind `http` is legal only on type `empty`, and that key has that one
  rule. The request goes through the node. Status 200–299 on the first
  response sets the label. Any other outcome clears it.
* Name rules and `geoip` run once after the node list is normalized, at
  build and on subscription refresh. They do not run per connection.
  Kind `query`, which would read other labels, is not accepted yet.
* A selector is a Nix attribute set. Key tests on one set combine with
  AND. `any` is OR and unions the members. `all` is AND of selectors.
  `not` matches when the inner selector does not. A `not` on one key
  matches only when that label is present and the inner test fails. A
  `string` constraint may be an exact token, a list of tokens, or a §4
  matcher (`regex`, `glob`, or `peg`).
* A rule has one of `target` (`direct` or `block`), `labels`, or an
  ordered `failover` list. `failover` uses the first selector that has a
  member and does not union the branches. An empty result warns and
  uses `direct`. It does not try the next routing rule. The renderer
  still emits one outbound set for the selector that won.
* When this model replaces §4, `janus.proxy.groups` and
  `janus.proxy.groupsAuto` are removed. A configuration that sets either
  fails evaluation. There is no compatibility and no migration. The
  configuration, the maintenance page, the panel, and the CLI do not
  present a group. The generated outbound tag stays inside the renderer.

## Consequences

ADR-0027 stays the decision that the operator does not name a group and
that sing-box and xray still receive one. The string-or-integer value,
the predefined `region` key, and the `below`/`above` pair in that ADR's
short list are refined here. §4, §5, and §9 stay in force until the *13*
item starts. The module must not grow `janus.proxy.labels` before that
work.

## Alternatives considered

Call the name a symbol or a keyword — rejected. The operator writes a
Nix attribute.

Accept a SQL WHERE clause or a Janet snippet — rejected. Both are
programs.

Test `empty` with `true`, or store `null` — rejected. `true` is a bool.
Nix `null` is also an unset option.

Accept `uk` — rejected. It is not officially assigned and not
user-assigned. The code is `gb`.

Write a placeholder region code when GeoIP misses — rejected. No row
means the label is not set.

Let an empty selector fall through to the next routing rule — rejected.
That rule was written for other traffic.

Treat `any` as failover — rejected. `any` keeps every matching node.
Failover keeps the first branch that has a member.

Keep a compatibility read of `groups` or `groupsAuto`, or generate
labels from them — rejected. The operator would still be maintaining
groups. The options are removed, and evaluation fails if they are set.
