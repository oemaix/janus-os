# ADR-0018 — Private config repo, not a fork per user

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-23 |
| Affects | 00 §4 and §9, 09 §3 |

## Context

Flakes evaluate a local project only when it is a git tree, and they skip
uncommitted files. That invited a layout where each user clones Janus OS,
commits personal `configuration.nix` on a private branch, and rebases
forever. It also invited the hope that the running board is "a flake" and
can rebuild itself from that clone.

## Decision

Janus OS is the public upstream flake. Each router has a private config
repository created from `templates.default`. That repo pins
`inputs.janus.url` to a release and contains `configuration.nix` (one file
or several modules) plus `secrets.yaml`. The board stores an embedded copy
of that tree (FR-CFG-008). It does not contain a checkout used for
evaluation.

Users commit in the private repo before `nix build`. They do not fork the
OS repository to hold a household configuration, and they do not keep one
OS branch per device.

## Consequences

* Updating Janus is `nix flake update janus` in the private repo.
* Personal configuration never has to be pushed to the public project.
* A dirty private repo fails the build in the usual flake way, on the
  build host, where fixing it is a commit.

## Alternatives considered

* **Fork Janus OS per user** — couples household secrets and LAN addresses
  to OS history and makes updates a rebase.
* **One clone with many branches** — same coupling, easier to push a secret
  to the wrong remote.
* **Drop flakes so the board can edit `configuration.nix` without git** —
  gives up the pin and the template model to solve a problem hot overrides
  already cover.
