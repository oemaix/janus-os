# SPDX-License-Identifier: Apache-2.0
# Raspberry Pi 2 v1.1. docs/10 §3. Tier 3. BCM2836, armv7l, one 100 MbE port.
# A Pi 2 v1.2 is a BCM2837 and uses the rpi3 profile.
# The boot ROM reads an MBR FAT partition. The image stays GPT for Linux
# and writes a hybrid MBR whose first entry is that FAT filesystem (docs/05 §2).
{
  config,
  lib,
  pkgs,
  ...
}: let
  fw = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
  dtb = "${config.boot.kernelPackages.kernel}/dtbs/broadcom/bcm2836-rpi-2-b.dtb";
in {
  config = lib.mkIf (config.janus.hardware.board == "rpi2") {
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
    };
    boot.kernelParams = [
      "console=ttyAMA0,115200"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "smsc95xx"
      "dwc2"
      "mmc_block"
      "bcm2835"
      "sdhci_iproc"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      hybridFatMbr = true;
      bootExtra = ''
        cp ${fw}/bootcode.bin ${fw}/fixup*.dat ${fw}/start*.elf .
        cp ${dtb} bcm2836-rpi-2-b.dtb
        ${config.janus.board.bootScript}
        cat > config.txt << EOF
        enable_uart=1
        kernel=vmlinuz
        initramfs initrd followkernel
        device_tree=bcm2836-rpi-2-b.dtb
        ${config.janus.board.configTxt}
        EOF
      '';
    };
  };
}
