# SPDX-License-Identifier: Apache-2.0
# Raspberry Pi 4 and Compute Module 4. docs/10 §3. Tier 2. BCM2711, aarch64.
# The Pi 4 has one gigabit port (genet). The CM4 uses that port on the
# official IO board. The Pi 400 has no Ethernet jack and is not a board (D-0032).
# The EEPROM loads start4.elf from the FAT partition. docs/05 §2: the
# profile writes a hybrid MBR so that firmware still finds the GPT boot
# partition.
{
  config,
  lib,
  pkgs,
  ...
}: let
  fw = "${pkgs.raspberrypifw}/share/raspberrypi/boot";
  dtbDir = "${config.boot.kernelPackages.kernel}/dtbs/broadcom";
in {
  config = lib.mkIf (config.janus.hardware.board == "rpi4") {
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
    };
    boot.kernelParams = [
      "console=ttyS0,115200"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "genet"
      "broadcom"
      "sdhci_iproc"
      "mmc_block"
      "xhci_pci"
      "pcie_brcmstb"
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
        cp ${fw}/bootcode.bin ${fw}/fixup4.dat ${fw}/start4.elf .
        cp ${dtbDir}/bcm2711-rpi-4-b.dtb ${dtbDir}/bcm2711-rpi-cm4-io.dtb .
        ${config.janus.board.bootScript}
        cat > config.txt << EOF
        arm_64bit=1
        enable_uart=1
        kernel=vmlinuz
        initramfs initrd followkernel
        [pi4]
        device_tree=bcm2711-rpi-4-b.dtb
        [cm4]
        device_tree=bcm2711-rpi-cm4-io.dtb
        [all]
        ${config.janus.board.configTxt}
        EOF
      '';
    };
  };
}
