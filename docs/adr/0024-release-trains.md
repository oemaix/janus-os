# ADR-0024 — Release trains are branches; versions are tags

| Field | Value |
|-------|-------|
| Status | Accepted; refines the release pin in ADR-0018 |
| Date | 2026-10-17 |
| Affects | 09 §3 and §10, 12 §6, 16 §0 and §6; refines ADR-0018 |

## Context

ADR-0018 pins the private repo at a Janus release and updates it with
`nix flake update janus`. Those two requirements disagree when the flake
URL contains a git commit. Nix treats `github:oemaix/janus-os/<40-hex>`
as a locked reference, and `nix flake update` does not move it. The URL
has to name something that update is allowed to follow. A tag names one
version and does not advance to the next one.

Nix also does not expose the fetched git ref as `self.sourceInfo`. The
program that runs `init` cannot ask the flake which branch it was fetched
from. The tree has to record its own train.

## Decision

1. A train is a branch. `janus-build update` follows that branch. The
   trains are `main` and `X.Y` (major.minor, no leading zeros). `main` is
   development. `X.Y` is a release train for end users.
2. A version is an immutable tag `vX.Y.Z` on branch `X.Y`. The tip of
   `X.Y` is always that tag. Tags are not flake URLs written by `init` or
   `update`.
3. `inputs.janus.url` is `github:oemaix/janus-os/<train>`. `flake.lock`
   records the commit in `locked.rev`. The lock's `original` names the
   branch and has no `rev`.
4. `janus-build update` runs `nix flake update janus` and leaves the URL.
   `janus-build update --train <train>` rewrites the URL to that train,
   then updates the lock. It does not build or deploy. It refuses a tag,
   a patch number, a commit, and any other name.
5. The file `train` in the Janus repository is one line, `main` or `X.Y`.
   `init` copies that line into the URL. Cutting train `1.3` is a commit
   that exists on branch `1.3`, sets `train` to `1.3`, and is tagged
   `v1.3.0`. `main` keeps `main`.
6. A bugfix or a backport of train `X.Y` is a short-lived branch
   `X.Y-<topic>`, cut from the tip of `X.Y`. The `train` file on it stays
   `X.Y`. It merges into `X.Y` as the commit tagged `vX.Y.(Z+1)`. It is
   not a train, and `--train` refuses it.
7. A dirty Janus tree has no revision. `init` writes a `path:` URL of
   that tree. `--train` is how that fleet joins a branch.

Semantic versions, as in *09* §10:

* **Patch** (`v1.3.4`) stays on train `1.3` and on the same Nixpkgs stable
  branch. The pinned Nixpkgs commit may advance. Fleets already on `1.3`
  take it with `janus-build update`.
* **Minor** (`v1.4.0`) is a new branch `1.4`. It may move to the next
  Nixpkgs stable. An existing fleet changes with `--train 1.4`.
* **Major** (`v2.0.0`) is a new branch `2.0`. Removed options, or an image
  layout that is not a closure deploy, are a major.

## Consequences

* `janus-build update` moves a fleet along one train and does not jump to
  the next minor or to `main`.
* The image still records a git revision in `build.json`. The version
  operators compare with the changelog is the tag on that revision.
* A clean `init` locks the commit of the `janus-build` that ran it. The
  commit has to be on `github:oemaix/janus-os`. Evaluation of a lock that
  names an unpublished commit fails until that commit is pushed, or until
  the fleet joins a train with `--train`.

## Alternatives considered

* **A commit hash in the URL** — reproduces the tool's revision and makes
  `nix flake update janus` a no-op. Rejected.
* **A version tag in the URL** — pins one release. Update does not select
  the next tag. Rejected as the thing `update` follows.
* **A standing `X.Y-dev` branch** — would be a second ref beside the
  train. Anyone who selected it would receive untagged commits from
  `janus-build update`. Maintenance work fits on `X.Y-<topic>` and merges
  back only as a tag. Rejected.
* **Reading the git branch at init** — the flake's `sourceInfo` has no
  ref, so a local checkout and a GitHub fetch of the same commit look the
  same. The `train` file is the record that travels with the commit.
