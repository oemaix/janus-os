# SPDX-License-Identifier: Apache-2.0
# x86_64-test: QEMU virtio NICs, GPT, no raw firmware. docs/10 §3.
# Not a deployment board.
{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.janus.hardware.board == "x86_64-test") {
    janus.storage.firmwareOffsetMiB = lib.mkDefault 0;
    janus.network.ports = {
      wan = lib.mkDefault {device = "eth0";};
      lan = lib.mkDefault {device = "eth1";};
    };
    # ttyS0 last, so /dev/console is the serial port the VM test reads.
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200"
      "earlyprintk=serial,ttyS0,115200"
      "net.ifnames=0"
    ];
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "virtio_net"
      "virtio_ring"
    ];
    boot.loader.grub.enable = lib.mkDefault false;
    boot.loader.systemd-boot.enable = lib.mkDefault false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
  };
}
