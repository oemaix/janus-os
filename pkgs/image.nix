# SPDX-License-Identifier: Apache-2.0
# Assemble a GPT image: FAT boot, f2fs root, f2fs nix store, f2fs state.
# No loop mounts and no root. docs/09 §6, ADR-0010.
{
  lib,
  stdenvNoCC,
  nix,
  f2fs-tools,
  dosfstools,
  mtools,
  gptfdisk,
  fakeroot,
  zstd,
  jq,
  bash,
  coreutils,
}: {
  hostName,
  toplevel,
  closureInfo,
  buildJson,
  firmwareOffsetMiB,
  bootMiB,
  rootMinMiB,
  stateMiB,
  nixSlackPercent,
  nixSizeMode,
  nixExactMiB,
  bootLabel,
  rootLabel,
  nixLabel,
  stateLabel,
}:
stdenvNoCC.mkDerivation {
  name = "janus-${hostName}-image";
  __structuredAttrs = false;

  nativeBuildInputs = [
    nix
    f2fs-tools
    dosfstools
    mtools
    gptfdisk
    fakeroot
    zstd
    jq
    bash
    coreutils
  ];

  inherit
    toplevel
    closureInfo
    buildJson
    firmwareOffsetMiB
    bootMiB
    rootMinMiB
    stateMiB
    nixSlackPercent
    nixSizeMode
    nixExactMiB
    bootLabel
    rootLabel
    nixLabel
    stateLabel
    hostName
    ;

  # The Nix database is loaded below with NIX_STATE_DIR inside the image tree.
  requiredSystemFeatures = [];

  buildCommand = ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [
      nix
      f2fs-tools
      dosfstools
      mtools
      gptfdisk
      fakeroot
      zstd
      jq
      bash
      coreutils
    ]}:$PATH"

    work=$(mktemp -d)
    cd "$work"

    # The filesystem is mounted at /nix, so its root is store/ and var/.
    # The sandbox cannot write /nix/var. The database lives in this tree;
    # the paths it records stay /nix/store/... on the board.
    mkdir -p nixfs/store nixfs/var/nix nixfs/var/log/nix
    xargs -I % cp -a --reflink=auto % nixfs/store/ < "$closureInfo/store-paths"
    export NIX_STATE_DIR="$work/nixfs/var/nix"
    export NIX_LOG_DIR="$work/nixfs/var/log/nix"
    unset NIX_REMOTE || true
    nix-store --load-db < "$closureInfo/registration"
    mkdir -p nixfs/var/nix/profiles
    ln -s "$toplevel" nixfs/var/nix/profiles/system-1-link
    ln -sfn system-1-link nixfs/var/nix/profiles/system

    mkdir -p rootfs/bin rootfs/boot rootfs/dev rootfs/etc rootfs/home \
      rootfs/nix rootfs/proc rootfs/run rootfs/sys rootfs/tmp rootfs/usr/bin rootfs/var
    ln -s ${bash}/bin/sh rootfs/bin/sh
    ln -s ${bash}/bin/bash rootfs/bin/bash
    ln -s ${coreutils}/bin/env rootfs/usr/bin/env
    ln -s /var/lib/janus/root rootfs/root

    # Populate an f2fs image from a directory. Prints the size in MiB.
    # The sixth argument, when non-empty, is the exact size in MiB.
    make_f2fs() {
      local label="$1" src="$2" out="$3" min_mib="$4" slack="$5" exact="$6"
      local bytes mib inodes
      if [ -n "$exact" ]; then
        mib=$exact
      else
        bytes=$(du -s -B1 "$src" | awk '{ print $1 }')
        inodes=$(find "$src" | wc -l)
        # f2fs spends a node block on every inode. A Nix store is mostly small files.
        bytes=$(( bytes * (100 + slack) / 100 + inodes * 4096 + 128 * 1024 * 1024 ))
        mib=$(( (bytes + 1048575) / 1048576 ))
        if (( mib < min_mib )); then mib=$min_mib; fi
      fi
      truncate -s "''${mib}M" "$out"
      mkfs.f2fs -f -l "$label" "$out" >&2
      fakeroot -- bash -c 'chown -R 0:0 "$1" && sload.f2fs -P -f "$1" -t / "$2"' bash "$src" "$out" >&2
      echo "$mib"
    }

    root_mib=$(make_f2fs "$rootLabel" rootfs root.img "$rootMinMiB" 0 "")
    if [ "$nixSizeMode" = exact ]; then
      nix_mib=$(make_f2fs "$nixLabel" nixfs nix.img 0 0 "$nixExactMiB")
    else
      nix_mib=$(make_f2fs "$nixLabel" nixfs nix.img 64 "$nixSlackPercent" "")
    fi

    truncate -s "''${stateMiB}M" state.img
    mkfs.f2fs -f -l "$stateLabel" state.img

    mkdir -p bootfiles
    cp -L "$toplevel/kernel" bootfiles/vmlinuz
    cp -L "$toplevel/initrd" bootfiles/initrd
    # One generation. The VM test boots with -kernel; the file is the boot entry.
    params=$(tr '\n' ' ' < "$toplevel/kernel-params")
    params="$params init=$toplevel/init"
    cat > bootfiles/extlinux.conf << EOF
    DEFAULT janus
    LABEL janus
      LINUX /vmlinuz
      INITRD /initrd
      APPEND $params
    EOF
    # extlinux rejects leading spaces on the DEFAULT line; rewrite without indent.
    sed -i 's/^    //' bootfiles/extlinux.conf
    printf '%s\n' "$params" > bootfiles/cmdline.txt

    truncate -s "''${bootMiB}M" boot.img
    mkfs.vfat -F 32 -n "$bootLabel" boot.img
    mcopy -i boot.img bootfiles/vmlinuz bootfiles/initrd bootfiles/extlinux.conf bootfiles/cmdline.txt ::/

    start_mib=$(( 1 + firmwareOffsetMiB ))
    boot_start=$start_mib
    root_start=$(( boot_start + bootMiB ))
    nix_start=$(( root_start + root_mib ))
    state_start=$(( nix_start + nix_mib ))
    state_end=$(( state_start + stateMiB ))
    # One MiB past the last partition holds the backup GPT header.
    total_mib=$(( state_end + 1 ))
    truncate -s "''${total_mib}M" disk.img

    sec() { echo $(( $1 * 2048 )); }
    sgdisk -o \
      -n "1:$(sec "$boot_start"):$(( $(sec "$root_start") - 1 ))" \
      -c "1:$bootLabel" -t 1:EF00 \
      -u 1:4a414e55-5300-4000-8000-000000000001 \
      -n "2:$(sec "$root_start"):$(( $(sec "$nix_start") - 1 ))" \
      -c "2:$rootLabel" -t 2:8300 \
      -u 2:4a414e55-5300-4000-8000-000000000002 \
      -n "3:$(sec "$nix_start"):$(( $(sec "$state_start") - 1 ))" \
      -c "3:$nixLabel" -t 3:8300 \
      -u 3:4a414e55-5300-4000-8000-000000000003 \
      -n "4:$(sec "$state_start"):$(( $(sec "$state_end") - 1 ))" \
      -c "4:$stateLabel" -t 4:8300 \
      -u 4:4a414e55-5300-4000-8000-000000000004 \
      disk.img

    dd if=boot.img of=disk.img bs=1M seek="$boot_start" conv=notrunc status=none
    dd if=root.img of=disk.img bs=1M seek="$root_start" conv=notrunc status=none
    dd if=nix.img of=disk.img bs=1M seek="$nix_start" conv=notrunc status=none
    dd if=state.img of=disk.img bs=1M seek="$state_start" conv=notrunc status=none

    printf 'boot_start_mib=%s\nboot_mib=%s\nstate_start_mib=%s\nstate_mib=%s\n' \
      "$boot_start" "$bootMiB" "$state_start" "$stateMiB" > layout.env

    mkdir -p "$out"
    install -m 0644 disk.img "$out/janus-$hostName.img"
    zstd -T"''${NIX_BUILD_CORES:-1}" -q --no-progress disk.img -o "$out/janus-$hostName.img.zst"
    install -m 0644 "$buildJson" "$out/build.json"
    install -m 0644 layout.env "$out/layout.env"
    (
      cd "$out"
      sha256sum "janus-$hostName.img" "janus-$hostName.img.zst" > SHA256SUMS
    )
  '';
}
