# SPDX-License-Identifier: Apache-2.0
# Libre Computer AML-S905X-CC (Le Potato). docs/10 §3.
# One 100 MbE port. Mainline U-Boot FIP from nixpkgs ubootLibreTechCC.
# That package's aml_encrypt_gxl is an x86_64 binary, so the image is built
# on x86_64. The profile does not choose a WAN role for the single jack.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # ubootLibreTechCC runs aml_encrypt_gxl, an x86_64 binary, while the
  # blob itself is aarch64. Cross from x86_64. An aarch64 build host needs
  # an x86_64 builder for this one derivation.
  uboot = (import pkgs.path {
    system = "x86_64-linux";
    config.allowUnfreePredicate = pkg: let
      licenses = lib.toList (pkg.meta.license or []);
    in
      builtins.any (
        license: (license.redistributable or false) && !(license.free or true)
      )
      licenses;
  })
  .pkgsCross
  .aarch64-multiplatform
  .ubootLibreTechCC;
  dtb = "${config.boot.kernelPackages.kernel}/dtbs/amlogic/meson-gxl-s905x-libretech-cc.dtb";
in {
  config = lib.mkIf (config.janus.hardware.board == "le-potato") {
    # FIP is written at sector 1. The boot partition starts at 4 MiB.
    janus.storage.firmwareOffsetMiB = lib.mkDefault 3;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
    };
    boot.kernelParams = [
      "console=ttyAML0,115200n8"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "mmc_block"
      "sdhci_meson"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      dtbName = "meson-gxl-s905x-libretech-cc.dtb";
      dtbSource = dtb;
      # nixpkgs ubootLibreTechCC: skip the image's own MBR sector, then
      # restore the first 444 bytes so the GPT protective partition table stays.
      firmwareInstall = ''
        fw=${uboot}/u-boot.gxl
        size=$(stat -c %s "$fw")
        limit=$(( boot_start * 1024 * 1024 ))
        if [ "$size" -ge "$limit" ]; then
          echo "janus: U-Boot FIP ($size bytes) overlaps the boot partition at ''${limit}" >&2
          exit 1
        fi
        dd if="$fw" of=disk.img bs=512 skip=1 seek=1 conv=notrunc status=none
        dd if="$fw" of=disk.img bs=1 count=444 conv=notrunc status=none
      '';
    };
  };
}
