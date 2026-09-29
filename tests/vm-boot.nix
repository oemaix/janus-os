# SPDX-License-Identifier: Apache-2.0
# Boot the x86_64-test image and check the phase 0 mount model. docs/09 §9.
{
  pkgs,
  self,
}: let
  os = self.lib.mkRouter {
    name = "vm";
    source = self;
    configRevision = self.rev or "unknown";
    modules = [
      ({pkgs, ...}: {
        janus.hardware.board = "x86_64-test";
        janus.access.ssh.authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval"
        ];
        systemd.services.janus-boot-stamp = {
          description = "Report whether the phase 0 filesystems mounted";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target" "janus-seed.service" "janus-persist-etc.service"];
          path = [pkgs.util-linux pkgs.systemd];
          serviceConfig.Type = "oneshot";
          script = ''
            set -eu
            fail() {
              echo "JANUS_BOOT_FAIL $1" > /dev/console
              systemctl poweroff
              exit 1
            }
            root=$(findmnt -n -o OPTIONS /)
            nix=$(findmnt -n -o OPTIONS /nix)
            var=$(findmnt -n -o OPTIONS /var)
            bytes=$(findmnt -n -b -o SIZE /var)
            echo "root=$root nix=$nix var=$var" > /dev/console
            case ",$root," in *,ro,*) ;; *) fail root ;; esac
            case ",$nix," in *,ro,*) ;; *) fail nix ;; esac
            case ",$var," in *,rw,*) ;; *) fail var ;; esac
            if ! mountpoint -q /etc/machine-id || ! [ -s /etc/machine-id ]; then
              fail machine-id
            fi
            echo JANUS_MACHINE_ID_OK > /dev/console
            if ! grep -qxE '[0-9a-f]{64} [0-9]+' /var/lib/janus/seed.stamp; then
              fail seed
            fi
            echo JANUS_SEED_OK > /dev/console
            echo "JANUS_VAR_BYTES=$bytes" > /dev/console
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
  pkgs.runCommand "vm-x86_64-test" {
    nativeBuildInputs = [pkgs.qemu pkgs.coreutils pkgs.mtools pkgs.gnugrep];
  } ''
    set -eu
    params=$(tr '\n' ' ' < ${toplevel}/kernel-params)
    params="$params init=${toplevel}/init"

    # The VM boots with -kernel. The FAT boot entry still has to name the init.
    mkdir -p bootcheck
    . ${image}/layout.env
    dd if=${image}/janus-vm.img of=boot.img bs=1M skip="$boot_start_mib" count="$boot_mib" status=none
    mcopy -i boot.img ::/extlinux.conf ::/cmdline.txt bootcheck/
    grep -q "init=${toplevel}/init" bootcheck/extlinux.conf
    grep -q "init=${toplevel}/init" bootcheck/cmdline.txt

    boot() {
      local disk="$1" serial="$2"
      set +e
      timeout 600 qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot -display none \
        -machine accel=tcg \
        -kernel ${toplevel}/kernel \
        -initrd ${toplevel}/initrd \
        -append "$params" \
        -snapshot \
        -drive if=none,id=disk,format=raw,file="$disk" \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
        -serial file:"$serial"
      set -e
    }

    require_ok() {
      local serial="$1"
      if grep -q JANUS_BOOT_FAIL "$serial" || ! grep -q JANUS_BOOT_OK "$serial"; then
        echo "--- $serial ---" >&2
        tail -n 200 "$serial" >&2 || true
        exit 1
      fi
      grep -q JANUS_MACHINE_ID_OK "$serial"
      grep -q JANUS_SEED_OK "$serial"
    }

    cp --reflink=auto ${image}/janus-vm.img large.img
    chmod u+w large.img
    truncate -s +256M large.img
    boot large.img serial-large.log
    require_ok serial-large.log
    bytes=$(sed -n 's/.*JANUS_VAR_BYTES=\([0-9]*\).*/\1/p' serial-large.log | tail -n 1)
    # 512 MiB state plus 256 MiB of extra disk, after f2fs overhead.
    if [ -z "$bytes" ] || [ "$bytes" -lt 629145600 ]; then
      echo "state filesystem did not grow (''${bytes:-missing})" >&2
      exit 1
    fi

    cp --reflink=auto ${image}/janus-vm.img corrupt.img
    chmod u+w corrupt.img
    # Wipe the state filesystem. fsck must not be able to mount it, so the
    # initrd reformats and the system still reaches the stamp.
    dd if=/dev/zero of=corrupt.img bs=1M seek="$state_start_mib" count="$state_mib" conv=notrunc status=none
    boot corrupt.img serial-corrupt.log
    require_ok serial-corrupt.log
    if ! grep -q "janus: reformatting JANUS_STATE" serial-corrupt.log; then
      echo "corrupt state was not reformatted" >&2
      tail -n 200 serial-corrupt.log >&2 || true
      exit 1
    fi

    mkdir -p "$out"
    cp serial-large.log serial-corrupt.log bootcheck/extlinux.conf bootcheck/cmdline.txt "$out/"
  ''
