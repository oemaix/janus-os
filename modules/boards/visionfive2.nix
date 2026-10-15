# SPDX-License-Identifier: Apache-2.0
# StarFive VisionFive 2. docs/10 §3. Tier 3. JH7110, riscv64, two 1 GbE ports.
# The boot ROM loads SPL and U-Boot from GPT partitions by type GUID.
# The boot partition starts at 8 MiB, after those two partitions.
# extlinux.conf does not name a DTB. U-Boot supplies the one for the board revision.
# The profile does not choose a WAN jack.
{
  config,
  lib,
  pkgs,
  ...
}: let
  uboot = pkgs.ubootVisionFive2;
  dtbDir = "${config.boot.kernelPackages.kernel}/dtbs/starfive";
in {
  config = lib.mkIf (config.janus.hardware.board == "visionfive2") {
    # 1 MiB GPT header, then SPL at 2 MiB and U-Boot at 4 MiB. Boot starts at 8 MiB.
    janus.storage.firmwareOffsetMiB = lib.mkDefault 7;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
      eth1 = {};
    };
    boot.kernelParams = [
      "console=ttyS0,115200"
      "earlycon"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "mmc_block"
      "dw_mmc-starfive"
      "nvme"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      bootExtra = ''
        cp ${dtbDir}/jh7110-starfive-visionfive-2-v1.2a.dtb .
        cp ${dtbDir}/jh7110-starfive-visionfive-2-v1.3b.dtb .
      '';
      firmwareInstall = ''
        if [ "$boot_start" -lt 8 ]; then
          echo "janus: VisionFive 2 needs the boot partition at 8 MiB or later (firmwareOffsetMiB >= 7)" >&2
          exit 1
        fi
        spl=${uboot}/u-boot-spl.bin.normal.out
        itb=${uboot}/u-boot.itb
        spl_size=$(stat -c %s "$spl")
        itb_size=$(stat -c %s "$itb")
        if [ "$spl_size" -gt $((2 * 1024 * 1024)) ]; then
          echo "janus: SPL ($spl_size bytes) does not fit the 2 MiB partition" >&2
          exit 1
        fi
        if [ "$itb_size" -gt $((4 * 1024 * 1024)) ]; then
          echo "janus: U-Boot ($itb_size bytes) does not fit the 4 MiB partition" >&2
          exit 1
        fi
        sgdisk \
          -n "8:$(sec 2):$(($(sec 4) - 1))" \
          -c 8:spl \
          -t 8:2E54B353-1271-4842-806F-E436D6AF6985 \
          -n "9:$(sec 4):$(($(sec 8) - 1))" \
          -c 9:uboot \
          -t 9:BC13C2FF-59E6-4262-A352-B275FD6F7172 \
          -A 1:set:2 \
          disk.img
        dd if="$spl" of=disk.img bs=1M seek=2 conv=notrunc status=none
        dd if="$itb" of=disk.img bs=1M seek=4 conv=notrunc status=none
      '';
    };
  };
}
