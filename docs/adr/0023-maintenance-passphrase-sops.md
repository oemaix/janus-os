# ADR-0023 — Maintenance page passphrase is a per-host sops file

| Field | Value |
|-------|-------|
| Status | Accepted; refines the secret-file list of ADR-0022 |
| Date | 2026-10-17 |
| Affects | 03 FR-SEC-002, 08 §10–11, 11 §4.1 and §4.3, 16 §2, 20 §1 and §3 |

## Context

ADR-0022 lists one file per credential. The maintenance page login is a
passphrase, separate from the SSH root password. *20* allowed that file
to be either a sops path or a file from `janus secrets put`, and the
sops tree had no entry for it. The other credentials already have a
named file under `secrets/`, encrypted to the routers that may read it.

## Decision

The maintenance page passphrase is a sops secret, one line, one file:

```text
secrets/web/<host>.yaml
```

The file is encrypted to that host only. `janus.access.web.passphraseSecret`
names the `sops.secrets` entry. When `janus.access.web.enable` is true,
exactly one of `passphraseSecret` and `passphraseFile` is set.
`passphraseFile` remains the sibling for a file created on the board
with `janus secrets put`. The passphrase is not a hot override. A change
is `janus-build secret set`, a commit, and a deploy.

## Consequences

* The private repo can describe a router whose page has a passphrase.
  The ciphertext is in git. The plaintext is in `/run/secrets` after
  the age key is installed.
* One SD card reveals that router's page passphrase. It does not reveal
  another router's.
* `passphraseFile` stays for a value that must not enter git.

## Alternatives considered

* **State-partition file only** — the repo cannot describe the login.
  Rejected for the same reason as the other credentials in ADR-0014.
* **One shared file, like a subscription** — every router that references
  it can read every page passphrase.
* **Hot override** — the page passphrase is not rotated on the board.
  The ciphertext in git stays the record.
