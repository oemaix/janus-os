# 16 — Build-host command-line specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

`janus-build` runs on the build host, inside the private config repo. The
router command stays `janus` (*14*). The two names share the project and
name different programs. The router image does not contain `janus-build`.
On the board, `janus deploy` and `janus fleet` exit `2` and name the
`janus-build` command.

Nix evaluates and builds. `janus-build` does not replace it, and it does
not grow a recipe language, a layer stack, or a task graph. It drives the
life of a router in this repo, and where a step is a router operation it
SSHes to `janus` on that board.

Exit codes match *14*: `0` success, `2` usage or a refused request, `1` a
runtime failure. A host that does not answer is a failure of that host.
Hosts that succeeded are left as they are and named in the output.

SSH destinations are `janus.deploy.address`, or the
`nixosConfigurations` attribute name when the option is unset.

## 1. Life cycle

| Stage | Command | What it does |
|-------|---------|--------------|
| Create the repo | `janus-build init` | `nix flake init -t` for Janus OS, then `git init` and the first commit if the directory is not already a repository. |
| Age key | `janus-build secret keygen` | Writes `~/.config/janus/age.key` (mode `0600`) if that file is absent, and prints the public key. Refuses to replace an existing key. |
| Edit a secret | `janus-build secret edit` | Decrypts `secrets.yaml` with that key, opens the editor, and writes ciphertext again. |
| Check | `janus-build check [<host>]` | Evaluates the named host, or every host. Prints assertion failures. Builds nothing. |
| Build | `janus-build build [<host>]` | Builds `images.<host>` for one host or every host. Prints the image path. |
| Install an image | `janus-build deploy <host>` | Closure deploy, or a state-preserving re-flash (*09* §8). |
| Push overrides | `janus-build fleet apply` | Committed hot-override projection, over SSH (§4). |
| Pull overrides | `janus-build fleet pull <host>` | Current overrides from one router into this repo (§5). |
| Look | `janus-build status [<host>]` | SSH `janus status` on one host or every host. |
| Save a router | `janus-build backup <host>` | SSH `janus backup` and write the archive on the build host. |
| New Janus pin | `janus-build update` | `nix flake update janus`. Does not build or deploy. |

A later local wizard is a front end for `init` and the first edit. It is
not a hosted builder (*00* §4, *13* Phase 4). Until it exists, `init` is
the creation step.

## 2. Age key

`secrets.yaml` is encrypted to one age key. That private key lives on the
build host and a copy is installed on each router that must decrypt the
file. The build host does not collect a separate private key from each
router. `janus-build secret` and `janus-build fleet` decrypt with the
build-host copy.

| Command | Effect |
|---------|--------|
| `janus-build secret keygen` | Create the key once (§1). |
| `janus-build secret edit` | Edit `secrets.yaml`. The tree must be a git repository. The command does not commit. |
| `janus-build deploy --secrets <dir> <host>` | Install the age key and the other secret files over SSH. |

## 3. `janus-build deploy`

| Command | Effect |
|---------|--------|
| `janus-build deploy <host>` | Remote closure deploy (*09* §8.2). |
| `janus-build deploy --preserve-state <host>` | Copy state off the router, then the caller re-flashes (*09* §8.1). |
| `janus-build deploy --confirm <host>` | Mark the booted generation good after a closure deploy. |
| `janus-build deploy --secrets <dir> <host>` | Install secret files, including the age key, over SSH. |

`deploy` installs a new image. It is how a change outside the hot-override
allowlist reaches a router. The copy onto the board uses `--max-jobs 0`
and an empty substituter list, so a missing store path is an error on the
build host rather than a build on the board.

## 4. `janus-build fleet apply`

Pushes the committed hot-override projection to running routers. It does
not build an image and it does not edit the repo.

```
janus-build fleet apply [<host>] [--only-overrides]
```

No host means every `nixosConfigurations` entry. The git tree must be
clean. The projection, per host, is only:

* `proxy.subscriptions.<name>.url` for a subscription that already exists
  on that host, taken from the sops key its `urlSecret` names
* `network.wifi.<name>.passphrase` for an AP that already exists, taken
  from its `passphraseSecret`
* `network.lans.<name>.dhcp.staticLeases.<host>` written in
  `hosts/<name>/overrides.nix`

Each reachable router receives its own projection through `janus override
set` on that board. A shared subscription secret is the same value on
every host that references it. The URL and the passphrase are passed on
the remote stdin. A changed URL is followed by `janus proxy refresh` for
that subscription.

`/etc/janus/build.json` records `configRevision`, the git revision of this
repo at image build. `fleet apply` diffs that revision to `HEAD`.

| Diff | Result |
|------|--------|
| Only the projection | Apply it. |
| Anything else (firewall, ports, a new LAN, PPPoE, WireGuard, a new subscription) | Print those paths. Exit `2`. Change nothing. |
| The same, with `--only-overrides` | Apply the projection only. Print the paths that still need `janus-build deploy`. |
| The running image has no `configRevision` | Exit `2` until `--only-overrides` is given. |

`--only-overrides` is the confirmation. It never applies a structural
change. An unreachable host is listed and left unchanged.

## 5. `janus-build fleet pull`

Brings one router's current overrides into the repo. The router does not
know which file defines an option, so it does not emit Nix. `fleet pull`
does, because it has evaluated this repo.

```
janus-build fleet pull <host>
```

Over SSH it reads `janus override show --json`. That object is the
overrides still stored on the router, not a history. A value that was set
and later unset is absent.

| Override | Where it is written |
|----------|---------------------|
| Subscription URL | The existing sops key named by that host's `urlSecret`. |
| Wi-Fi passphrase | The existing sops key named by that host's `passphraseSecret`. |
| Static lease | `hosts/<host>/overrides.nix`, which that host's `configuration.nix` already imports. |

The command re-encrypts `secrets.yaml` with the build-host age key. It
does not commit and it does not push. It prints the diff.

A shared sops key is not written from one router when another host that
references it is down or reports a different value. The output names both
values and leaves the file unchanged. Pull each of those hosts, make the
values agree on the routers or edit the secret once, then pull again.

If `hosts/<host>/overrides.nix` is not imported and the router has lease
overrides, the command exits `2` and names the import. Secret keys are
not written in that failed run.

## 6. Check, build, status, backup, update

| Command | Effect |
|---------|--------|
| `janus-build check [<host>]` | Evaluation and assertions only. |
| `janus-build build [<host>]` | Image build. No host means every host. |
| `janus-build status [<host>]` | One SSH to `janus status` per host. No host means every host. A down host is named; the others are still printed. |
| `janus-build backup <host>` | Writes the `janus backup` archive to `./backup/<host>-<utc>.tar` and prints the path. Does not commit it. |
| `janus-build update` | Updates the `janus` flake input only. The user runs `check` and `build` next. |

`status` and `backup` do not grow a second implementation of those
reports. The report is the router command.
