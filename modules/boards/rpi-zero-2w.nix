# SPDX-License-Identifier: Apache-2.0
# Raspberry Pi Zero 2 W. docs/10 §3. No onboard Ethernet.
# The GPU firmware on the FAT partition loads the kernel (config.txt).
# A USB Ethernet peripheral is a separate janus.hardware.peripherals entry.
{
  config,
  lib,
  pkgs,
  ...
}: let
  fw = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
  dtb = "${config.boot.kernelPackages.kernel}/dtbs/broadcom/bcm2710-rpi-zero-2-w.dtb";
in {
  config = lib.mkIf (config.janus.hardware.board == "rpi-zero-2w") {
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    boot.kernelParams = [
      "console=ttyS0,115200"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "sdhci_iproc"
      "mmc_block"
      "dwc2"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    # Closed Broadcom firmware for the onboard Wi-Fi. The AP is phase 3.
    hardware.enableRedistributableFirmware = lib.mkDefault true;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      bootExtra = ''
        cp ${fw}/bootcode.bin ${fw}/fixup*.dat ${fw}/start*.elf .
        cp ${dtb} bcm2710-rpi-zero-2-w.dtb
        cat > config.txt << EOF
        arm_64bit=1
        enable_uart=1
        kernel=vmlinuz
        initramfs initrd followkernel
        device_tree=bcm2710-rpi-zero-2-w.dtb
        EOF
      '';
    };
  };
}
