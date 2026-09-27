# ADR-0021 — Local git is mandatory; one repo may hold many routers

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-26 |
| Affects | 03 FR-CFG-010/011, FR-OPS-010, 09 §3; refines ADR-0018 |

## Context

Flakes only see a local project when it is a git tree, and they skip
uncommitted files. That is a real barrier for someone who does not use a
remote git host. The same person may have several routers that should
share one subscription. Hot overrides also raised the idea that the board
itself would push to the remote, or pull from it and apply the result.

## Decision

1. The private config project MUST be a local git repository. A remote is
   recommended and not required to build.
2. One repo MAY define many routers as `nixosConfigurations.<host>`,
   sharing modules such as `common/proxy.nix`. The entry file is
   `configuration.nix`. `janus_configuration.nix` and
   `janus-configuration.nix` are not used.
3. The board has no credential for that remote. It does not push overrides
   and it does not fetch the repo. `janus-build fleet pull` runs on the
   build host over SSH; a person commits there.

## Consequences

* The manual's first-run path is `git init` and a commit, not "create a
  GitHub account".
* Losing the laptop loses the repo unless a remote or another copy exists.
  That is the reason to recommend a remote, not a reason to require one.
* Shared subscription URLs live in one sops file imported by each host.
  Rotating that secret is one edit. `janus-build fleet apply` copies the
  committed hot-override projection onto the reachable routers
  (FR-OPS-012, *16*).

## Alternatives considered

* **Remote git required** — excludes anyone who can commit locally and
  cannot or will not operate a forge. The declarative record is the local
  history; the remote is a copy of it.
* **No git at all** — flakes will not evaluate the config reliably, and
  there is no history to diff against the router.
* **One file name with a `janus_` prefix** — NixOS and the template already
  use `configuration.nix`. A second name is a second thing to teach.
* **The router pushes or pulls** — puts a forge credential on the board and
  brings Nix evaluation back onto the device.
