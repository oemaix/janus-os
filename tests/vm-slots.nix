# SPDX-License-Identifier: Apache-2.0
# Boot a slotted image and check that janus.slot selects the A or B
# root and store. Both slots hold the same files, so the PARTUUID is
# what distinguishes them. docs/09 §8.4 and §9.
{
  pkgs,
  self,
}: let
  os = self.lib.mkRouter {
    name = "slots";
    source = self;
    configRevision = self.rev or "unknown";
    modules = [
      ({pkgs, ...}: {
        janus.hardware.board = "x86_64-test";
        janus.storage.slots.enable = true;
        janus.storage.nix.minimumSize = "64M";
        janus.access.ssh.authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval"
        ];
        systemd.services.janus-boot-stamp = {
          description = "Report which slot partitions mounted";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target"];
          path = [pkgs.coreutils pkgs.util-linux pkgs.systemd];
          serviceConfig.Type = "oneshot";
          script = ''
            set -eu
            fail() {
              echo "JANUS_BOOT_FAIL $1" > /dev/console
              systemctl poweroff
              exit 1
            }
            report() {
              name=$1
              mountpoint=$2
              if [ ! -b "/dev/disk/by-janus/$name" ]; then
                fail "$name-link"
              fi
              link=$(readlink -f "/dev/disk/by-janus/$name")
              dev=$(readlink -f "$(findmnt -n -o SOURCE "$mountpoint")")
              if [ "$dev" != "$link" ]; then
                fail "$name"
              fi
              id=$(blkid -s PARTUUID -o value "$dev" || true)
              id=$(printf '%s' "$id" | tr 'A-F' 'a-f')
              if [ -z "$id" ]; then
                fail "$name-partuuid"
              fi
              echo "JANUS_''${name^^}_PARTUUID=$id" > /dev/console
            }
            report root /
            report nix /nix
            echo JANUS_BOOT_OK > /dev/console
            systemctl poweroff
          '';
        };
      })
    ];
  };
  toplevel = os.config.system.build.toplevel;
  image = os.config.system.build.janusImage;
in
  pkgs.runCommand "vm-x86_64-slots" {
    nativeBuildInputs = [pkgs.qemu pkgs.coreutils pkgs.gnugrep];
  } ''
    set -eu
    params=$(tr '\n' ' ' < ${toplevel}/kernel-params)
    params="$params init=${toplevel}/init"

    boot() {
      local slot="$1" serial="$2"
      set +e
      timeout 600 qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot -display none \
        -machine accel=tcg \
        -kernel ${toplevel}/kernel \
        -initrd ${toplevel}/initrd \
        -append "$params janus.slot=$slot" \
        -snapshot \
        -drive if=none,id=disk,format=raw,file=${image}/janus-slots.img \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
        -serial file:"$serial"
      set -e
    }

    require_slot() {
      local serial="$1" root="$2" nix="$3"
      if grep -q JANUS_BOOT_FAIL "$serial" || ! grep -q JANUS_BOOT_OK "$serial"; then
        echo "--- $serial ---" >&2
        tail -n 200 "$serial" >&2 || true
        exit 1
      fi
      grep -q "JANUS_ROOT_PARTUUID=$root" "$serial"
      grep -q "JANUS_NIX_PARTUUID=$nix" "$serial"
    }

    boot a serial-a.log
    require_slot serial-a.log \
      4a414e55-5300-4000-8000-000000000002 \
      4a414e55-5300-4000-8000-000000000003
    boot b serial-b.log
    require_slot serial-b.log \
      4a414e55-5300-4000-8000-000000000006 \
      4a414e55-5300-4000-8000-000000000007

    mkdir -p "$out"
    cp serial-a.log serial-b.log "$out/"
  ''
