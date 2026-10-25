# Security policy

## Reporting

Report a vulnerability through
[private vulnerability reporting](https://github.com/oemaix/janus-os/security/advisories/new).

A public issue or pull request stays free of exploit detail. Leave
credentials, subscription URLs, age keys, and node lists that name a
relay out of the report. Name the revision, the board when the fault is
on a device, and what an attacker gains.

There is no bug bounty. The project promises no response time. A report
is read, and a fix lands in the repository when there is one. Describe
the exploit in public after that fix is on the maintained line.

## Scope

In scope:

- This repository.
- The image built from it.
- `janus` and `janus-build`.
- The maintenance page.
- Handling of credentials in the ways [docs/11-security.md](docs/11-security.md) describes.

Out of scope:

- A private config repo that pins Janus OS.
- A subscription provider, or a relay the operator chose.
- A defect in Nixpkgs or NixOS. Report that upstream.
- Physical access to the SD card. [docs/11-security.md](docs/11-security.md) §5 records that residual risk.

## Fixes

Janus has no on-device updates. A security fix ships as a new commit on
the maintained line. The operator rebuilds the image.

The maintained line today is `main`. A release train is a branch `X.Y`
(ADR-0024). Once that branch exists, a fix for it is the next tag
`vX.Y.Z` on that branch. `janus-build update` follows the train the
fleet already pins. [docs/11-security.md](docs/11-security.md) §6 is
that update rule.
