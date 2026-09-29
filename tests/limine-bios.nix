# SPDX-License-Identifier: Apache-2.0
# The Yanyu Limine scripts on a GPT disk with FAT32, the filesystem the
# image builder writes. No loop device. docs/10 §3.1, D-0029.
{pkgs}: let
  limineBoot = import ../pkgs/limine-boot.nix {inherit (pkgs) limine;};
in
  pkgs.runCommand "limine-bios" {
    nativeBuildInputs = [
      pkgs.limine
      pkgs.gptfdisk
      pkgs.dosfstools
      pkgs.mtools
      pkgs.qemu_kvm
    ];
  } ''
    set -eu
    mkdir -p bootfiles
    printf 'ok\n' > bootfiles/vmlinuz
    printf 'ok\n' > bootfiles/initrd
    params='console=tty0 console=ttyS0,115200n8 init=/bin/init'
    ${limineBoot.configScript}
    # 64 MiB is a valid FAT32. 16 MiB is not, and Limine then misses stage 3.
    # The image builder's boot partition is 256 MiB, created with the same -F 32.
    truncate -s 64M boot.img
    mkfs.vfat -F 32 -n JANUS_BOOT boot.img
    mcopy -i boot.img bootfiles/* ::/
    # Boot partition at 2 MiB. JANUS_BIOS occupies the MiB before it.
    truncate -s 72M disk.img
    boot_start=2
    sgdisk -o \
      -n 1:4096:135167 -c 1:JANUS_BOOT -t 1:EF00 \
      -u 1:4a414e55-5300-4000-8000-000000000001 \
      disk.img
    dd if=boot.img of=disk.img bs=1M seek=2 conv=notrunc status=none
    ${limineBoot.biosPartitionScript}
    sgdisk -i 5 disk.img | grep -q 'BIOS boot'
    mcopy -i disk.img@@2M ::/limine.conf conf
    grep -q 'editor_enabled: no' conf
    grep -q 'module_path: boot():/initrd' conf
    grep -q 'console=ttyS0,115200n8' conf
    timeout 20 qemu-system-x86_64 \
      -machine pc -accel tcg -m 64 -nographic -no-reboot \
      -drive file=disk.img,format=raw,if=ide \
      > serial.log 2> qemu.err || true
    if ! grep -q 'Loading kernel' serial.log; then
      echo '--- serial ---' >&2
      cat serial.log >&2 || true
      echo '--- qemu ---' >&2
      cat qemu.err >&2 || true
      exit 1
    fi
    mkdir -p "$out"
    echo ok > "$out/ok"
  ''
