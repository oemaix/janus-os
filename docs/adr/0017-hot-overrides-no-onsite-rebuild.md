# ADR-0017 — Hot overrides; no Nix evaluation on the board

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-23 |
| Affects | 00 G7, 03 FR-OPS-001/007/008/009, 09 §3, 12 §1; refines ADR-0002 |

## Context

ADR-0002 keeps the board free of compilers and of Nix so a power-loss-safe,
slim image cannot drift into a build machine. Operators still have to
rotate a subscription URL, add a static lease, and switch a dead node
without scheduling an image build. Doing those through on-site
`nixos-rebuild switch` was proposed, including the questions of whether
the system must itself be a flake, whether the Nix store is rewritten, and
whether every edit must be a git commit first.

## Decision

The board does not contain the Nix evaluator, nixpkgs sources, or a
writable store, and it does not run `nixos-rebuild`.

Day-to-day changes are either maintenance actions or hot overrides.
The override allowlist is: the URL of an existing subscription, static
leases of an existing LAN, and the passphrase of an existing Wi-Fi AP.
Values live on the state partition, renderers apply them, and
`janus status` shows drift against the embedded configuration.
`janus override export` is how the change gets back into the private repo.
Adding a subscription, a LAN, a firewall rule, or a port mapping is still
a rebuild on the build host.

`nixos-rebuild` would not rewrite the Nix store. It would add paths. That
fact does not make it cheap: evaluation needs nixpkgs unpacked, a writable
store, a git checkout (flakes ignore uncommitted files), and more RAM than
a Raspberry Pi Zero 2 W has.

## Consequences

* DHCP, subscription fetch, and hostapd must have runtime renderers for
  the allowlist, not only NixOS activation.
* Users who want a change outside the allowlist rebuild. The CLI says so.
* ADR-0002's rule "the board never builds" stands. This ADR narrows the
  rule "every definition change is a rebuild" to structural changes.

## Alternatives considered

* **On-site `nixos-rebuild` for "no compile, just parameters"** — fails the
  RAM, store, and dirty-git constraints above, and teaches users that
  uncommitted edits do nothing.
* **Making every small edit imperative and unrecorded** — the project then
  has a declarative build nobody trusts because the running router no
  longer matches it.
* **Requiring a rebuild for a static lease** — correct and unused. People
  will not do it.
