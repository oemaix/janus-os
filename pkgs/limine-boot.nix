# SPDX-License-Identifier: Apache-2.0
# Limine BIOS files for the Yanyu image. pkgs/image.nix and tests/limine-bios.nix
# both use these scripts. docs/10 §3.1, D-0029.
{limine}: {
  # $params is the kernel command line, including init=.
  configScript = ''
    cp ${limine}/share/limine/limine-bios.sys bootfiles/limine-bios.sys
    cat > bootfiles/limine.conf << EOF
    timeout: 0
    serial: yes
    editor_enabled: no
    /janus
        protocol: linux
        kernel_path: boot():/vmlinuz
        cmdline: $params
        module_path: boot():/initrd
    EOF
  '';

  # $boot_start is the boot partition offset in MiB. Partition 5 is the
  # unformatted gap immediately before it.
  biosPartitionScript = ''
    if [ "$boot_start" -lt 2 ]; then
      echo "janus: Limine needs the boot partition at 2 MiB or later" >&2
      exit 1
    fi
    sgdisk -a 1 \
      -n "5:2048:$((boot_start * 2048 - 1))" \
      -c 5:JANUS_BIOS -t 5:EF02 \
      -u 5:4a414e55-5300-4000-8000-000000000005 \
      disk.img
    ${limine}/bin/limine bios-install disk.img 5
  '';
}
