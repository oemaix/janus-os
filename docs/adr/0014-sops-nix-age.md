# ADR-0014 — sops-nix with age for credentials

| Field | Value |
|-------|-------|
| Status | Accepted; key custody and the single secrets file are refined by ADR-0022 |
| Date | 2026-09-23 |
| Affects | 03 FR-SEC-002, 08 §11, 11 §4.3, 12 §2 |

## Context

Credentials in this project are the PPPoE username and password, the Wi-Fi
passphrase, subscription URLs (they usually embed a bearer token), manual
node secrets, and WireGuard or mesh keys. The Wi-Fi SSID is not a secret.
Node lists fetched from a URL are volatile data, not credentials.

An earlier draft deferred secrets to files dropped onto the state partition
and left sops-nix as a later option. That split makes the private config
repo unable to hold a complete router, and it puts plaintext into the Nix
store if the values are inlined instead.

## Decision

sops-nix with age is the default. `secrets.yaml` lives in the user's private
config repo. The age private key is generated on the build host before the
first image build, never committed, and installed once onto the state
partition. Activation decrypts into `/run/secrets`. Inline plaintext
requires `janus.security.allowInlineSecrets`. `janus secrets put` remains
for a value that should not enter git.

Subscription URLs are sops secrets. A hot override (ADR-0017) may replace
one on the board; the replacement is mode `0600` and is drift until
`secrets.yaml` is updated.

## Consequences

* The first boot cannot decrypt until the age key is installed. Day-0
  documents that step.
* An attacker with the SD card can read the key and the ciphertext. That
  residual risk is unchanged from plaintext files on `/var`.
* Janus documents one path. agenix is not a second supported integration.

## Alternatives considered

* **agenix** — same threat model, fewer features, less familiar in a
  multi-host NixOS repo.
* **Files only** — nothing secret in git, so the repo is not a full
  description of the router.
* **Leaving subscription URLs in plaintext because node lists change** —
  confuses the URL with the list. The token is stable and sensitive.
