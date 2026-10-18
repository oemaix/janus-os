# SPDX-License-Identifier: Apache-2.0
# StarFive VisionFive 2. docs/10 §3. Tier 3. JH7110, riscv64, two 1 GbE ports.
# U-Boot 2026.04 loads from QSPI (D-0047). One disk image serves the SD card,
# eMMC, and NVMe. This U-Boot tries eMMC, then the SD card, then NVMe.
# extlinux.conf does not name a DTB. U-Boot supplies the one for the board
# revision. The profile does not choose a WAN jack.
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
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
      eth1 = {};
    };
    boot.kernelParams = [
      "console=ttyS0,115200"
      "earlycon"
      "net.ifnames=0"
    ];
    # dw_mmc-starfive is built in. NVMe root also needs the PCIe host and its PHY.
    boot.initrd.availableKernelModules = [
      "mmc_block"
      "dw_mmc-starfive"
      "nvme"
      "pcie-starfive"
      "phy-jh7110-pcie"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      # QSPI map from the U-Boot 2026.04 JH7110 board document: SPL at 0
      # (0xf0000), ITB at 0x100000 (0xf00000). The image does not write the flash.
      bootExtra = ''
        spl=${uboot}/u-boot-spl.bin.normal.out
        itb=${uboot}/u-boot.itb
        spl_size=$(stat -c %s "$spl")
        itb_size=$(stat -c %s "$itb")
        if [ "$spl_size" -gt $((0xf0000)) ]; then
          echo "janus: SPL ($spl_size bytes) exceeds the QSPI spl region 0xf0000" >&2
          exit 1
        fi
        if [ "$itb_size" -gt $((0xf00000)) ]; then
          echo "janus: U-Boot ITB ($itb_size bytes) exceeds the QSPI uboot region 0xf00000" >&2
          exit 1
        fi
        cp ${dtbDir}/jh7110-starfive-visionfive-2-v1.2a.dtb .
        cp ${dtbDir}/jh7110-starfive-visionfive-2-v1.3b.dtb .
        cp "$spl" u-boot-spl.bin.normal.out
        cp "$itb" u-boot.itb
      '';
    };
  };
}
