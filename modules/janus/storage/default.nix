# SPDX-License-Identifier: Apache-2.0
# Partition model, read-only root, /etc overlay. docs/05.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types mkIf mkDefault;
  cfg = config.janus.storage;
  # GPT partition GUID. It survives a wiped filesystem, unlike by-label.
  statePartUuid = "4a414e55-5300-4000-8000-000000000004";

  sizeMiB = s: let
    m = builtins.match "([0-9]+)([KMGT]i?B?)" s;
    n =
      if m == null
      then null
      else lib.toInt (lib.elemAt m 0);
    unit =
      if m == null
      then ""
      else lib.elemAt m 1;
  in
    if m == null
    then throw "janus.storage size '${s}' is not a number of MiB or GiB (for example 256M or 1G)."
    else if lib.hasPrefix "G" unit
    then n * 1024
    else if lib.hasPrefix "M" unit
    then n
    else throw "janus.storage size '${s}' must use M or G.";

  slackPercent = s: let
    m = builtins.match "([0-9]+)%" s;
  in
    if m == null
    then throw "janus.storage slack '${s}' is not a percentage such as 15%."
    else lib.toInt (lib.elemAt m 0);

  partition = types.submodule {
    options = {
      size = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "256M";
        description = "Partition size, such as 256M or 1G. Null sizes the Nix partition from the closure and the state partition from state.minimumSize. A set Nix size is used as given.";
      };
      fsType = mkOption {
        type = types.enum ["f2fs" "vfat" "erofs" "squashfs"];
        description = "Filesystem. The image builder writes f2fs and FAT.";
      };
      mountPoint = mkOption {
        type = types.str;
        description = "Mount point. Partitions are found by label.";
      };
      readOnly = mkOption {
        type = types.bool;
        description = "Mounted read-only. / and /nix must be read-only.";
      };
      options = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Mount options.";
      };
      slack = mkOption {
        type = types.str;
        default = "0%";
        example = "15%";
        description = "Extra space when the image builder sizes this partition from its contents. The Nix partition uses 15%, and the builder also reserves one 4 KiB node block per file plus 128 MiB so f2fs can store the closure.";
      };
    };
  };

  parts = lib.attrValues cfg.layout.partitions;
  mounted = mp: lib.filter (p: p.mountPoint == mp) parts;

  janusNixPartition =
    if cfg.layout.partitions.JANUS_NIX.size == null
    then {
      mode = "auto";
      exactMiB = null;
    }
    else {
      mode = "exact";
      exactMiB = sizeMiB cfg.layout.partitions.JANUS_NIX.size;
    };

  # Phase 0 seed is the empty snapshot. The hash and generation are what
  # janus-seed compares, so a later snapshot with a higher generation replaces it.
  janusSeed = pkgs.runCommand "janus-seed" {} ''
    set -eu
    mkdir -p $out/subscriptions $out/geodata $out/engine
    cat > $out/manifest.json << 'EOF'
    {"generation":1,"subscriptions":[],"geodata":[],"engine":null}
    EOF
    echo 1 > $out/seed.generation
    sha256sum $out/manifest.json | cut -d' ' -f1 > $out/seed.hash
  '';
in {
  options.janus.storage = {
    layout.partitions = mkOption {
      type = types.attrsOf partition;
      default = {
        JANUS_BOOT = {
          size = "256M";
          fsType = "vfat";
          mountPoint = "/boot";
          readOnly = true;
          options = ["ro" "umask=0077"];
        };
        JANUS_ROOT = {
          size = "64M";
          fsType = "f2fs";
          mountPoint = "/";
          readOnly = true;
          options = ["ro"];
        };
        JANUS_NIX = {
          size = null;
          fsType = "f2fs";
          mountPoint = "/nix";
          readOnly = true;
          options = ["ro"];
          slack = "15%";
        };
        JANUS_STATE = {
          size = null;
          fsType = "f2fs";
          mountPoint = "/var";
          readOnly = false;
          options = ["rw" "noatime" "lazytime" "background_gc=on" "discard"];
        };
      };
      description = "One partition per filesystem. docs/05 §2 and §8.";
    };
    readOnlyFs = mkOption {
      type = types.enum ["f2fs" "erofs" "squashfs"];
      default = "f2fs";
      description = "Filesystem for the read-only partitions. The builder populates f2fs.";
    };
    state.minimumSize = mkOption {
      type = types.str;
      default = "512M";
      description = "Minimum size of the state partition. The image uses this size; janus-grow-state expands it on larger media.";
    };
    state.onCorruption = mkOption {
      type = types.enum ["reformat" "halt"];
      default = "reformat";
      description = "What initrd does when the state filesystem cannot be repaired.";
    };
    firmwareOffsetMiB = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = "Mebibytes reserved before the boot partition, after the leading 1 MiB. Firmware written in raw sectors leaves this gap unpartitioned. A bootloader that keeps a boot stage of its own uses the gap as an extra unformatted partition.";
    };
  };

  config = {
    assertions = [
      {
        assertion = (mounted "/" != []) && lib.all (p: p.readOnly) (mounted "/");
        message = "janus.storage: / must be mounted read-only (FR-STO-001).";
      }
      {
        assertion = (mounted "/nix" != []) && lib.all (p: p.readOnly) (mounted "/nix");
        message = "janus.storage: /nix must be mounted read-only (FR-STO-001).";
      }
      {
        assertion = lib.length (lib.filter (p: p.mountPoint == "/var" && !p.readOnly) parts) == 1;
        message = "janus.storage: exactly one read-write partition must mount /var (FR-STO-004).";
      }
      {
        assertion = cfg.readOnlyFs == "f2fs";
        message = "janus.storage.readOnlyFs: the image builder populates f2fs and FAT (docs/09 §6).";
      }
      {
        assertion = lib.all (p: p.fsType == "f2fs" || p.fsType == "vfat") parts;
        message = "janus.storage: the image builder writes f2fs and FAT only.";
      }
    ];

    fileSystems = lib.mkMerge [
      (lib.mapAttrs' (
          label: p: {
            name = p.mountPoint;
            value = {
              device = "/dev/disk/by-label/${label}";
              fsType = p.fsType;
              options = p.options;
              neededForBoot = true;
            };
          }
        )
        cfg.layout.partitions)
      {
        "/tmp" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = ["nosuid" "nodev" "size=64M"];
        };
        "/home" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = ["nosuid" "nodev"];
        };
      }
    ];

    # Store-generated /etc, immutable lower dir. Persistent files are bind-mounted
    # from the state partition by janus-persist-etc.
    system.etc.overlay.enable = true;
    system.etc.overlay.mutable = false;
    boot.initrd.systemd.enable = true;
    systemd.sysusers.enable = true;
    boot.initrd.supportedFilesystems = ["f2fs" "vfat"];
    boot.initrd.availableKernelModules = ["f2fs" "vfat" "nls_cp437" "nls_iso8859_1"];

    # Compilers and dev headers, not the runtime libgcc/libstdc++ that systemd needs.
    system.forbiddenDependenciesRegexes = [
      "-gcc-[0-9][.0-9]*$"
      "-gcc-wrapper-"
      "-binutils-[0-9][.0-9]*$"
      "-binutils-wrapper-"
      "-glibc-dev-"
      "-cmake-[0-9]"
      "-meson-[0-9]"
      "-janus-build-"
    ];

    # Empty regular file so the bind mount has a target on the immutable /etc.
    environment.etc."machine-id".text = "";

    # Grow the partition table before fsck. A failure here must not reformat.
    boot.initrd.systemd.services.janus-grow-state = {
      description = "Grow the state partition to the end of the disk";
      requiredBy = ["janus-state-recover.service"];
      before = ["janus-state-recover.service" "local-fs-pre.target"];
      after = ["systemd-udev-trigger.service"];
      unitConfig.DefaultDependencies = false;
      path = [pkgs.gptfdisk pkgs.util-linux pkgs.coreutils];
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        dev=/dev/disk/by-partuuid/${statePartUuid}
        for _ in $(seq 1 50); do
          [ -b "$dev" ] && break
          sleep 0.1
        done
        if [ ! -b "$dev" ]; then
          echo "<3>janus: JANUS_STATE did not appear" > /dev/kmsg
          exit 1
        fi
        part=$(readlink -f "$dev")
        parent=$part
        while [ "''${parent%[0-9]}" != "$parent" ]; do
          parent="''${parent%[0-9]}"
        done
        partNum="''${part#"$parent"}"
        if [ "''${parent%[0-9]p}" != "$parent" ] && [ -b "''${parent%p}" ]; then
          parent="''${parent%p}"
        fi
        # The image places the backup GPT at the end of the file. A larger
        # disk needs that header moved before the last partition can grow.
        sgdisk -e "$parent"
        start=""
        end=""
        while read -r line; do
          case "$line" in
            "First sector:"*)
              set -- $line
              start=$3
              ;;
            "Last sector:"*)
              set -- $line
              end=$3
              ;;
          esac
        done < <(sgdisk -i "$partNum" "$parent")
        last=""
        while read -r line; do
          case "$line" in
            *"last usable sector is"*) last="''${line##* }" ;;
          esac
        done < <(sgdisk --print "$parent")
        if [ -z "$start" ] || [ -z "$end" ] || [ -z "$last" ]; then
          echo "<3>janus: cannot read the state partition table" > /dev/kmsg
          exit 1
        fi
        # One megabyte is the backup header the image already reserved.
        if [ $((last - end)) -le 2048 ]; then
          exit 0
        fi
        sgdisk \
          -d "$partNum" \
          -n "''${partNum}:''${start}:0" \
          -c "''${partNum}:JANUS_STATE" \
          -t "''${partNum}:8300" \
          -u "''${partNum}:4a414e55-5300-4000-8000-000000000004" \
          "$parent"
        partx -u "$parent"
      '';
    };

    boot.initrd.systemd.services.janus-state-recover = {
      description = "Repair or reformat the Janus state partition";
      requiredBy = ["local-fs-pre.target"];
      before = ["local-fs-pre.target"];
      after = ["janus-grow-state.service" "systemd-udev-trigger.service"];
      unitConfig.DefaultDependencies = false;
      path = [pkgs.f2fs-tools pkgs.util-linux pkgs.kmod pkgs.coreutils];
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        dev=/dev/disk/by-partuuid/${statePartUuid}
        for _ in $(seq 1 50); do
          [ -b "$dev" ] && break
          sleep 0.1
        done
        if [ ! -b "$dev" ]; then
          echo "<3>janus: JANUS_STATE did not appear" > /dev/kmsg
          exit 1
        fi
        set +e
        timeout 30 fsck.f2fs -a "$dev"
        fsck_status=$?
        set -e
        # 126/127 means the tool did not run. 0 is clean, 1 corrected,
        # 2 reboot requested, 3 both. 8 is an operational error: fsck did
        # not finish, and a grown partition has returned this while the
        # filesystem was still mountable. Those statuses are decided by a
        # mount. 4 is uncorrected and 255 is a missing superblock. Mounting
        # those can sit in the kernel, so they follow the corruption policy
        # without a mount.
        if [ "$fsck_status" -eq 126 ] || [ "$fsck_status" -eq 127 ]; then
          echo "<3>janus: fsck.f2fs did not run ($fsck_status)" > /dev/kmsg
          exit 1
        fi
        action=mount
        case "$fsck_status" in
          4|255) action=broken ;;
        esac
        mount_status=1
        if [ "$action" = mount ]; then
          modprobe f2fs || true
          probe=/run/janus-state-probe
          mkdir -p "$probe"
          set +e
          timeout 20 mount -t f2fs -o ro "$dev" "$probe"
          mount_status=$?
          set -e
          if mountpoint -q "$probe"; then
            umount "$probe" || umount -l "$probe"
          fi
        fi
        if [ "$mount_status" != 0 ]; then
          if [ ${cfg.state.onCorruption} = reformat ]; then
            echo "<3>janus: reformatting JANUS_STATE" > /dev/kmsg
            mkfs.f2fs -f -l JANUS_STATE "$dev"
            part=$(readlink -f "$dev")
            echo change > "/sys/class/block/''${part##*/}/uevent" || true
            label=/dev/disk/by-label/JANUS_STATE
            for _ in $(seq 1 50); do
              [ -e "$label" ] && break
              sleep 0.1
            done
            if [ ! -e "$label" ]; then
              echo "<3>janus: JANUS_STATE label did not appear after reformat" > /dev/kmsg
              exit 1
            fi
          else
            echo "<3>janus: JANUS_STATE failed to mount and janus.storage.state.onCorruption is halt" > /dev/kmsg
            exit 1
          fi
        fi
        resize.f2fs "$dev"
      '';
    };

    systemd.services.janus-seed = {
      description = "Create the Janus state tree and record the embedded seed";
      wantedBy = ["multi-user.target"];
      after = ["var.mount" "local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        install -d -m 0755 \
          /var/lib/janus/etc \
          /var/lib/janus/etc/ssh \
          /var/lib/janus/root \
          /var/lib/janus/secrets \
          /var/lib/janus/subscriptions \
          /var/lib/janus/geodata \
          /var/lib/janus/engine \
          /var/lib/janus/leases \
          /var/lib/janus/monitoring \
          /var/lib/janus/hmi
        embedded_hash=$(cat ${janusSeed}/seed.hash)
        embedded_gen=$(cat ${janusSeed}/seed.generation)
        stamp=/var/lib/janus/seed.stamp
        apply=0
        if [ ! -f "$stamp" ] || ! grep -qxE '[0-9a-f]{64} [0-9]+' "$stamp"; then
          apply=1
        else
          read -r local_hash local_gen < "$stamp"
          if [ "$local_hash" != "$embedded_hash" ] && [ "$embedded_gen" -gt "$local_gen" ]; then
            apply=1
          fi
        fi
        if [ "$apply" = 1 ]; then
          cp -a ${janusSeed}/subscriptions/. /var/lib/janus/subscriptions/
          cp -a ${janusSeed}/geodata/. /var/lib/janus/geodata/
          cp -a ${janusSeed}/engine/. /var/lib/janus/engine/
          cp -a ${janusSeed}/manifest.json /var/lib/janus/manifest.json
          printf '%s %s\n' "$embedded_hash" "$embedded_gen" > "$stamp"
        fi
      '';
    };

    systemd.services.janus-persist-etc = {
      description = "Bind machine-id from the state partition";
      wantedBy = ["sysinit.target"];
      before = ["sysinit.target" "systemd-machine-id-commit.service"];
      after = ["var.mount"];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [pkgs.coreutils pkgs.util-linux pkgs.systemd];
      script = ''
        set -eu
        install -d -m 0755 /var/lib/janus/etc /var/lib/janus/etc/ssh
        if [ ! -s /var/lib/janus/etc/machine-id ]; then
          systemd-machine-id-setup --print > /var/lib/janus/etc/machine-id
        fi
        if [ ! -e /etc/machine-id ]; then
          echo "janus: /etc/machine-id is missing from the immutable etc image" >&2
          exit 1
        fi
        if ! mountpoint -q /etc/machine-id; then
          mount --bind /var/lib/janus/etc/machine-id /etc/machine-id
        fi
      '';
    };

    system.build.janusSeed = janusSeed;
    system.build.janusNixPartition = janusNixPartition;

    system.build.janusBoardImage = lib.mkDefault {};

    system.build.janusImage = let
      boardImage = config.system.build.janusBoardImage;
    in
      (pkgs.callPackage ../../../pkgs/image.nix {}) {
        hostName = config.janus.system.hostName;
        toplevel = config.system.build.toplevel;
        closureInfo = pkgs.closureInfo {rootPaths = [config.system.build.toplevel];};
        buildJson = config.environment.etc."janus/build.json".source;
        firmwareOffsetMiB = cfg.firmwareOffsetMiB;
        bootMiB = sizeMiB (cfg.layout.partitions.JANUS_BOOT.size or "256M");
        rootMinMiB = sizeMiB (cfg.layout.partitions.JANUS_ROOT.size or "64M");
        stateMiB = sizeMiB (
          if cfg.layout.partitions.JANUS_STATE.size == null
          then cfg.state.minimumSize
          else cfg.layout.partitions.JANUS_STATE.size
        );
        nixSlackPercent = slackPercent cfg.layout.partitions.JANUS_NIX.slack;
        nixSizeMode = janusNixPartition.mode;
        nixExactMiB =
          if janusNixPartition.exactMiB == null
          then "0"
          else toString janusNixPartition.exactMiB;
        bootLabel = "JANUS_BOOT";
        rootLabel = "JANUS_ROOT";
        nixLabel = "JANUS_NIX";
        stateLabel = "JANUS_STATE";
        bootExtra = boardImage.bootExtra or "";
        firmwareInstall = boardImage.firmwareInstall or "";
        dtbName = boardImage.dtbName or null;
        dtbSource = boardImage.dtbSource or null;
        limineBios = boardImage.limineBios or false;
      };
  };
}
