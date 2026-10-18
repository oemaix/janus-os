# 09 — Build and Deployment

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-18 |

## 1. Principles

1. The Board never builds and never evaluates Nix. All evaluation,
   compilation, and package fetching happens on the build host
   (C-001, FR-BLD-003/004/007, ADR-0017). Hot overrides are data, not a
   rebuild.
2. One command produces one flashable image (FR-BLD-001).
3. Builds are reproducible except for explicitly impure inputs
   (subscription snapshots), which can be pinned (FR-BLD-006).
4. The build host may sit in an unrestricted network *or* behind its own
   tunnel; Janus does not care how the build host reaches the Internet.

## 2. Flake layout (project)

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-<release>";
  outputs = { self, nixpkgs, ... }: {
    nixosModules.janus     = ./modules/janus;          # the option layer
    nixosModules.boards    = ./modules/boards;         # all board profiles
    lib.mkRouter           = import ./lib/mk-router.nix;
    templates.default      = { path = ./templates/default; description = "Janus router"; };
    packages.<system>      = { janus-cli; janus-tools; docs-options; image-builder; };
    checks.<system>        = { eval-*; render-golden-*; vm-x86_64-test; build-<board>; };
    overlays.default       = …;                        # pinned sing-box/xray if nixpkgs lags
    devShells.<system>.default = …;                   # `nix develop`; see the root README
  };
}
```

## 3. Flake layout (user template)

`nixosConfigurations` lives in this repo's `flake.nix`. It is not a
router file. `janus-build init` writes the tree below and adds no host
(*16* §0). `janus-build host add <name>` creates one directory under
`hosts/`.

```text
flake.nix                      # one nixosConfigurations.<name> per hosts/<name>/
flake.lock
common/default.nix             # imported for every host; a shared proxy subscription goes here. A host sets enable = false to drop one (D-0044)
hosts/<name>/configuration.nix # this router only
hosts/<name>/overrides.nix     # fleet pull writes static leases here
secrets/                       # one ciphertext file per credential (ADR-0022)
```

`flake.nix` reads the directories under `hosts/` and builds each one as:

```nix
janus.lib.mkRouter {
  modules = [
    ./common/default.nix
    ./hosts/<name>/configuration.nix
    ./hosts/<name>/overrides.nix
  ];
}
```

It also re-exports `packages.<system>.janus-build` and a development
shell that contains only that program. A hand-written flake with one
`configuration.nix` and one attribute remains valid (FR-CFG-006). The
template does not ship that shape.

`hosts/<name>/overrides.nix` is the only Nix file `janus-build fleet pull`
writes. It holds static leases copied back from that router. Proxy
subscription URLs and Wi-Fi passphrases stay in per-credential files under `secrets/`
(ADR-0022). The file name is `configuration.nix`, including under
`hosts/<name>/`. `janus-configuration.nix` and
`janus_configuration.nix` are not used.
Snake case is not the NixOS file convention, and a prefix does not help
the flake find the module.

`mkRouter` reads `janus.hardware.board` from the modules to pick the system
(`aarch64-linux`, `x86_64-linux`, `armv7l-linux`, `riscv64-linux`) and the
board profile. Splitting one router's `configuration.nix` into further
files is supported (FR-CFG-006, FR-CFG-011). Those files stay under that
host's directory, or under `common/` when every host imports them.

This template is a **separate git repository** from Janus OS. The user
clones nothing of the OS for day-to-day use. The first command is
`nix run github:oemaix/janus-os#janus-build -- init <dir>` (*16* §0).
`inputs.janus.url` is the train branch of the Janus that provided that
`janus-build` (`main`, or `X.Y`). `flake.lock` records the commit.
`janus-build update` follows the branch. Another train is
`janus-build update --train` (ADR-0024, §10). They do not fork Janus OS
per router, and they do not keep one branch per device inside the OS repo.
A second router is `janus-build host add <name>` in this same repo.

A **local** git repository is mandatory (FR-CFG-010). Flakes skip
uncommitted files, so the sequence is edit, commit, `nix build`. A
**remote** (GitHub or otherwise) is how that repo survives a dead laptop.
It is recommended and not required. Someone who cannot operate a remote
host can still build. The user manual, not the router, is what teaches
`git init`.

The board never holds a credential for that remote, never pushes, and
never pulls the repo to apply it (FR-OPS-010). `janus-build fleet pull`
on the build host reads the current overrides over SSH. The operator
reviews the diff and commits there.

On-site `nixos-rebuild` was considered and rejected (ADR-0017). It would
not rewrite the Nix store; it would add store paths. Doing that on the
board would still require the Nix evaluator, a writable store, and the
nixpkgs source (hundreds of megabytes) for evaluation, and a dirty tree
would silently not apply. A Raspberry Pi Zero 2 W does not have the RAM
for a NixOS evaluation. Parameter changes that humans actually make on the
router go through hot overrides instead.

## 4. Target architectures and how they are built

| Board | System | Binary cache | Default build strategy |
|-------|--------|--------------|------------------------|
| RPi 3/4, RPi Zero 2 W, NanoPi R4S, Le Potato | `aarch64-linux` | cache.nixos.org | `boot.binfmt.emulatedSystems = ["aarch64-linux"]` on x86_64 host (transparent, slow for local builds but most packages come from cache) **or** native aarch64 builder **or** cross (`pkgsCross.aarch64-multiplatform`) |
| RPi 2 (BCM2836) | `armv7l-linux` | none (community only) | cross-compilation required; expect long builds; Tier 3 |
| VisionFive 2 | `riscv64-linux` | none | cross-compilation; Tier 3 |
| Yanyu STX-R19F and the test target | `x86_64-linux` | yes | native on the build host. The STX-R19F image boots with Limine on legacy BIOS, not UEFI. |

`mkRouter` selects `crossSystem` when `janus.build.strategy = "cross"`,
defaulting to `"emulated"` for aarch64 and `"cross"` for the others. Users
with an aarch64 machine set `"native"`.

`lib.mkRouter` takes `buildSystem`, the machine that runs the compiler.
Pure flake evaluation has no `builtins.currentSystem`, so the default is
`x86_64-linux`. `janus-build` on any other machine evaluates the fleet
flake with `--impure`, which makes `builtins.currentSystem` that machine,
and refuses the image when the cross build is still aimed at a different
machine.

## 5. Build-time fetches

| Data | Mechanism | Purity |
|------|-----------|--------|
| nixpkgs, Janus, engines | flake inputs, fixed hashes | pure |
| Geo data | `fetchurl` with version pin + hash from Janus release metadata; `janus.proxy.geodata.pin = "latest"` switches to impure | pure by default |
| Subscription snapshot | impure derivation (`__impure = true` or `--impure` with `builtins.fetchurl`) unless `snapshot.hash` is set (then fixed-output) | impure by default |

DoH and DoT hostnames are not resolved at build time. `janus.dns.bootstrap`
is a list of IP literals. Unset, it follows the region preset (D-0040).
There is no refresh timer for those addresses.

The build fails with a clear message if a subscription cannot be fetched
and no previous snapshot is cached (`janus.proxy.subscriptions.<n>.
allowMissingAtBuild = false` by default; when `true`, the image boots with
an empty subscription and refreshes at runtime).

## 6. Image assembly

The image builder is a Nix derivation (no root, no loop mounts) that:

1. Computes the closure of `config.system.build.toplevel`.
2. Creates file system images:
   * `nix.img` — `mkfs.f2fs` sized to closure + slack, populated with
     `sload.f2fs` from the closure and `/nix/var` (db, profiles);
   * `root.img` — `mkfs.f2fs`, populated with the skeleton (`/bin/sh`,
     `/usr/bin/env`, mount points, `/etc` lower dir is in the store);
   * `boot.img` — `mkfs.vfat` + `mcopy` of kernel, initrd, DTBs,
     board firmware and boot script (`extlinux.conf`, `config.txt`,
     `cmdline.txt`, `limine.conf`, U-Boot binaries as the profile dictates);
   * `state.img` — empty `mkfs.f2fs` of `state.minimumSize`; expanded to
     the full media on first boot by `janus-grow-state.service`.
3. Writes GPT/MBR with labels and PARTUUIDs, installs raw U-Boot/SPL at the
   profile offsets, concatenates partitions. On the Yanyu image, `limine
   bios-install` writes stage 1 into the image file and stage 2 into
   `JANUS_BIOS`.
4. Emits `janus-<host>.img` plus `.img.zst`, `SHA256SUMS`,
   `build.json` (provenance, including `configRevision`).

`systemd-repart` is not the builder (ADR-0010). Revisit it when it can
create and populate f2fs.

## 7. Preventing on-device builds (FR-BLD-004)

Multiple independent guards:

* `system.switch.enable = false` — no `switch-to-configuration`.
* `nix.enable = false` — no daemon, no channels. The `nix` binary stays
  for boot-time activation and for `nix-store --import` in §8.2. nixpkgs
  sources are not on the image, and `/nix` is read-only except during
  that deploy, so the board does not evaluate.
* `/nix` mounted read-only.
* No compilers/`stdenv` in the closure: a check derivation asserts that
  `gcc`, `binutils`, `glibc.dev`, `cmake`, `meson` etc. are not in the
  runtime closure (`checks.no-build-tools`).
* `janus-build deploy` (build-host tool) uses `--max-jobs 0` and `--substituters
  ""` when pushing a closure, so any missing path is an error rather than a
  build/download attempt on the Board.

## 8. Deployment methods

### 8.1 Full image re-flash (1.0, always available)

Flash `janus-<host>.img` to the SD card, eMMC, or NVMe. On the VisionFive 2
that disk is not the bootloader. The boot ROM loads U-Boot 2026.04 from
QSPI (D-0047). The operator updates the QSPI before the first boot, using
the U-Boot board document cited there. The image does not write the flash.
`janus-build deploy --preserve-state <host>` does not flash. It copies
this set to the build host:

* `/var/lib/janus/etc`
* `/var/lib/janus/secrets`
* `/var/lib/janus/subscriptions`
* `/var/lib/janus/geodata`
* `/var/lib/janus/overrides.json`
* `/var/lib/janus/engine/selection.json`

The operator flashes the image. After the board boots, `janus restore`
of that archive puts the set back (*14* §6). A flash without that copy
starts from an empty state partition.

### 8.2 Remote closure deployment (P2)

`janus-build deploy <host>` (a build-host program):

1. Build closure locally; verify no derivation needs building on target.
2. `ssh` to router; remount `/nix` and `/boot` read-write for the session.
3. `nix copy --to ssh://router` the closure (`nix-store --import` fallback
   as there is no daemon).
4. Update boot entry and `/nix/var/nix/profiles/system`; remount read-only;
   `reboot`.
5. Rollback: previous generation is kept in the boot menu for one boot
   (`janus-build deploy --confirm` after successful boot marks it good; otherwise
   the boot script falls back).

Requires spare space on `JANUS_NIX` (`janus.storage.layout.partitions.
JANUS_NIX.slack = "40%"`).

### 8.3 Hot overrides, without a new image (P2)

`janus-build fleet apply` and `janus-build fleet pull` run on the build host. The
contract is *16*. `fleet apply` pushes the committed projection. Secret
files go as ciphertext; the router decrypts. Static leases are plaintext.
A commit that also changes anything else is refused until the user passes
`--only-overrides`, which still does not deploy those other changes.
`fleet pull` with no host reads every reachable router. It writes leases
into `hosts/<host>/overrides.nix` and names secret overrides without
fetching them. `--with-secrets` writes the secret files after the router
decrypts.

`build.json` includes `configRevision`, the git revision of the private
repo that built the image. `fleet apply` uses it to see what `HEAD` would
change beyond the projection.

### 8.4 A/B slots

`janus.storage.slots.enable` (default false) duplicates `ROOT` and `NIX`.
`JANUS_STATE` stays one partition and stays last, so it can still grow.
The first flash writes the same system into both slots and boots slot A.
Partition 5 stays the Limine BIOS gap. Slot B is GPT partitions 6 and 7.

`janus-build deploy` on a host with the option set writes the new root
and store images onto the inactive slot, updates that slot's kernel and
command line, and then changes the boot entry. On a Raspberry Pi image
the same step rewrites `kernel=` and `initramfs` in `config.txt`, so
slot B loads `initrd-b`. A power loss before that
change leaves the active slot bootable. The state partition is shared.
`janus-build deploy --confirm` marks the boot good. Without it, the next
boot changes the boot entry back. The other slot's files stay where they
are.

The slot partitions are the size fixed by the flashed image. If the new
images do not fit, deploy stops and the operator flashes a larger image.
A disk that was flashed without the option has no inactive slot; deploy
says so and does not resize the table.

## 9. Testing strategy

| Level | What | Where |
|-------|------|-------|
| Evaluation | assertions fire for known-bad configs; option docs render; the rendered Shadowsocks outbound completes a hop to `127.0.0.1` | `checks.eval-*` |
| Rendering | golden files for engine configs, nftables rulesets, networkd units from fixture configurations | `checks.render-golden-*` |
| VM | `x86_64-test` boots with two virtual NICs. `vm-x86_64-test` checks the mount model. `vm-x86_64-net` checks DHCP, NAT, a static DNS answer, and the WAN/LAN firewall | `checks.vm-*` |
| Board build | each board's image builds in CI (aarch64 daily, others weekly) | `checks.build-<board>` |
| Hardware | Tier-1 boards boot-and-route on a lab bench (manual/semi-automated) | release checklist |
| Chaos | power-cut loop on Tier-1 hardware (NFR-REL-001) | release checklist |

## 10. Release

Versions and trains are ADR-0024. A train is the branch `janus-build
update` follows. A version is a tag on that branch.

| Name | Role |
|------|------|
| `main` | Development train. The file `train` in this repository contains `main`. |
| `X.Y` | Release train, major.minor, no leading zeros. End users follow this branch. The file `train` on that branch contains `X.Y`. |
| `vX.Y.Z` | Immutable tag. The tip of branch `X.Y` is always one of these tags. |
| `X.Y-<topic>` | Short-lived branch for a bugfix or a backport, cut from the tip of `X.Y`. Not a train. |

There is no `X.Y-dev` branch. Maintenance of train `1.3` is
`1.3-<topic>`, for example `1.3-dhcp-lease`. The `train` file on that
branch stays `1.3`. The branch merges into `1.3` as the commit tagged
`v1.3.N`. `janus-build update` on a fleet that follows `1.3` then moves
to that tag. A standing `1.3-dev` would be a second line, and an update
would deliver commits that are not tagged.

* **Patch** (`v1.3.4`): same train, same Nixpkgs stable branch. The pinned
  Nixpkgs commit may advance. Fleets on `1.3` take it with
  `janus-build update`.
* **Minor** (`v1.4.0`): new branch `1.4`. New options, and it may move to
  the next Nixpkgs stable. An existing fleet changes with
  `janus-build update --train 1.4`.
* **Major** (`v2.0.0`): new branch `2.0`. Removed options, or an image
  layout that is not a closure deploy.

Cutting train `1.3` is a commit on branch `1.3` that sets `train` to
`1.3` and is tagged `v1.3.0`. `main` keeps `main`. Nix does not expose
the fetched ref to the flake, so `init` reads this file rather than the
branch name.

`inputs.janus.url` is `github:oemaix/janus-os/<train>`. `flake.lock`
holds the commit. The lock's `original` names the branch and has no
`rev`, which is what lets `nix flake update janus` move. A dirty tree
has no revision; `init` writes a `path:` URL, and `--train` joins a
branch later.

Each release pins one nixpkgs release-branch commit and one version each
of sing-box, Xray, and Geo data. Release artifacts are images for Tier-1
boards with the template configuration, `SHA256SUMS`, the options
reference HTML, and a changelog. Users are expected to rebuild rather
than download images, but stock images make first contact easy. The
image records a git revision in `build.json`. The version to compare
with the changelog is the tag on that revision.
