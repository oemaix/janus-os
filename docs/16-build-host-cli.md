# 16 — Build-host command-line specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-28 |

`janus-build` runs on the build host. After the fleet repo exists, every
command runs in that repo. The router command stays `janus` (*14*). The
two names share the project and name different programs. The router image
does not contain `janus-build`. On the board, `janus deploy` and
`janus fleet` exit `2` and name the `janus-build` command.

```
janus-build <command> [<args>]
janus-build --help
janus-build --usage
```

`--help` and `--usage` print the same command list on stdout and exit
`0`. They do not run a command. With no command, or with an unknown
command, the program prints the synopsis on stderr, names `--help`, and
exits `2`.

One fleet repo holds every router. `flake.nix` turns each directory
`hosts/<name>/` into `nixosConfigurations.<name>`. `init` prepares that
repo and adds no router, unless `--host` is given. A later router is
`janus-build host add <name>`. `build`, `check`, `status`, and
`fleet apply` with no host name cover every host. With no hosts they
exit `0` and say so.

## 0. Where the program comes from

The operator does not clone Janus OS, and does not already have
`janus-build` installed. The build host has Nix, with flakes enabled.
That is the prerequisite.

The first command fetches the Janus OS flake into the Nix store and runs
the `janus-build` package from it:

```text
nix run github:oemaix/janus-os#janus-build -- init ./fleet
```

That fetch is not a working copy the operator maintains. `init` then
creates `./fleet` from the template bundled with that same `janus-build`
(*09* §3, ADR-0024):

* Copy that template. `inputs.janus.url` is the train branch recorded in
  the `train` file of this `janus-build` (`main`, or `X.Y`). `flake.lock`
  records the commit, and its `original` names the branch without a
  `rev`. A dirty tree has no commit, so the URL is a `path:` of that
  tree. A clean commit that is not on `github:oemaix/janus-os` still
  gets the branch URL; evaluation fails until that commit is pushed,
  or until `--train` joins a branch.
* `git init` and an initial commit when the directory is not already a
  repository.
* The command refuses when the directory already contains `flake.nix`.

From then on the program is the fleet repo's package, not a second
install:

```text
cd fleet
nix develop
janus-build host add potato
```

`host add` writes the stub and does not commit. Flakes ignore untracked
files, so the next step is a commit, then `janus-build secret keygen potato`.

`nix develop` in the fleet repo puts that repo's `janus-build` on `PATH`.
`nix run .#janus-build -- <args>` is the same program without the shell.
Both follow `inputs.janus`. `janus-build update` moves the lock along the
branch in the URL. `janus-build update --train <train>` rewrites the URL
to `github:oemaix/janus-os/<train>` and then updates the lock. `<train>`
is `main` or `X.Y`. A tag, a patch number, a commit, and a topic branch
such as `1.3-dhcp-lease` are refused. Neither form builds or deploys.
When the pinned Janus does not evaluate, those commands are unavailable
with it: `janus-build` is that pin. `nix flake update janus` in the fleet
repo moves the lock without evaluating it.

Cloning Janus OS and running `nix develop` there is how someone changes
Janus itself. That shell also contains `janus-build`. `init` from it
still writes a separate fleet directory. Operating routers does not
require that clone.

Nix evaluates and builds. `janus-build` does not replace it, and it does
not grow a recipe language, a layer stack, or a task graph. It drives the
life of a router in this repo, and where a step is a router operation it
SSHes to `janus` on that board.

Exit codes match *14*: `0` success, `2` usage or a refused request, `1` a
runtime failure. A host that does not answer is a failure of that host.
Hosts that succeeded are left as they are and named in the output.

SSH destinations are `janus.access.deploy.address`. `mkRouter` sets that
to the `nixosConfigurations` attribute name. The option default is
`janus.system.hostName`. A later `hostName` does not move this value:
`mkRouter` sets both at default priority. `deploy`, `fleet apply`,
`fleet pull`, `status`, and `backup` evaluate it from the fleet repo when
the command runs. The router does not use it. `deploy`, `fleet pull`,
`status`, and `backup` read an uncommitted edit. `fleet apply` still
requires a clean git tree. A new image is not required (Q-0043).

A bare IPv6 literal is passed as `root@[address]`. A value already in
brackets is kept. A value that contains `@` is used as written, so an
IPv6 form there is `root@[address]`.

## 1. Life cycle

| Stage | Command | What it does |
|-------|---------|--------------|
| Create the fleet repo | `nix run github:oemaix/janus-os#janus-build -- init <dir> [--host <name>]` | The only command that runs before the repo exists (§0). No `--host` means the repo has no router. Each `--host` adds that router before the initial commit. Later, `janus-build init <dir>` from a fleet shell creates another fleet directory the same way. |
| Add a router | `janus-build host add <name>` | Creates `hosts/<name>/configuration.nix` and `hosts/<name>/overrides.nix`. Does not edit `flake.nix` and does not commit. |
| Age key | `janus-build secret keygen <host>` | Creates that host's keypair outside the Nix build. Commits nothing by itself: it writes `secrets/keys/<host>.pub` and prints the private key once on stdout. Refuses to replace an existing public key. |
| Set a secret | `janus-build secret set <path>` | Reads plaintext on stdin, writes a sops document for the recipients of that path, and does not keep a plaintext file. A one-line credential is the `value` key. A PPPoE file and a node file are YAML. An empty stdin is refused. The plaintext is not passed as a program argument. |
| Rewrap a shared secret | `janus-build secret rewrap <path> --from <host>` | Asks a router that can decrypt that file, then encrypts to the current recipient set. |
| Check | `janus-build check [<host>]` | Evaluates the named host, or every host. Prints assertion failures. Builds nothing. Refuses a cross image whose build machine is not this one. |
| Build | `janus-build build [<host>]` | Builds `images.<host>` for one host or every host. Prints the store path and links the output directory at `result/<host>`. The image file in that directory is `janus-<hostName>.img`. `janus.system.hostName` defaults to the fleet host name. A later host keeps its own link. On a machine other than x86_64, evaluation is impure so `builtins.currentSystem` is this machine. |
| Install an image | `janus-build deploy <host>` | Closure deploy, or a state-preserving re-flash (*09* §8). |
| Push overrides | `janus-build fleet apply` | Committed hot-override projection, over SSH (§4). |
| Pull overrides | `janus-build fleet pull [<host>]` | Current overrides from one router, or every reachable router, into this repo (§5). |
| Look | `janus-build status [<host>]` | SSH `janus status` on one host or every host. |
| Save a router | `janus-build backup <host>` | SSH `janus backup` and write the archive on the build host. |
| New Janus pin | `janus-build update [--train <train>]` | `nix flake update janus`. `--train` rewrites `inputs.janus.url` to that train first (§0). Does not build or deploy. |

A later local wizard is a front end for `init` and `host add`. It is
not a hosted builder (*00* §4, *13* Future). Until it exists, those two
commands are the creation steps.

### Adding a host

```text
janus-build host add <name>
```

`<name>` is the `nixosConfigurations` attribute, the default SSH
destination, and the directory name. It starts with a letter and then
contains only letters, digits, and hyphens. The command refuses when
`hosts/<name>` already exists.

It writes:

* `hosts/<name>/configuration.nix` — this router only. `janus.system.hostName`
  is `<name>`. Board, ports, WAN, LAN, and an SSH key are still unset.
  The comment points at `docs/examples/configuration.example.nix`.
  `check` fails until those values are filled in.
* `hosts/<name>/overrides.nix` — an empty module. `fleet pull` writes
  static leases here.

`flake.nix` already imports `common/default.nix` and those two files for
every directory under `hosts/`. Shared options, including a subscription
used by two routers, go in `common/default.nix`. The command does not
commit. Commit, then `secret keygen <name>`.

`init <dir> --host <name>` is `host add` run before the initial commit,
so that commit already contains the host. `--host` may be repeated.

## 2. Age keys and secret files

Each router has its own age key (ADR-0022). The build host stores the
public key in the repo and does not keep the private key. Encryption uses
the public key. Decryption runs on the router.

Secret files, one credential each:

```text
secrets/keys/<host>.pub
secrets/wifi/<host>/<ap>.yaml
secrets/pppoe/<host>/<wan>.yaml
secrets/tailscale/<host>.yaml
secrets/wireguard/<host>/<name>.yaml
secrets/subscription/<vendor>.yaml   # proxy subscription URL
secrets/nodes/<name>.yaml            # manual proxy-node credential
secrets/web/<host>.yaml              # maintenance page passphrase, one line
```

A host path is encrypted to `secrets/keys/<host>.pub`. A proxy
subscription file or a manual proxy-node file is encrypted to every host
whose configuration names that file.
The tree must be a git repository. These commands do not commit.

| Command | Effect |
|---------|--------|
| `janus-build secret keygen <host>` | Create that host's keypair (§1). Print the private key once. Do not write it into the repo or into `~/.config/janus/`. |
| `janus-build secret set <path>` | Encrypt stdin to the recipients of `<path>` and write a sops document. A one-line credential is the `value` key. A PPPoE file and a node file are YAML. An empty stdin is refused. The plaintext is not a program argument. `<path>` is one of the paths above. |
| `janus-build secret rewrap <path> --from <host>` | SSH to `<host>`, which decrypts `<path>`. Encrypt to the recipient set implied by the current configuration. Warn that the session carried plaintext. |
| `janus-build deploy --age-key <host>` | Open one SSH session with stdin closed. When it answers, read that host's private key and send it on a second session. Do not store the key, and do not pass it as an argument. On a terminal, print `Paste the age private key, then press Enter and Ctrl-D.` on stderr only after the first session answers. A failed first session prints nothing and does not read stdin. A pipe stays quiet. Input with no `AGE-SECRET-KEY-1` line is refused. SSH does not allocate a terminal, so the router command stays quiet. |

## 3. `janus-build deploy`

| Command | Effect |
|---------|--------|
| `janus-build deploy <host>` | Remote closure deploy (*09* §8.2). When `janus.storage.slots.enable` is true, write the inactive ROOT and NIX slot and then toggle the boot entry (*09* §8.4). |
| `janus-build deploy --preserve-state <host>` | Copy the state set in *09* §8.1 to the build host. Does not flash. The operator flashes, then sends the archive to `janus restore`. |
| `janus-build deploy --confirm <host>` | Mark the booted generation good after a closure deploy. |
| `janus-build deploy --age-key <host>` | Install that host's age private key from stdin (§2). Probe SSH with stdin closed. On a terminal, prompt on stderr after the probe. Input with no `AGE-SECRET-KEY-1` line is refused. |

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
  on that host, the ciphertext file its `urlSecret` names
* `network.wifi.<name>.passphrase` for an AP that already exists, the
  ciphertext file its `passphraseSecret` names
* `network.lans.<name>.dhcp.staticLeases.<host>` written in
  `hosts/<name>/overrides.nix`

Each reachable router receives its own projection. Static leases are
passed to `janus override set` as plaintext. Secret files are sent as
ciphertext. The file is a sops document, resolved from
`sops.secrets.<name>.sopsFile`, not from the spelling of the secret
name. The router decrypts it with `sops decrypt` and
`SOPS_AGE_KEY_FILE` pointing at its age key, then applies the override.
`age -d` cannot read that document. The build host does not decrypt. A shared subscription file is
the same ciphertext on every host that references it; each of those hosts
can decrypt it. A changed URL is followed by `janus proxy refresh` for
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

Brings current overrides into the repo. The router does not know which
file defines an option, so it does not emit Nix. `fleet pull` does,
because it has evaluated this repo. There is no `janus override export`.

```
janus-build fleet pull [<host>] [--with-secrets]
```

No host means every reachable `nixosConfigurations` entry. An unreachable
host is named and skipped. Over SSH the command reads `janus override
show --json`. That object is the overrides still stored on the router,
not a history. A value that was set and later unset is absent. Secret
values are redacted unless `--with-secrets` is set, in which case the
remote command is `janus override show --secrets --json`.

| Override | Default | `--with-secrets` |
|----------|---------|------------------|
| Subscription URL | Named as changed. Not fetched. | Router decrypts. Build host encrypts to the recipients of the existing `urlSecret` file and writes that file. |
| Wi-Fi passphrase | Named as changed. Not fetched. | Same, for the existing `passphraseSecret` file. |
| Static lease | `hosts/<host>/overrides.nix`, which that host's `configuration.nix` already imports. | Same file. Leases are not secrets. |

The command does not commit and it does not push. It prints the diff.
`--with-secrets` prints a warning that the SSH session carried plaintext
credentials and that no plaintext file was kept. The user reviews the
ciphertext diff and deletes nothing from the repo beyond what they do
not want to commit.

A shared secret file is not written from one router when another
reachable host that references it reports a different value. The output
names both hosts and leaves the file unchanged. Make the values agree on
the routers, or replace the file once with `secret set`, then pull again.
An unreachable host does not block a per-host file. It does block a
shared file that host also references.

If `hosts/<host>/overrides.nix` is not imported and the router has lease
overrides, the command exits `2` and names the import. Secret files are
not written in that failed run.

## 6. Check, build, status, backup, update

| Command | Effect |
|---------|--------|
| `janus-build check [<host>]` | Evaluation and assertions only. Refuses a cross image whose build machine is not this one. |
| `janus-build build [<host>]` | Image build. No host means every host. Prints the store path and links the output directory at `result/<host>`. The image file in that directory is `janus-<hostName>.img`. `janus.system.hostName` defaults to the fleet host name. A non-x86_64 machine evaluates impurely so `builtins.currentSystem` is that machine. |
| `janus-build status [<host>]` | One SSH to `janus status` per host. No host means every host. A down host is named; the others are still printed. |
| `janus-build backup <host>` | Writes the `janus backup` archive to `./backup/<host>-<utc>.tar` and prints the path. Does not commit it. |
| `janus-build update [--train <train>]` | Updates the `janus` flake input only. Without `--train`, the URL stays and the lock follows that branch. `--train` changes the train (§0). The user runs `check` and `build` next. |

`status` and `backup` do not grow a second implementation of those
reports. The report is the router command.
