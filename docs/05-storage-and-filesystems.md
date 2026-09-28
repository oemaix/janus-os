# 05 — Storage and File System Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

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
| 3 | `JANUS_NIX` | `/nix` | f2fs | ro | sized to closure + 15 % | Nix store and `/nix/var` (profiles, db) |
| 4 | `JANUS_STATE` | `/var` | f2fs | rw | remaining space (min 512 MiB) | All persistent mutable state |

tmpfs mounts: `/run`, `/tmp`, `/etc` overlay upper, `/home` (no interactive
users besides root; root's home is `/var/lib/janus/root` for SSH `known_hosts`
etc.).

Notes:

* Boards with U-Boot in raw sectors (NanoPi R4S, Le Potato, VisionFive 2)
  additionally need reserved unpartitioned space before partition 1; the
  board profile declares `janus.storage.firmwareOffsetMiB`.
* Partition table is GPT by default; MBR where the Board firmware requires it
  (Raspberry Pi 2/3 firmware reads MBR; RPi 4 firmware handles GPT via
  hybrid MBR — board profile decides).
* Partitions are discovered by label/PARTUUID, never by device name.

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
| `/nix/var` | Read-only. Profiles and DB are frozen at image build. No `nix` daemon is running; the `nix` binary is present only because NixOS activation requires it, and `nix.enable = false` (no daemon, no channels). |
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
│   ├── subscriptions/       <name>.json (normalized), <name>.meta
│   ├── geodata/             geoip.*, geosite.*, versions.json
│   ├── engine/              rendered runtime config, selection state
│   ├── leases/              DHCPv4/v6 leases
│   ├── monitoring/          vnstat db, flow spool
│   ├── hmi/                 display state
│   └── seed.stamp           hash of embedded snapshot last applied
├── log/journal/             optional persistent journal (capped)
└── tmp/                     systemd PrivateTmp for services needing disk
```

Every writer follows *write-temp → fsync → rename*. Directories are owned by
dedicated service users with `StateDirectory=` in their units.

## 6. Seeding and recovery

* The store contains `/nix/store/…-janus-seed/` with the build-time
  snapshot of subscriptions, Geo data and default engine selection.
* At boot, `janus-seed.service` runs before the engine:
  * if `/var/lib/janus` is missing, empty or its `seed.stamp` differs from
    the embedded seed hash **and** the embedded data is newer than what is
    present (or present data fails validation), copy the seed;
  * otherwise keep runtime-refreshed data.
* If `/var` fails to mount even after fsck, the initrd re-formats the state
  partition (policy `janus.storage.state.onCorruption = "reformat" |
  "halt"`, default `reformat`) so the router still comes up (FR-OPS-005).
  The event is logged to the HMI (if any) and to the journal.

## 7. Write-load budget

| Writer | Frequency | Mitigation |
|--------|-----------|------------|
| Journal | continuous | volatile by default; if persistent, `SystemMaxUse=64M`, `Compress=yes` |
| DHCP leases | per lease event | dnsmasq lease file (small) |
| vnstat | every 5 min | small db; `SaveInterval` tuned to 15 min |
| Subscription refresh | per schedule (default 6 h) | atomic, few KiB–MiB |
| Geo data refresh | default weekly | atomic, ~10–30 MiB |
| Flow export spool | continuous if enabled | ring buffer with cap |

The state partition is mounted with `noatime`, `lazytime` and f2fs
`background_gc=on`, `discard`.

## 8. User-configurable layout

`janus.storage` exposes:

* `layout.partitions.<label>.{size, fsType, mountPoint, readOnly, options}`
  with defaults as in §2;
* `state.minimumSize`, `state.onCorruption`;
* `readOnlyFs = "f2fs" | "erofs" | "squashfs"` shortcut for ro partitions;
* `journal.persistent`, `journal.maxUse`.

Assertions: `/`, `/nix` MUST be `readOnly = true`; exactly one partition
MUST mount `/var` rw; no overlay-on-shared-partition option exists.

## 9. Out of scope / future

* A/B image slots for atomic remote upgrades (see *13 — Roadmap*). The
  one-partition-per-FS layout leaves room: slots would duplicate `ROOT`
  and `NIX`.
* Encrypted state partition (LUKS) — possible, low priority on a router
  without a keyboard.
