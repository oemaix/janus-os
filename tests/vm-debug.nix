# SPDX-License-Identifier: Apache-2.0
# Boot the x86_64-test image twice. The first boot logs in as root on
# the serial console. The second starts the initrd emergency target and
# checks that its shell can see fsck.f2fs. docs/08 §13, D-0056, D-0057.
{
  pkgs,
  self,
}: let
  serialMarker = pkgs.writeShellScriptBin "janus-serial-marker" ''
    ${pkgs.coreutils}/bin/printf '%s\n' JANUS_SERIAL_ROOT > /dev/console
    ${pkgs.coreutils}/bin/touch /run/janus-serial-root
    while [ ! -f /run/janus-boot-ok ]; do
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    ${pkgs.systemd}/bin/systemctl poweroff
  '';
  initrdMarker = pkgs.writeShellScriptBin "janus-initrd-marker" ''
    ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_SHELL
    ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_SHELL > /dev/console
    found=$(command -v fsck.f2fs || true)
    case "$found" in
      */fsck.f2fs)
        ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_FSCK
        ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_FSCK > /dev/console
        ;;
      *)
        ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_FSCK_MISSING
        ${pkgs.coreutils}/bin/printf '%s\n' JANUS_INITRD_FSCK_MISSING > /dev/console
        ;;
    esac
    ${pkgs.systemd}/bin/systemctl reboot || ${pkgs.coreutils}/bin/printf b > /proc/sysrq-trigger
  '';
  os = self.lib.mkRouter {
    name = "vm-debug";
    source = self;
    configRevision = self.rev or "unknown";
    modules = [
      ({lib, ...}: {
        janus.hardware.board = "x86_64-test";
        janus.storage.nix.minimumSize = "64M";
        janus.storage.state.maximumSize = "640M";
        janus.access.ssh.authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval"
        ];
        janus.debug.serialAutologin = true;
        janus.debug.initrdShell = true;
        users.users.root.shell = lib.mkForce "${serialMarker}/bin/janus-serial-marker";
        environment.shells = ["${serialMarker}/bin/janus-serial-marker"];
        # The initrd passwd is built from these users. A second
        # /etc/passwd text is appended, and getpwnam keeps the first root.
        boot.initrd.systemd.users.root.shell = "${initrdMarker}/bin/janus-initrd-marker";
        boot.initrd.systemd.storePaths = [initrdMarker];
        systemd.services.janus-boot-stamp = {
          description = "Report that the debug image reached multi-user";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target"];
          path = [pkgs.coreutils];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            printf '%s\n' JANUS_BOOT_OK > /dev/console
            touch /run/janus-boot-ok
            sleep infinity
          '';
        };
      })
    ];
  };
  toplevel = os.config.system.build.toplevel;
  image = os.config.system.build.janusImage;
in
  pkgs.runCommand "vm-x86_64-debug" {
    nativeBuildInputs = [pkgs.qemu pkgs.coreutils pkgs.gnugrep];
  } ''
    set -eu
    params=$(tr '\n' ' ' < ${toplevel}/kernel-params)
    params="$params init=${toplevel}/init"

    boot() {
      local extra="$1" serial="$2"
      set +e
      timeout 600 qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot -display none \
        -machine accel=tcg \
        -kernel ${toplevel}/kernel \
        -initrd ${toplevel}/initrd \
        -append "$params $extra" \
        -snapshot \
        -drive if=none,id=disk,format=raw,file=${image}/janus-vm-debug.img \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
        -serial file:"$serial"
      set -e
    }

    show() {
      echo "--- $1 ---" >&2
      grep -a -n -E 'JANUS_|Press Enter|sulogin|Emergency' "$1" | tail -n 40 >&2 || true
      tail -n 40 "$1" >&2 || true
    }

    boot "" serial-login.log
    if grep -q JANUS_INITRD_SHELL serial-login.log \
      || ! grep -q JANUS_SERIAL_ROOT serial-login.log \
      || ! grep -q JANUS_BOOT_OK serial-login.log; then
      echo "serial root login did not reach the marker" >&2
      show serial-login.log
      exit 1
    fi

    # rd.systemd.unit= is the initrd copy. systemd.unit= would start the
    # emergency shell after switch-root. An empty root password still
    # waits for Enter.
    rm -f guest.in guest.out
    mkfifo guest.in guest.out
    exec 3<>guest.in
    exec 4<>guest.out
    cat guest.out > serial-emergency.log &
    catpid=$!
    (
      set +e
      for _ in $(seq 1 400); do
        if grep -q 'Press Enter' serial-emergency.log; then
          printf '\n' > guest.in
          exit 0
        fi
        sleep 0.2
      done
    ) &
    feed=$!
    set +e
    timeout 180 qemu-system-x86_64 \
      -m 2048 -smp 2 -no-reboot -display none \
      -machine accel=tcg \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$params rd.systemd.unit=emergency.target" \
      -snapshot \
      -drive if=none,id=disk,format=raw,file=${image}/janus-vm-debug.img \
      -device virtio-blk-pci,drive=disk \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
      -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
      -serial pipe:guest
    set -e
    kill "$catpid" "$feed" 2>/dev/null || true
    wait "$catpid" "$feed" 2>/dev/null || true
    exec 3>&-
    exec 4>&-
    if ! grep -a -q JANUS_INITRD_SHELL serial-emergency.log \
      || ! grep -a -q JANUS_INITRD_FSCK serial-emergency.log \
      || grep -a -q JANUS_INITRD_FSCK_MISSING serial-emergency.log; then
      echo "initrd emergency shell did not see fsck.f2fs" >&2
      show serial-emergency.log
      exit 1
    fi

    mkdir -p "$out"
    cp serial-login.log serial-emergency.log "$out/"
  ''
