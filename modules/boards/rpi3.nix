# SPDX-License-Identifier: Apache-2.0
# Raspberry Pi 3 / 3+. docs/10 §3. Tier 2. One 100 MbE port on the USB bus.
# The GPU firmware on the FAT partition loads the kernel (config.txt).
{
  config,
  lib,
  pkgs,
  ...
}: let
  fw = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
  dtbDir = "${config.boot.kernelPackages.kernel}/dtbs/broadcom";
in {
  config = lib.mkIf (config.janus.hardware.board == "rpi3") {
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
    };
    boot.kernelParams = [
      "console=ttyS0,115200"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "smsc95xx"
      "lan78xx"
      "dwc2"
      "sdhci_iproc"
      "mmc_block"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      bootExtra = ''
        cp ${fw}/bootcode.bin ${fw}/fixup*.dat ${fw}/start*.elf .
        cp ${dtbDir}/bcm2710-rpi-3-b.dtb ${dtbDir}/bcm2710-rpi-3-b-plus.dtb .
        ${config.janus.board.bootScript}
        cat > config.txt << EOF
        arm_64bit=1
        enable_uart=1
        kernel=vmlinuz
        initramfs initrd followkernel
        [pi3]
        device_tree=bcm2710-rpi-3-b.dtb
        [pi3+]
        device_tree=bcm2710-rpi-3-b-plus.dtb
        [all]
        ${config.janus.board.configTxt}
        EOF
      '';
    };
  };
}
