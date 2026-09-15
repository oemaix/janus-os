# ADR-0008 — Janet for PEG matchers, node normalization and runtime rendering

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 04 §3.1, 07 §3–4, ADR-0002 |

## Context

Node grouping must support regex, glob and PEG matching; PEG "implemented in
Janet-lang" is an explicit wish. Independently, ADR-0002 requires that the
engine configuration can be regenerated *at runtime* from refreshed
subscription data with exactly the semantics used at build time, without
Nix on the device. Subscription formats (share links, Clash YAML, sing-box
JSON) need a real parser.

## Decision

Janet is the scripting language for Janus data tooling. One Janet code base
(`janet/`) provides:

* the node normalizer (share links, Clash YAML, sing-box JSON → canonical
  node JSON);
* the matcher engine (regex, glob → PEG translation, native PEG);
* the runtime renderer (canonical model JSON + data → engine config).

At build time Nix invokes the same Janet programs (via `runCommand`) to
produce the snapshot and to validate PEG syntax; at run time systemd
services invoke them on refreshed data.

## Consequences

* Identical grouping/rendering semantics at build and run time by
  construction.
* Small footprint (~1 MB interpreter), no Python/Node in the image.
* PEG gives users structure-aware matching beyond regex.
* Contributors need basic Janet; the code base is small and well-tested with
  a corpus of real subscription samples.

## Alternatives considered

* **Nix only** — cannot run on the device (ADR-0002).
* **Shell + jq + yq** — brittle parsing, no PEG, hard to test.
* **Python** — large runtime in the image; conflicts with slimness.
* **Go tool** — fine performance, but PEG-in-Janet is a stated requirement
  and a compiled tool adds cross-compilation burden for Tier-3 targets.
