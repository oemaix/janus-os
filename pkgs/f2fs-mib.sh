# SPDX-License-Identifier: Apache-2.0
# Size of an f2fs partition in MiB. image.nix and slot-images.nix both
# call this, and eval-nix-size runs it without building an image.
# f2fs_partition_mib SRC MIN_MIB SLACK_PERCENT EXACT
# EXACT empty: bytes plus slack, one 4 KiB node block per inode, and
# 128 MiB, rounded up to a MiB, then raised to MIN_MIB.
# EXACT set: that size. MIN_MIB is not applied.
f2fs_partition_mib() {
  local src="$1" min_mib="$2" slack="$3" exact="$4"
  local bytes mib inodes
  if [ -n "$exact" ]; then
    mib=$exact
  else
    bytes=$(du -s -B1 "$src" | awk '{ print $1 }')
    inodes=$(find "$src" | wc -l)
    # f2fs spends a node block on every inode. A Nix store is mostly small files.
    bytes=$((bytes * (100 + slack) / 100 + inodes * 4096 + 128 * 1024 * 1024))
    mib=$(((bytes + 1048575) / 1048576))
    if ((mib < min_mib)); then mib=$min_mib; fi
  fi
  printf '%s\n' "$mib"
}
