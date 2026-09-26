# 09 — Build and Deployment

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-26 |

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
  };
}
```

## 3. Flake layout (user template)

```nix
{
  inputs.janus.url = "github:<org>/janus-os/<release>";
  outputs = { janus, ... }: {
    nixosConfigurations.home-router = janus.lib.mkRouter {
      modules = [ ./configuration.nix ];        # may import ./network.nix, ./proxy.nix …
    };
    images.home-router = janus.lib.mkImage self.nixosConfigurations.home-router;
  };
}
```

Several routers that share a subscription live in that same repo
(ADR-0021):

```nix
nixosConfigurations = {
  potato = janus.lib.mkRouter { modules = [ ./common/proxy.nix ./hosts/potato/configuration.nix ]; };
  zero   = janus.lib.mkRouter { modules = [ ./common/proxy.nix ./hosts/zero/configuration.nix ]; };
};
```

The file name is `configuration.nix`, including under `hosts/<name>/`.
`janus-configuration.nix` and `janus_configuration.nix` are not used.
Snake case is not the NixOS file convention, and a prefix does not help
the flake find the module.

`mkRouter` reads `janus.hardware.board` from the modules to pick the system
(`aarch64-linux`, `x86_64-linux`, `armv7l-linux`, `riscv64-linux`) and the
board profile. Splitting `configuration.nix` into several files is
supported (FR-CFG-006, FR-CFG-011). The template ships a single file for
one router.

This template is a **separate git repository** from Janus OS. The user
clones nothing of the OS for day-to-day use; `nix flake init -t` creates
their private repo, and `inputs.janus.url` pins a release. They do not
fork Janus OS per router, and they do not keep one branch per device
inside the OS repo.

A **local** git repository is mandatory (FR-CFG-010). Flakes skip
uncommitted files, so the sequence is edit, commit, `nix build`. A
**remote** (GitHub or otherwise) is how that repo survives a dead laptop.
It is recommended and not required. Someone who cannot operate a remote
host can still build. The user manual, not the router, is what teaches
`git init`.

The board never holds a credential for that remote, never pushes, and
never pulls the repo to apply it (FR-OPS-010). Hot overrides are exported
over SSH to the build host, then committed there.

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
| Yanyu STX-R19F and the test target | `x86_64-linux` | yes | native on the build host. The STX-R19F image boots with legacy GRUB, not UEFI. |

`mkRouter` selects `crossSystem` when `janus.build.strategy = "cross"`,
defaulting to `"emulated"` for aarch64 and `"cross"` for the others. Users
with an aarch64 machine set `"native"`.

## 5. Build-time fetches

| Data | Mechanism | Purity |
|------|-----------|--------|
| nixpkgs, Janus, engines | flake inputs, fixed hashes | pure |
| Geo data | `fetchurl` with version pin + hash from Janus release metadata; `janus.proxy.geodata.pin = "latest"` switches to impure | pure by default |
| Subscription snapshot | impure derivation (`__impure = true` or `--impure` with `builtins.fetchurl`) unless `snapshot.hash` is set (then fixed-output) | impure by default |
| DoH/DoT bootstrap IPs | resolved at eval time on build host (impure) or set explicitly | impure by default |

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
     `cmdline.txt`, U-Boot binaries as the profile dictates);
   * `state.img` — empty `mkfs.f2fs` of `state.minimumSize`; expanded to
     the full media on first boot by `janus-grow-state.service`.
3. Writes GPT/MBR with labels and PARTUUIDs, installs raw U-Boot/SPL at the
   profile offsets, concatenates partitions.
4. Emits `janus-<host>.img` plus `.img.zst`, `SHA256SUMS`,
   `build.json` (provenance).

Alternative considered: `systemd-repart` / `image.repart`. It is the
direction NixOS is moving, but f2fs population support is not established;
revisit (ADR-0010 placeholder).

## 7. Preventing on-device builds (FR-BLD-004)

Multiple independent guards:

* `system.switch.enable = false` — no `switch-to-configuration`.
* `nix.enable = false` — no daemon, no channels; the `nix` binary is
  present only for activation script needs.
* `/nix` mounted read-only.
* No compilers/`stdenv` in the closure: a check derivation asserts that
  `gcc`, `binutils`, `glibc.dev`, `cmake`, `meson` etc. are not in the
  runtime closure (`checks.no-build-tools`).
* `janus deploy` (build-host tool) uses `--max-jobs 0` and `--substituters
  ""` when pushing a closure, so any missing path is an error rather than a
  build/download attempt on the Board.

## 8. Deployment methods

### 8.1 Full image re-flash (1.0, always available)

Flash `janus-<host>.img` to SD/eMMC. State partition content on the media
is lost unless the operator uses `janus deploy --preserve-state` which
copies `/var/lib/janus/{etc,secrets,subscriptions,geodata}` back over SSH
before flashing. Simple and always correct.

### 8.2 Remote closure deployment (P2)

`janus deploy <host>` (a build-host program):

1. Build closure locally; verify no derivation needs building on target.
2. `ssh` to router; remount `/nix` and `/boot` read-write for the session.
3. `nix copy --to ssh://router` the closure (`nix-store --import` fallback
   as there is no daemon).
4. Update boot entry and `/nix/var/nix/profiles/system`; remount read-only;
   `reboot`.
5. Rollback: previous generation is kept in the boot menu for one boot
   (`janus deploy --confirm` after successful boot marks it good; otherwise
   the boot script falls back).

Requires spare space on `JANUS_NIX` (`janus.storage.layout.partitions.
JANUS_NIX.slack = "40%"`).

### 8.3 A/B slots (P3)

Duplicate `ROOT`/`NIX` partitions with a boot-side toggle; enables atomic,
power-safe upgrades over the tunnel. See *13 — Roadmap*.

## 9. Testing strategy

| Level | What | Where |
|-------|------|-------|
| Evaluation | assertions fire for known-bad configs; option docs render | `checks.eval-*` |
| Rendering | golden files for engine configs, nftables rulesets, networkd units from fixture configurations | `checks.render-golden-*` |
| VM | `x86_64-test` board boots in NixOS VM test with two virtual NICs; DHCP, NAT, DNS policy and firewall verified; engine started against a mock server | `checks.vm-*` |
| Board build | each board's image builds in CI (aarch64 daily, others weekly) | `checks.build-<board>` |
| Hardware | Tier-1 boards boot-and-route on a lab bench (manual/semi-automated) | release checklist |
| Chaos | power-cut loop on Tier-1 hardware (NFR-REL-001) | release checklist |

## 10. Release

* Semantic versioning; each release pins one nixpkgs release branch commit
  and one version each of sing-box, Xray, Geo data.
* Release artifacts: images for Tier-1 boards with the template
  configuration, `SHA256SUMS`, options reference HTML, changelog.
* Users are expected to *rebuild* rather than download images, but stock
  images make first contact easy.
