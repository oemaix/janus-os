#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Le Potato partition layout. pkgs/image.nix and tests/eval.nix both run this.
# docs/10 §3.6, D-0055.
set -euo pipefail

need() {
  if [ -z "${!1:-}" ]; then
    echo "janus: amlogic-disk.sh needs $1" >&2
    exit 1
  fi
}

write_layout_env() {
  cat > amlogic-layout.env << EOF
boot_lba=$boot_lba
boot_sectors=$boot_sectors
root_lba=$root_lba
root_sectors=$root_sectors
nix_lba=$nix_lba
nix_sectors=$nix_sectors
state_lba=$state_lba
state_sectors=$state_sectors
EOF
  if [ "$slots" = 1 ]; then
    cat >> amlogic-layout.env << EOF
root_b_lba=$root_b_lba
nix_b_lba=$nix_b_lba
EOF
  fi
}

layout() {
  need boot_start
  need bootMiB
  need root_mib
  need nix_mib
  need stateMiB
  need slots
  need bootLabel
  need rootLabel
  need nixLabel
  need stateLabel

  # One sector before each logical filesystem is its EBR. The FIP stays
  # at LBA 1 and the boot partition stays on a 1 MiB boundary.
  boot_lba=$((boot_start * 2048))
  boot_sectors=$((bootMiB * 2048))
  root_sectors=$((root_mib * 2048))
  nix_sectors=$((nix_mib * 2048))
  state_sectors=$((stateMiB * 2048))
  root_lba=$((boot_lba + boot_sectors + 1))
  nix_lba=$((root_lba + root_sectors + 1))
  if [ "$slots" = 1 ]; then
    root_b_lba=$((nix_lba + nix_sectors + 1))
    nix_b_lba=$((root_b_lba + root_sectors + 1))
    state_lba=$((nix_b_lba + nix_sectors + 1))
  else
    state_lba=$((nix_lba + nix_sectors + 1))
  fi
  state_last=$((state_lba + state_sectors - 1))
  image_sectors=$((state_last + 1 + 2048))
  truncate -s "$((image_sectors * 512))" disk.img
  write_layout_env

  slot_n=()
  if [ "$slots" = 1 ]; then
    slot_n=(
      -n "6:$root_b_lba:$((root_b_lba + root_sectors - 1))"
      -c 6:JANUS_ROOT_B -t 6:8300
      -u 6:4a414e55-5300-4000-8000-000000000006
      -n "7:$nix_b_lba:$((nix_b_lba + nix_sectors - 1))"
      -c 7:JANUS_NIX_B -t 7:8300
      -u 7:4a414e55-5300-4000-8000-000000000007
    )
  fi
  # -o resets alignment to 2048, so -a 1 has to follow it.
  sgdisk -o -a 1 \
    -n "1:$boot_lba:$((boot_lba + boot_sectors - 1))" \
    -c "1:$bootLabel" -t 1:EF00 \
    -u 1:4a414e55-5300-4000-8000-000000000001 \
    -n "2:$root_lba:$((root_lba + root_sectors - 1))" \
    -c "2:$rootLabel" -t 2:8300 \
    -u 2:4a414e55-5300-4000-8000-000000000002 \
    -n "3:$nix_lba:$((nix_lba + nix_sectors - 1))" \
    -c "3:$nixLabel" -t 3:8300 \
    -u 3:4a414e55-5300-4000-8000-000000000003 \
    "${slot_n[@]}" \
    -n "4:$state_lba:$((state_lba + state_sectors - 1))" \
    -c "4:$stateLabel" -t 4:8300 \
    -u 4:4a414e55-5300-4000-8000-000000000004 \
    disk.img
  dd if=boot.img of=disk.img bs=512 seek="$boot_lba" conv=notrunc status=none
  dd if=root.img of=disk.img bs=512 seek="$root_lba" conv=notrunc status=none
  dd if=nix.img of=disk.img bs=512 seek="$nix_lba" conv=notrunc status=none
  if [ "$slots" = 1 ]; then
    dd if=root-b.img of=disk.img bs=512 seek="$root_b_lba" conv=notrunc status=none
    dd if=nix-b.img of=disk.img bs=512 seek="$nix_b_lba" conv=notrunc status=none
  fi
  dd if=state.img of=disk.img bs=512 seek="$state_lba" conv=notrunc status=none
}

prepare() {
  need JANUS_GPT_FIX
  need slots
  # shellcheck disable=SC1091
  . ./amlogic-layout.env
  hint_lba=$((boot_lba - 1))
  logicals=(
    --logical "$root_lba:$root_sectors"
    --logical "$nix_lba:$nix_sectors"
  )
  if [ "$slots" = 1 ]; then
    logicals+=(--logical "$root_b_lba:$root_sectors" --logical "$nix_b_lba:$nix_sectors")
  fi
  logicals+=(--logical "$state_lba:$state_sectors")
  "$JANUS_GPT_FIX" prepare disk.img \
    --hint-lba "$hint_lba" \
    --first-usable "$boot_lba" \
    --boot-lba "$boot_lba" \
    --boot-sectors "$boot_sectors" \
    "${logicals[@]}"
}

case "${1:-}" in
  layout) layout ;;
  prepare) prepare ;;
  *)
    echo "janus: amlogic-disk.sh layout|prepare" >&2
    exit 1
    ;;
esac
