# ADR-0022 — Per-host age keys; the build host encrypts only

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-29 |
| Affects | 03 FR-SEC-002, FR-OPS-008, FR-OPS-010, FR-OPS-012, 08 §11, 11 §4.3, 12 §1–2 and §7, 14 §3–4, 16 §2 and §4–5; refines ADR-0014 and the secret-file sentence of ADR-0018 and ADR-0021 |

## Context

ADR-0014 encrypts every credential to one age key. That private key is
kept on the build host and copied onto every router. The ciphertext in
the private repo is then readable by the build host and by anyone who
has any one SD card. One card yields the Wi-Fi passphrase, the PPPoE
password, every subscription URL, the Tailscale auth key, and the
WireGuard private keys of the whole household.

That key is an age identity used to encrypt credentials. It is not an
SSH host key. SSH host keys stay generated on first boot and stored
under `/var/lib/janus/etc`.

## Decision

Each router has its own age keypair. The build host keeps the public
key only. It can encrypt. It cannot decrypt.

1. `janus-build secret keygen <host>` creates the keypair as a life-cycle
   step. It does not run inside a Nix derivation. The public key is
   committed at `secrets/keys/<host>.pub`. The private key is installed
   on that router at `/var/lib/janus/secrets/age.key` and is not retained
   on the build host. The user's password manager is the backup copy.
   `janus backup` still contains the key, because git cannot recreate
   it. That archive is not a working key left on the build host.
2. There is no `janus-build secret edit`. `janus-build secret set <path>`
   reads new plaintext on stdin, encrypts it to the recipients of that
   path, and writes ciphertext. It does not write a plaintext file.
3. The repo holds ciphertext so an image can decrypt at boot. It is not
   the plaintext credential store. Wi-Fi keys, PPPoE passwords,
   Tailscale auth keys, and subscription URLs are supplied from outside
   the repo when they change. Losing a private key means generating a
   new keypair and entering those secrets again.
4. One credential is one file:

   ```text
   secrets/keys/<host>.pub
   secrets/wifi/<host>/<ap>.yaml
   secrets/pppoe/<host>/<wan>.yaml
   secrets/tailscale/<host>.yaml
   secrets/wireguard/<host>/<name>.yaml
   secrets/subscription/<vendor>.yaml
   secrets/nodes/<name>.yaml
   ```

   A path under `wifi/`, `pppoe/`, `tailscale/`, or `wireguard/` is
   encrypted to that host's public key. A path under `subscription/` or
   `nodes/` is encrypted to every host whose configuration references
   that file. Replacing one file does not require any other plaintext.
5. `janus-build fleet pull` with no host reads every reachable router.
   By default it writes non-secret overrides only
   (`hosts/<host>/overrides.nix`) and names secret overrides without
   their values. `--with-secrets` asks the router to decrypt. The build
   host re-encrypts to the public keys, writes the yaml files, and warns
   that the values were plaintext in that SSH session. A shared file
   that two reachable routers disagree on is left unchanged.
6. `janus-build fleet apply` does not decrypt. It sends secret
   ciphertext to the router. The router decrypts with its own age key
   and applies the override.
7. The router has no `janus override export`. `janus override show`
   redacts secret values. `janus override show --secrets` is the stdout
   `fleet pull --with-secrets` reads.
8. The private key is not an output of the image derivation and does not
   enter the Nix store.

Adding a host to a shared file needs the plaintext again (`secret set`)
or `janus-build secret rewrap <path> --from <host>`. Rewrap asks a
router that can already decrypt, then encrypts to the current recipient
set. It carries the same plaintext warning as `--with-secrets`.

## Consequences

* One SD card reveals secrets encrypted to that router, including shared
  subscription URLs and node files that list it. It does not reveal
  another router's Wi-Fi, PPPoE, Tailscale, or WireGuard secret.
* After the private key is installed and discarded, the build host
  holds ciphertext and public keys. A backup archive kept on that
  machine, or a `--with-secrets` / `rewrap` session, is plaintext or a
  private key again.
* The first boot cannot decrypt until that host's private key is
  installed.
* A shared secret is still readable by every recipient. Encrypting it
  to several public keys does not hide it from those routers.
* SSH host keys are unchanged.

## Alternatives considered

* **One age key on the build host and on every router** — the ADR-0014
  custody model. Any one card decrypts the household.
* **Generate the private key inside `nix build`** — the key lands in the
  store, and the image is no longer reproducible.
* **The router generates the key on first boot** — the build host never
  sees the private key, but the first image cannot contain ciphertext
  until a second round trip. Rejected as the default.
* **No ciphertext in git** — the repo cannot describe a router that
  knows its credentials. Rejected for the same reason as in ADR-0014.
* **`janus override export` on the router** — a second path that dumps
  plaintext. Pull on the build host is the only path.
