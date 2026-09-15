# ADR-0003 — One partition per file system, f2fs, read-only root and store

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 03 FR-STO-*, 05 |

## Context

Routers lose power without warning. SD cards and eMMC are the storage media.
OpenWrt's squashfs + writable overlay on one partition couples the image
with mutable data and exposes the overlay to corruption. The note asks for
`/` and `/nix` read-only, one partition per file system, f2fs by default,
and user-adjustable layout.

## Decision

* Default layout: `BOOT` (FAT, ro, firmware-mandated), `ROOT` (f2fs, ro),
  `NIX` (f2fs, ro), `STATE` (f2fs, rw at `/var`). `/run`, `/tmp`, `/etc`
  upper are tmpfs.
* Exactly one persistent read-write partition exists. All mutable data is
  under `/var`.
* f2fs is the default for every partition not constrained by firmware.
  Users may select `erofs`/`squashfs` for read-only partitions.
* Overlay-on-shared-partition layouts are not offered.
* Partitions are addressed by label/PARTUUID.

## Consequences

* Read-only partitions cannot be corrupted by power loss; the state partition
  is small, journaled and fsck'd at boot; worst case it is reformatted and
  reseeded.
* NixOS's writable-`/etc` assumption is handled by `system.etc.overlay`;
  persistent `/etc` files are bind-mounted from `/var/lib/janus/etc`.
* Image builder must populate f2fs without root (`sload.f2fs`).
* Remote closure deployment must remount `/nix` rw temporarily; A/B slots
  would require duplicating `ROOT`/`NIX`.

## Alternatives considered

* **squashfs + f2fs overlay in one partition (OpenWrt)** — rejected for the
  coupling and corruption exposure described above.
* **ext4 everywhere** — mature, but journaling on flash media yields more
  write amplification; f2fs targets this media class.
* **btrfs with snapshots** — heavier, more RAM, recovery tooling is more
  complex; benefits (snapshots) are not needed with an immutable store.
* **Full tmpfs root** — viable, but the note asks for a real read-only root
  partition and tmpfs root costs RAM on 1 GB boards.
