# SPDX-License-Identifier: Apache-2.0
# Boot the x86_64-test image. The serial console logs in as root.
# A failed state check starts the initrd shell and can see fsck.f2fs.
# A recover that exits before the stamp does not reach multi-user.
# A failed grow still reaches recover and multi-user.
# docs/08 §13, D-0067, D-0068.
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
  common = {
    janus.hardware.board = "x86_64-test";
    janus.storage.nix.minimumSize = "64M";
    janus.storage.state.maximumSize = "640M";
    janus.access.ssh.authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval"
    ];
    janus.debug.serialAutologin = true;
    janus.debug.initrdShell = true;
    users.users.root.shell = pkgs.lib.mkForce "${serialMarker}/bin/janus-serial-marker";
    environment.shells = ["${serialMarker}/bin/janus-serial-marker"];
    boot.initrd.systemd.users.root.shell = "${initrdMarker}/bin/janus-initrd-marker";
    boot.initrd.systemd.storePaths = [initrdMarker];
  };
  bootStamp = {pkgs, ...}: {
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
  };
  shellExec = {
    boot.initrd.systemd.services.janus-debug-shell.serviceConfig.ExecStart = pkgs.lib.mkForce "${initrdMarker}/bin/janus-initrd-marker";
  };
  # The real recover script marks, runs fsck, and exits 1 on 126/127
  # with the stamp still set. The shell's /bin keeps the real fsck.f2fs.
  fakeFsck = pkgs.writeShellScriptBin "fsck.f2fs" ''
    exit 126
  '';
  router = modules:
    self.lib.mkRouter {
      name = "vm-debug";
      source = self;
      configRevision = self.rev or "unknown";
      inherit modules;
    };
  loginOs = router [common bootStamp];
  checkOs = router [
    common
    bootStamp
    shellExec
    {
      boot.initrd.systemd.services.janus-state-recover.path = pkgs.lib.mkBefore [fakeFsck];
    }
  ];
  # Exits before the stamp, which is what a device that never appears does.
  missOs = router [
    common
    bootStamp
    shellExec
    {
      boot.initrd.systemd.services.janus-state-recover.script = pkgs.lib.mkForce ''
        set -eu
        exit 1
      '';
    }
  ];
  growOs = router [
    common
    bootStamp
    shellExec
    {
      boot.initrd.systemd.services.janus-grow-state.script = pkgs.lib.mkForce ''
        set -eu
        echo "<3>janus: grow failed on purpose" > /dev/kmsg
        exit 1
      '';
    }
  ];
in
  pkgs.runCommand "vm-x86_64-debug" {
    nativeBuildInputs = [pkgs.qemu pkgs.coreutils pkgs.gnugrep];
  } ''
    set -eu

    boot() {
      local toplevel="$1" image="$2" extra="$3" serial="$4" seconds="$5"
      local params
      params=$(tr '\n' ' ' < "$toplevel/kernel-params")
      params="$params init=$toplevel/init $extra"
      set +e
      timeout "$seconds" qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot -display none \
        -machine accel=tcg \
        -kernel "$toplevel/kernel" \
        -initrd "$toplevel/initrd" \
        -append "$params" \
        -snapshot \
        -drive if=none,id=disk,format=raw,file="$image" \
        -device virtio-blk-pci,drive=disk \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
        -serial file:"$serial"
      set -e
    }

    show() {
      echo "--- $1 ---" >&2
      grep -a -n -E 'JANUS_|sulogin|Emergency' "$1" | tail -n 40 >&2 || true
      tail -n 40 "$1" >&2 || true
    }

    boot ${loginOs.config.system.build.toplevel} ${loginOs.config.system.build.janusImage}/janus-vm-debug.img "" serial-login.log 600
    if grep -q JANUS_INITRD_SHELL serial-login.log \
      || ! grep -q JANUS_SERIAL_ROOT serial-login.log \
      || ! grep -q JANUS_BOOT_OK serial-login.log; then
      echo "serial root login did not reach the marker" >&2
      show serial-login.log
      exit 1
    fi

    boot ${checkOs.config.system.build.toplevel} ${checkOs.config.system.build.janusImage}/janus-vm-debug.img "" serial-check.log 300
    if ! grep -a -q JANUS_INITRD_SHELL serial-check.log \
      || ! grep -a -q JANUS_INITRD_FSCK serial-check.log \
      || grep -a -q JANUS_INITRD_FSCK_MISSING serial-check.log \
      || grep -a -q JANUS_SERIAL_ROOT serial-check.log \
      || grep -a -q JANUS_BOOT_OK serial-check.log; then
      echo "a failed state check did not open the initrd shell" >&2
      show serial-check.log
      exit 1
    fi

    boot ${missOs.config.system.build.toplevel} ${missOs.config.system.build.janusImage}/janus-vm-debug.img "" serial-miss.log 300
    if grep -a -q JANUS_INITRD_SHELL serial-miss.log \
      || grep -a -q JANUS_SERIAL_ROOT serial-miss.log \
      || grep -a -q JANUS_BOOT_OK serial-miss.log; then
      echo "a missing state device reached a shell" >&2
      show serial-miss.log
      exit 1
    fi

    boot ${growOs.config.system.build.toplevel} ${growOs.config.system.build.janusImage}/janus-vm-debug.img "" serial-grow.log 600
    if grep -a -q JANUS_INITRD_SHELL serial-grow.log \
      || ! grep -a -q JANUS_SERIAL_ROOT serial-grow.log \
      || ! grep -a -q JANUS_BOOT_OK serial-grow.log; then
      echo "a failed grow did not reach multi-user" >&2
      show serial-grow.log
      exit 1
    fi

    mkdir -p "$out"
    cp serial-login.log serial-check.log serial-miss.log serial-grow.log "$out/"
  ''
