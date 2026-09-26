# ADR-0020 — Keep Janet; do not move tooling into Go

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-26 |
| Affects | ADR-0008, 07 |

## Context

sing-box and Xray are Go programs. The question is whether the Janet
matcher, normalizer, and runtime renderer should move to a Go tool, on
the expectation that Go can offer pattern matching beyond regular
expressions in the same way Janet PEG does.

## Decision

Stay on ADR-0008. Janus does not link against the engines. It runs their
binaries and writes their configuration. Sharing a language with them
shares nothing else.

PEG patterns are user configuration, evaluated again whenever a
subscription refresh changes node names. That requires an interpreter.
Janet's `peg` module is that interpreter. The usual Go PEG tools generate
Go source and then need a compiler. Compiling a user pattern on the board
is a build, which ADR-0017 forbids. Go can express richer matching than
regular expressions, and so can Janet; the language of the engines is not
what provides the matcher.

## Consequences

* Contributors keep a small Janet tree.
* armv7l and riscv64 do not gain another helper that must be cross-compiled
  for every pattern change.

## Alternatives considered

* **A Go normalizer with regex and glob only** — drops PEG, which the
  original requirement asked for.
* **Generating Go matchers at image build time** — a later refresh cannot
  recompile them on the board.
* **Embedding the engines as Go libraries** — they are not built for that,
  and their version churn would enter the Janus build.
