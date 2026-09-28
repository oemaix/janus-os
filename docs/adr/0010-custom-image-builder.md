# ADR-0010 — Custom image builder until repart can populate f2fs

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-28 |
| Affects | *09* §6, ADR-0003 |

## Context

The image is GPT or MBR, a FAT boot partition, read-only f2fs for `/` and
`/nix`, and a read-write f2fs state partition. `systemd-repart` is the
direction NixOS images are moving. Its `Format=` list covers ext4, btrfs,
xfs, vfat, erofs, squashfs, and swap. Creating and populating f2fs is
still an open request (systemd issue 32124).

## Decision

A custom builder assembles the image, as specified in *09* §6. Revisit
repart when it can create and populate f2fs partitions.

## Consequences

* The builder owns partition layout, `mkfs.f2fs`, and `mkfs.vfat`.
* Switching later is a change of this ADR's status, not a silent swap in
  the code.

## Alternatives considered

* **systemd-repart now** — cannot populate the f2fs partitions this layout
  requires.
