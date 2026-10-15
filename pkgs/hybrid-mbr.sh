#!/usr/bin/env bash
# Hybrid MBR for the Raspberry Pi 2 boot ROM. docs/05 §2, docs/10 §3.
# Partition 1 of the MBR is the FAT boot filesystem, type 0x0C.
# Partition 2 is type 0xEE and covers only the gap in front of that FAT,
# so the GPT header at LBA 1 stays valid and Linux still reads the GPT.
# boot_start and bootMiB are MiB offsets from the image builder. disk.img is the cwd file.
set -euo pipefail

: "${boot_start:?}"
: "${bootMiB:?}"

le32() {
  local n=$1
  printf '%b' "\\$(printf '%03o' $((n & 255)))\\$(printf '%03o' $(((n >> 8) & 255)))\\$(printf '%03o' $(((n >> 16) & 255)))\\$(printf '%03o' $(((n >> 24) & 255)))"
}

mbr_entry() {
  local flag=$1 typ=$2 start=$3 count=$4
  printf '%b' "\\$(printf '%03o' "$flag")\\377\\377\\377\\$(printf '%03o' "$typ")\\377\\377\\377"
  le32 "$start"
  le32 "$count"
}

boot_lba=$((boot_start * 2048))
boot_sectors=$((bootMiB * 2048))
if ((boot_lba < 2)); then
  echo "janus: hybrid MBR needs the boot partition after the GPT header" >&2
  exit 1
fi

{
  mbr_entry 128 12 "$boot_lba" "$boot_sectors"
  mbr_entry 0 238 1 $((boot_lba - 1))
  dd if=/dev/zero bs=32 count=1 status=none
} | dd of=disk.img bs=1 seek=446 conv=notrunc status=none
