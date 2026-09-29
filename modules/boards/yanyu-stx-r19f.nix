# SPDX-License-Identifier: Apache-2.0
# Yanyu STX-R19F. docs/10 §3.1. Legacy AMI BIOS, Limine, no EFI.
# Four Intel 82583V NICs. The profile does not choose a WAN jack.
# The lab OpenWrt install uses GRUB. The Janus image uses Limine (D-0029).
{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.janus.hardware.board == "yanyu-stx-r19f") {
    # Boot partition starts at 2 MiB. The MiB before it is JANUS_BIOS.
    janus.storage.firmwareOffsetMiB = lib.mkDefault 1;
    # PCI paths measured for this board. systemd.link renames them.
    janus.network.ports = lib.mkDefault {
      lan1 = {match.path = "pci-0000:01:00.0";};
      lan2 = {match.path = "pci-0000:02:00.0";};
      lan3 = {match.path = "pci-0000:03:00.0";};
      lan4 = {match.path = "pci-0000:04:00.0";};
    };
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
    ];
    boot.initrd.availableKernelModules = [
      "ahci"
      "sd_mod"
      "e1000e"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      limineBios = true;
    };
  };
}
