# SPDX-License-Identifier: Apache-2.0
# Strip unused module trees from a kernel and rebuild the depmod index.
# Pure function so a test can apply it to a synthetic module tree
# (tests/eval.nix, eval-kernel-trim) without building a kernel.
{lib, pkgs}: let
  # Runtime-safe directories to drop. The appliance boots via Limine BIOS
  # with wired igb/e1000e NICs, SATA/USB storage and f2fs/vfat, so GPU,
  # sound, media, wireless and Infiniband trees are dead weight. fs/ is
  # kept whole (erofs/squashfs/overlay are used by the running system).
  dropDirs = [
    "kernel/sound"
    "kernel/drivers/gpu"
    "kernel/drivers/media"
    "kernel/drivers/bluetooth"
    "kernel/drivers/infiniband"
    "kernel/drivers/staging"
    "kernel/drivers/parport"
    "kernel/drivers/net/wireless"
    "kernel/net/bluetooth"
    "kernel/net/wireless"
    "kernel/net/rfkill"
    "kernel/net/6lowpan"
  ];

  # Wrap a kernel derivation with the module-tree trim. Re-applied after any
  # .override (NixOS's kernel.nix adds a randstructSeed), so the passthru
  # forwards overrides to the base kernel and trims the result again.
  trimKernel = k:
    pkgs.stdenv.mkDerivation {
      pname = "linux";
      # modDirVersion is a plain attribute, not only a passthru entry:
      # nixpkgs reads kernel.modDirVersion directly, and a wrapped kernel
      # whose base has no passthru would otherwise lose it.
      inherit (k) version modDirVersion;
      outputs = ["out" "modules"];
      # dev is forwarded untouched: the upstream dev tree ships dangling
      # selftest symlinks that fail noBrokenSymlinks when rebuilt locally.
      passthru =
        (k.passthru or {})
        // {
          dev = k.dev;
          override = args: trimKernel (k.override args);
          # Marker for assertions: verifies the trim is the kernel that
          # actually landed on boot.kernelPackages.
          janusTrimmed = true;
        };
      nativeBuildInputs = [pkgs.kmod];
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        cp -r ${k.out} "$out"
        chmod -R u+w "$out"
        cp -r ${k.modules} "$modules"
        chmod -R u+w "$modules"
        cd "$modules/lib/modules/${k.modDirVersion}"
        ${lib.concatMapStrings (d: ''
          rm -rf ${d}
        '')
        dropDirs}
        # depmod -b appends lib/modules/<version> itself.
        depmod -b "$modules" "${k.modDirVersion}"
      '';
    };
in {
  inherit dropDirs trimKernel;
}
