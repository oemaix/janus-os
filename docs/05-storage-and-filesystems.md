# 05 — Storage and File System Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-22 |

## 1. Objectives

* Minimize the consequences of unexpected power loss (G2, FR-STO-*).
* Keep the running system immutable (C-001, C-003).
* Avoid the OpenWrt pattern of squashfs + writable overlay sharing one
  partition; a corrupted overlay there can render the system unusable, and
  the shared partition couples the image lifetime to the mutable data.
* Give users control over layout while providing safe defaults.

## 2. Default partition layout

| # | Label | Mount | FS | Mode | Default size | Contents |
|---|-------|-------|----|------|--------------|----------|
| 1 | `JANUS_BOOT` | `/boot` | FAT32 (board-dependent) | ro | 256 MiB | Board firmware, U-Boot / RPi firmware, kernel, initrd, DTBs, `extlinux.conf` or `config.txt` |
| 2 | `JANUS_ROOT` | `/` | f2fs | ro | 64 MiB | Directory skeleton, mount points, symlinks into the store |
| 3 | `JANUS_NIX` | `/nix` | f2fs | ro | closure + 15 % + one 4 KiB block per file + 128 MiB, at least 2.5 GiB | Nix store and `/nix/var` (profiles, db) |
| 4 | `JANUS_STATE` | `/var` | f2fs | rw | 512 MiB, grown to at most 4 GiB | All persistent mutable state |

tmpfs mounts: `/run`, `/tmp`, `/etc` overlay upper, `/home` (no interactive
users besides root; root's home is `/var/lib/janus/root` for SSH `known_hosts`
etc.).

Notes:

* `janus.storage.firmwareOffsetMiB` reserves space before partition 1,
  after the leading 1 MiB. Firmware in raw sectors (NanoPi R4S, Le Potato)
  leaves that gap unpartitioned. A bootloader that keeps a boot stage of
  its own uses the gap as an extra unformatted partition.
* The Yanyu image keeps GPT partitions 1–4 and their PARTUUIDs. Partition 5,
  `JANUS_BIOS`, is unformatted (type `EF02`) in the 1 MiB before
  `JANUS_BOOT`. Limine stage 2 is written there. It is not mounted.
* Partition table is GPT by default. The Raspberry Pi 2, Pi 3, Zero 2 W,
  and Pi 4 profiles write a hybrid MBR so the boot ROM or EEPROM finds
  the GPT boot partition.
* Partitions are discovered by label/PARTUUID, never by device name.
* `janus.storage.slots.enable` (default false) inserts `JANUS_ROOT_B` and
  `JANUS_NIX_B` before `JANUS_STATE`. The boot entry selects the slot.
  Each Nix slot is the same size. See *09* §8.4.
* When `JANUS_NIX.size` is null, each Nix partition is the closure plus
  15 %, one 4 KiB node block per file, and 128 MiB, and at least
  `nix.minimumSize` (default 2.5 GiB). `JANUS_NIX.size` may be smaller
  than that floor and is then used as given.
* Without A/B slots, 4 GiB of storage holds the image while each Nix
  partition stays at the 2.5 GiB floor. With no firmware gap that image
  is 3394 MiB, so 4 GiB leaves about 700 MiB. 8 GiB or more is
  recommended. With A/B slots the same floor makes a 6018 MiB image, so
  the storage is at least 8 GiB and 16 GiB or more is recommended. A
  closure that raises the Nix partition above the floor needs a larger
  card by the same amount.
* Those sizes are fixed when the card is flashed. A later Nix image that
  is larger than the flashed Nix partition does not fit. Deploy names
  the Nix partition and stops.
* `janus-grow-state` expands `JANUS_STATE` on boot until it reaches
  `state.maximumSize` (default 4 GiB) or the end of the media. It does
  not shrink. Space past the cap stays free. `JANUS_STATE.size` replaces
  the 512 MiB written into the image and is not the cap (D-0049).
  Every boot moves the backup GPT and then publishes the partition table
  again, and waits until the state partuuid exists, including when the
  partition is already at the cap.

## 3. Why f2fs

* Designed for NAND-based media (SD, eMMC) — the media on all target boards.
* Log-structured writes with checkpointing bound the damage of a torn write to
  the last checkpoint; `fsck.f2fs` recovers automatically.
* Supported by mainline kernels on all target architectures; `mkfs.f2fs` and
  `sload.f2fs` allow populating an image at build time without mounting
  (no root/loop-mount needed in the Nix sandbox).
* Read-only partitions gain little from f2fs specifically, but a single FS
  type keeps the image builder, initrd and tooling small (one set of user
  space tools). Users may switch ro partitions to `erofs` or `squashfs`
  for smaller images (FR-STO-005).

## 4. Read-only root on NixOS

NixOS normally expects a writable `/etc`, `/var`, and `/nix/var`. Janus
configures:

| Concern | Approach |
|---------|----------|
| `/etc` | `system.etc.overlay.enable = true`, `mutable = false`: `/etc` is an overlayfs of the store-generated tree with a tmpfs upper. Files that must persist (`machine-id`, `ssh/ssh_host_*_key`) are bind-mounted from `/var/lib/janus/etc/`. |
| `/nix/var` | Read-only. Profiles and DB are frozen at image build. No `nix` daemon is running. The `nix` binary stays for boot-time activation and for `nix-store --import` during a closure deploy (*09* §8.2). `nix.enable = false` (no daemon, no channels). nixpkgs sources are not on the image, so the board does not evaluate. |
| `/var` | Real f2fs partition. Standard NixOS `systemd-tmpfiles` rules create the tree at boot. |
| `/root` | Symlink to `/var/lib/janus/root`. |
| `/usr/bin/env`, `/bin/sh` | Symlinks baked into the root image. |
| Activation | `system.switch.enable = false`: no `switch-to-configuration` on the device (FR-OPS-001). Boot-time activation only. |
| Bootloader | Generation menu disabled; exactly one generation. |

Assertions fail evaluation if any module tries to write outside `/var`,
`/run`, `/tmp` (detected via `systemd.tmpfiles` and `StateDirectory`
review — best effort; documented residual risk).

## 5. State partition layout (`/var`)

```
/var/
├── lib/janus/
│   ├── etc/                 machine-id, ssh host keys (bind-mounted to /etc)
│   ├── root/                root home (known_hosts)
│   ├── secrets/             user-provisioned secret files (0600)
│   ├── subscriptions/       proxy subscription cache: <name>.json, <name>.meta
│   ├── geodata/             geoip.*, geosite.*, versions.json
│   ├── engine/              rendered runtime config, selection state
│   ├── leases/              DHCPv4/v6 leases
│   ├── monitoring/          vnstat db, flow spool
│   ├── audit/               connection audit JSON Lines, when enabled
│   ├── hmi/                 display state
│   └── seed.stamp           hash of embedded snapshot last applied
├── log/journal/             optional persistent journal (capped)
└── tmp/                     systemd PrivateTmp for services needing disk
```

Every writer follows *write-temp → fsync → rename*. Directories are owned by
dedicated service users with `StateDirectory=` in their units.

## 6. Seeding and recovery

* The store contains `/nix/store/…-janus-seed/` with the build-time
  snapshot of proxy subscriptions, Geo data, the default engine
  selection, and — when the proxy is on — the clash dashboard
  (`engine/ui`, D-0057): sing-box downloads `external_ui` synchronously
  at start, which on a censored first-boot uplink deadlocks the engine
  before the first subscription refresh can populate the proxy group.
  Presetting the dashboard skips that download; deleting
  `/var/lib/janus/engine/ui` re-triggers the `engineSettings`
  `external_ui_download_url` as the manual-update channel.
* At boot, `janus-seed.service` runs before the engine:
  * if `/var/lib/janus` is missing, empty or its `seed.stamp` differs from
    the embedded seed hash **and** the embedded data is newer than what is
    present (or present data fails validation), copy the seed;
  * otherwise keep runtime-refreshed data.
* Every boot runs `fsck.f2fs -a --no-kernel-check` on `JANUS_STATE`.
  That repairs a checkpoint the kernel marked bad. It does not scan the
  volume. A full `fsck.f2fs -f` runs only on the maintenance reboot when
  `janus.system.reboot.fsck` is set, and that boot does not cap the check.
  The on-disk request is removed before that check, so a check that does
  not finish is not repeated (D-0049).
* If `/var` fails to mount even after fsck, the initrd re-formats the state
  partition (policy `janus.storage.state.onCorruption = "reformat" |
  "halt"`, default `reformat`) so the router still comes up (FR-OPS-005).
  A timeout, a slow mount, or a missing block device is not that failure.
  Status 4 or 255 is checked again once the block device is present, and
  the policy runs only when that second result is still 4 or 255. A failed
  `janus-grow-state` does not skip the check. The event is logged to the
  HMI (if any) and to the journal after the boot.

## 7. Write-load budget

| Writer | Frequency | Mitigation |
|--------|-----------|------------|
| Journal | continuous | volatile by default; if persistent, `SystemMaxUse=64M`, `Compress=yes` |
| DHCP leases | per lease event | dnsmasq lease file (small) |
| vnstat | every 5 min | small db; `SaveInterval` tuned to 15 min |
| Proxy subscription refresh | per schedule (default 6 h) | atomic, few KiB–MiB |
| Geo data refresh | default weekly | atomic, ~10–30 MiB |
| Flow export spool | continuous if enabled | ring buffer with cap |

The state partition is mounted with `noatime`, `lazytime` and f2fs
`background_gc=on`, `discard`.

## 8. User-configurable layout

`janus.storage` exposes:

* `layout.partitions.<label>.{size, fsType, mountPoint, readOnly, options}`
  with defaults as in §2;
* `nix.minimumSize` (default `2.5G`), `state.minimumSize`,
  `state.maximumSize` (default `4G`), `state.onCorruption`;
* `readOnlyFs = "f2fs" | "erofs" | "squashfs"`. `f2fs` is the implemented
  value. `erofs` and `squashfs` are reserved names and fail evaluation
  until the image builder can populate them (D-0035);
* `journal.persistent`, `journal.maxUse`.

Assertions: `/`, `/nix` MUST be `readOnly = true`; exactly one partition
MUST mount `/var` rw; no overlay-on-shared-partition option exists.

## 9. Out of scope / future

* Encrypted state partition (LUKS) — possible, low priority on a router
  without a keyboard.
* `readOnlyFs = "erofs"` or `"squashfs"` for the read-only partitions.
  The names are reserved. The image builder populates f2fs and FAT
  (D-0035).
