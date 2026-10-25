# SPDX-License-Identifier: Apache-2.0
# Root and Nix filesystem images for both A/B slots. docs/09 §8.4.
# Labels match pkgs/image.nix. The inactive image is written over the
# inactive partition; the active slot is left mounted.
{
  stdenvNoCC,
  nix,
  f2fs-tools,
  fakeroot,
  bash,
  coreutils,
  gawk,
  findutils,
}: {
  toplevel,
  closureInfo,
  rootMinMiB,
  nixSlackPercent,
  nixMinMiB,
  nixSizeMode,
  nixExactMiB,
}:
stdenvNoCC.mkDerivation {
  name = "janus-slot-images";
  __structuredAttrs = false;
  nativeBuildInputs = [nix f2fs-tools fakeroot bash coreutils gawk findutils];
  inherit toplevel closureInfo rootMinMiB nixSlackPercent nixMinMiB nixSizeMode nixExactMiB;

  passthru = {
    inherit toplevel;
  };

  buildCommand = ''
    set -euo pipefail
    export PATH="${nix}/bin:${f2fs-tools}/bin:${fakeroot}/bin:${bash}/bin:${coreutils}/bin:${gawk}/bin:${findutils}/bin:$PATH"
    work=$(mktemp -d)
    cd "$work"
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

    . ${./f2fs-mib.sh}
    make_f2fs() {
      local label="$1" src="$2" out="$3" min_mib="$4" slack="$5" exact="$6"
      local mib
      mib=$(f2fs_partition_mib "$src" "$min_mib" "$slack" "$exact")
      truncate -s "''${mib}M" "$out"
      # mkfs creates the root inode. sload.f2fs -P never updates it, and
      # the default owner is the build user's getuid()/getgid().
      mkfs.f2fs -f -l "$label" -R 0:0 "$out" >&2
      fakeroot -- bash -c 'chown -R 0:0 "$1" && sload.f2fs -P -f "$1" -t / "$2"' bash "$src" "$out" >&2
      echo "$mib"
    }

    root_mib=$(make_f2fs JANUS_ROOT rootfs root-a.img "$rootMinMiB" 0 "")
    make_f2fs JANUS_ROOT_B rootfs root-b.img 0 0 "$root_mib" >/dev/null
    if [ "$nixSizeMode" = exact ]; then
      make_f2fs JANUS_NIX nixfs nix-a.img 0 0 "$nixExactMiB" >/dev/null
      make_f2fs JANUS_NIX_B nixfs nix-b.img 0 0 "$nixExactMiB" >/dev/null
    else
      nix_mib=$(make_f2fs JANUS_NIX nixfs nix-a.img "$nixMinMiB" "$nixSlackPercent" "")
      make_f2fs JANUS_NIX_B nixfs nix-b.img 0 0 "$nix_mib" >/dev/null
    fi

    mkdir -p "$out"
    install -m 0644 root-a.img root-b.img nix-a.img nix-b.img "$out/"
    printf '%s\n' "$toplevel" > "$out/toplevel"
  '';
}
