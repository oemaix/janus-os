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
  rootPartUuid = "4a414e55-5300-4000-8000-000000000002";
  nixPartUuid = "4a414e55-5300-4000-8000-000000000003";
  # 000000000005 is the Limine BIOS gap. Slot B uses the next two.
  rootBPartUuid = "4a414e55-5300-4000-8000-000000000006";
  nixBPartUuid = "4a414e55-5300-4000-8000-000000000007";
  # systemd follows a /dev mount with the device unit of that path, and
  # activates the unit only for a symlink udev created. /nix keeps that
  # dependency after switch-root, so both udev copies need the same links.
  slotLinkRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", IMPORT{cmdline}="janus.slot"
    ACTION=="add|change", SUBSYSTEM=="block", ENV{janus.slot}!="b", ENV{ID_PART_ENTRY_UUID}=="${rootPartUuid}", SYMLINK+="disk/by-janus/root"
    ACTION=="add|change", SUBSYSTEM=="block", ENV{janus.slot}!="b", ENV{ID_PART_ENTRY_UUID}=="${nixPartUuid}", SYMLINK+="disk/by-janus/nix"
    ACTION=="add|change", SUBSYSTEM=="block", ENV{janus.slot}=="b", ENV{ID_PART_ENTRY_UUID}=="${rootBPartUuid}", SYMLINK+="disk/by-janus/root"
    ACTION=="add|change", SUBSYSTEM=="block", ENV{janus.slot}=="b", ENV{ID_PART_ENTRY_UUID}=="${nixBPartUuid}", SYMLINK+="disk/by-janus/nix"
  '';

  sizeMiB = s: let
    m = builtins.match "([0-9]+)(\\.[0-9]+)?([KMGT]i?B?)" s;
    n =
      if m == null
      then null
      else lib.toInt (lib.elemAt m 0);
    frac =
      if m == null || lib.elemAt m 1 == null
      then ""
      else lib.removePrefix "." (lib.elemAt m 1);
    unit =
      if m == null
      then ""
      else lib.elemAt m 2;
    scale =
      if lib.hasPrefix "G" unit
      then 1024
      else if lib.hasPrefix "M" unit
      then 1
      else null;
    denom = lib.foldl' (acc: _: acc * 10) 1 (lib.stringToCharacters frac);
    numer =
      if frac == "" || scale == null
      then 0
      else lib.toInt frac * scale;
    quot = numer / denom;
    # A fractional size rounds up, so the partition is never short of the request.
    extra =
      if frac == "" || scale == null
      then 0
      else if numer == quot * denom
      then quot
      else quot + 1;
  in
    if m == null || scale == null
    then throw "janus.storage size '${s}' is not a number of MiB or GiB (for example 256M, 1G, or 2.5G)."
    else n * scale + extra;

  slackPercent = s: let
    m = builtins.match "([0-9]+)%" s;
  in
    if m == null
    then throw "janus.storage slack '${s}' is not a percentage such as 15%."
    else lib.toInt (lib.elemAt m 0);

  # 512-byte sectors, the same unit sgdisk uses for the 1 MiB backup gap.
  stateMaxSectors = sizeMiB cfg.state.maximumSize * 2048;

  waitForState = ''
    dev=/dev/disk/by-partuuid/${statePartUuid}
    for _ in $(seq 1 50); do
      [ -b "$dev" ] && break
      sleep 0.1
    done
    if [ ! -b "$dev" ]; then
      echo "<3>janus: JANUS_STATE did not appear" > /dev/kmsg
      exit 1
    fi
  '';

  reformatState = ''
    echo "<3>janus: reformatting JANUS_STATE" > /dev/kmsg
    mkdir -p /run/janus
    echo reformatted > /run/janus/state-reformatted
    rm -f /run/janus/full-fsck
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
  '';

  # /run is moved across switch-root, so the note reaches the real journal.
  corruptState = ''
    if [ ${cfg.state.onCorruption} = reformat ]; then
      ${reformatState}
    else
      echo "<3>janus: JANUS_STATE failed to mount and janus.storage.state.onCorruption is halt" > /dev/kmsg
      exit 1
    fi
  '';

  partition = types.submodule {
    options = {
      size = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "256M";
        description = "Partition size, such as 256M or 1G. Null sizes the Nix partition from the closure plus slack, and at least nix.minimumSize. A set Nix size is used as given, even when it is below nix.minimumSize. A set state size replaces state.minimumSize. It does not change state.maximumSize.";
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
    {
      minimumMiB = sizeMiB cfg.nix.minimumSize;
    }
    // (
      if cfg.layout.partitions.JANUS_NIX.size == null
      then {
        mode = "auto";
        exactMiB = null;
      }
      else {
        mode = "exact";
        exactMiB = sizeMiB cfg.layout.partitions.JANUS_NIX.size;
      }
    );

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

  # Le Potato: the FIP owns LBA 1, so grow must not let sgdisk rewrite it.
  amlogicSd = config.system.build.janusBoardImage.amlogicSd or false;
  gptFix = pkgs.callPackage ../../../pkgs/janus-gpt-fix.nix {};
  hintLba = (1 + cfg.firmwareOffsetMiB) * 2048 - 1;
  partUuidRule = ''
    ACTION=="add|change", SUBSYSTEM=="block", ENV{PARTUUID}=="?*", SYMLINK+="disk/by-partuuid/$env{PARTUUID}"
  '';
  amlogicGrow = ''
    set -eu
    dev=/dev/disk/by-partuuid/${statePartUuid}
    boot=/dev/disk/by-label/JANUS_BOOT
    found=""
    for _ in $(seq 1 50); do
      if [ -b "$dev" ]; then
        found=$dev
        break
      fi
      if [ -b "$boot" ]; then
        found=$boot
        break
      fi
      sleep 0.1
    done
    if [ -z "$found" ]; then
      echo "<3>janus: JANUS_STATE did not appear" > /dev/kmsg
      exit 1
    fi
    part=$(readlink -f "$found")
    parent=$part
    while [ "''${parent%[0-9]}" != "$parent" ]; do
      parent="''${parent%[0-9]}"
    done
    if [ "''${parent%[0-9]p}" != "$parent" ] && [ -b "''${parent%p}" ]; then
      parent="''${parent%p}"
    fi
    # The image's backup GPT sits at the end of the file. A larger card
    # needs it at the end of the card before the kernel can use it. The
    # tool does not write LBA 1, which is the Amlogic FIP.
    publish_state() {
      updated=0
      for _ in $(seq 1 10); do
        if partx -u "$parent"; then
          updated=1
          break
        fi
        sleep 0.2
      done
      if [ "$updated" -ne 1 ]; then
        echo "<4>janus: partx did not update the disk" > /dev/kmsg
      fi
      settled=0
      for _ in 1 2; do
        if "${config.boot.initrd.systemd.package}/bin/udevadm" settle --timeout=10; then
          settled=1
          break
        fi
      done
      need=2
      if [ "$settled" -ne 1 ]; then
        echo "<4>janus: udev queue did not settle after the partition reread" > /dev/kmsg
        need=5
      fi
      seen=0
      stable=0
      for _ in $(seq 1 50); do
        if [ -b "$dev" ]; then
          seen=$((seen + 1))
          if [ "$seen" -ge "$need" ]; then
            stable=1
            break
          fi
          sleep 0.2
        else
          seen=0
          sleep 0.1
        fi
      done
      if [ "$stable" -ne 1 ]; then
        echo "<3>janus: JANUS_STATE did not return after the partition reread" > /dev/kmsg
        exit 1
      fi
    }
    ${gptFix}/bin/janus-gpt-fix relocate "$parent" ${toString hintLba}
    publish_state
    info=$(${gptFix}/bin/janus-gpt-fix show "$parent" ${toString hintLba} ${statePartUuid})
    start=''${info#*start=}
    start=''${start%%$'\n'*}
    end=''${info#*end=}
    end=''${end%%$'\n'*}
    last=''${info#*last=}
    last=''${last%%$'\n'*}
    if [ -z "$start" ] || [ -z "$end" ] || [ -z "$last" ]; then
      echo "<3>janus: cannot read the state partition table" > /dev/kmsg
      exit 1
    fi
    max_sectors=${toString stateMaxSectors}
    if [ $((end - start + 1)) -ge "$max_sectors" ]; then
      exit 0
    fi
    if [ $((last - end)) -le 2048 ]; then
      exit 0
    fi
    want=$((start + max_sectors - 1))
    if [ "$want" -gt "$last" ]; then
      want=$last
    fi
    if [ "$want" -le "$end" ]; then
      exit 0
    fi
    ${gptFix}/bin/janus-gpt-fix set-end "$parent" ${toString hintLba} ${statePartUuid} "$want"
    publish_state
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
      description = "Filesystem for the read-only partitions. f2fs is implemented. erofs and squashfs are reserved and fail evaluation (D-0035).";
    };
    nix.minimumSize = mkOption {
      type = types.str;
      default = "2.5G";
      description = "Floor for each Nix partition when JANUS_NIX.size is null. The built size is the closure plus 15%, one 4 KiB node block per file, and 128 MiB, and at least this floor. JANUS_NIX.size may be smaller and is then used as given. With slots, both Nix partitions use the same size.";
    };
    state.minimumSize = mkOption {
      type = types.str;
      default = "512M";
      description = "Size of the state partition in the image. janus-grow-state expands it on larger media, up to state.maximumSize.";
    };
    state.maximumSize = mkOption {
      type = types.str;
      default = "4G";
      example = "8G";
      description = "Largest size janus-grow-state will give the state partition. Growth also stops at the end of the media. A cap below the flashed size does not shrink the partition. A larger or smaller size is accepted.";
    };
    state.onCorruption = mkOption {
      type = types.enum ["reformat" "halt"];
      default = "reformat";
      description = "What initrd does when the state filesystem cannot be repaired. A slow check or a missing block device is not corruption.";
    };
    firmwareOffsetMiB = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = "Mebibytes reserved before the boot partition, after the leading 1 MiB. Firmware written in raw sectors leaves this gap unpartitioned. A bootloader that keeps a boot stage of its own uses the gap as an extra unformatted partition.";
    };
    slots.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Duplicate ROOT and NIX. janus-build deploy writes the inactive slot, then the boot entry toggles. docs/09 §8.4.";
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
        message = "janus.storage.readOnlyFs: the image builder populates f2fs and FAT. erofs and squashfs are reserved (D-0035, docs/05 §9).";
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
      (mkIf cfg.slots.enable {
        "/" = {
          device = lib.mkForce "/dev/disk/by-janus/root";
        };
        "/nix" = {
          device = lib.mkForce "/dev/disk/by-janus/nix";
        };
      })
    ];

    # Store-generated /etc, immutable lower dir. Persistent files are bind-mounted
    # from the state partition by janus-persist-etc.
    system.etc.overlay.enable = true;
    system.etc.overlay.mutable = false;
    boot.initrd.systemd.enable = true;
    systemd.sysusers.enable = true;
    boot.initrd.supportedFilesystems = ["f2fs" "vfat"];
    boot.initrd.availableKernelModules = ["f2fs" "vfat" "nls_cp437" "nls_iso8859_1"];

    boot.initrd.services.udev.rules = mkIf (cfg.slots.enable || amlogicSd) (
      lib.optionalString cfg.slots.enable slotLinkRules
      + lib.optionalString amlogicSd partUuidRule
    );
    services.udev.extraRules = mkIf (cfg.slots.enable || amlogicSd) (
      lib.optionalString cfg.slots.enable slotLinkRules
      + lib.optionalString amlogicSd partUuidRule
    );

    environment.etc."janus/slots.json" = mkIf cfg.slots.enable {
      text = builtins.toJSON {
        enable = true;
        rootA = rootPartUuid;
        nixA = nixPartUuid;
        rootB = rootBPartUuid;
        nixB = nixBPartUuid;
      };
    };

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

    # Grow the partition table before fsck. A failure here must not reformat
    # and must not stop janus-state-recover: that unit only wants this one.
    boot.initrd.systemd.services.janus-grow-state = {
      description = "Grow the state partition up to its configured cap";
      wantedBy = ["janus-state-recover.service"];
      before = ["janus-state-recover.service" "local-fs-pre.target"];
      after = ["systemd-udev-trigger.service"];
      unitConfig.DefaultDependencies = false;
      path =
        if amlogicSd
        then [gptFix pkgs.util-linux pkgs.coreutils]
        else [pkgs.gptfdisk pkgs.util-linux pkgs.coreutils];
      serviceConfig.Type = "oneshot";
      script =
        if amlogicSd
        then amlogicGrow
        else ''
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
          # sgdisk -e also makes the kernel drop partition devices while it
          # rereads the table. partx publishes them again before any exit,
          # including the boots that do not change the partition size.
          # Recover must not run in that gap.
          publish_state() {
            updated=0
            for _ in $(seq 1 10); do
              if partx -u "$parent"; then
                updated=1
                break
              fi
              sleep 0.2
            done
            # A busy neighbor can make partx fail after the kernel already
            # has the state node. That must not fail this unit: recover
            # would then be the only fsck, and it still has to run.
            if [ "$updated" -ne 1 ]; then
              echo "<4>janus: partx did not update the disk" > /dev/kmsg
            fi
            settled=0
            for _ in 1 2; do
              if "${config.boot.initrd.systemd.package}/bin/udevadm" settle --timeout=10; then
                settled=1
                break
              fi
            done
            # After a drained queue, two sightings are enough. When settle
            # did not finish, require a longer run of sightings so the old
            # node, which udev is about to remove, does not count.
            need=2
            if [ "$settled" -ne 1 ]; then
              echo "<4>janus: udev queue did not settle after the partition reread" > /dev/kmsg
              need=5
            fi
            seen=0
            stable=0
            for _ in $(seq 1 50); do
              if [ -b "$dev" ]; then
                seen=$((seen + 1))
                if [ "$seen" -ge "$need" ]; then
                  stable=1
                  break
                fi
                sleep 0.2
              else
                seen=0
                sleep 0.1
              fi
            done
            if [ "$stable" -ne 1 ]; then
              echo "<3>janus: JANUS_STATE did not return after the partition reread" > /dev/kmsg
              exit 1
            fi
          }
          sgdisk -e "$parent"
          publish_state
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
          # max_sectors is state.maximumSize. A smaller cap does not shrink.
          max_sectors=${toString stateMaxSectors}
          if [ $((end - start + 1)) -ge "$max_sectors" ]; then
            exit 0
          fi
          if [ $((last - end)) -le 2048 ]; then
            exit 0
          fi
          want=$((start + max_sectors - 1))
          if [ "$want" -gt "$last" ]; then
            want=$last
          fi
          if [ "$want" -le "$end" ]; then
            exit 0
          fi
          sgdisk \
            -d "$partNum" \
            -n "''${partNum}:''${start}:''${want}" \
            -c "''${partNum}:JANUS_STATE" \
            -t "''${partNum}:8300" \
            -u "''${partNum}:4a414e55-5300-4000-8000-000000000004" \
            "$parent"
          publish_state
        '';
    };

    # -a repairs a checkpoint the kernel marked bad. It does not scan the
    # volume. --no-kernel-check skips the 30-day full scan inside fsck.f2fs.
    # 15 min bounds a stuck card. A full check has its own unit and no cap.
    boot.initrd.systemd.services.janus-state-recover = {
      description = "Repair or reformat the Janus state partition";
      requiredBy = ["local-fs-pre.target"];
      before = ["local-fs-pre.target" "janus-state-fsck-full.service"];
      after = ["janus-grow-state.service" "systemd-udev-trigger.service"];
      unitConfig.DefaultDependencies = false;
      path = [pkgs.f2fs-tools pkgs.util-linux pkgs.kmod pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "15min";
      };
      script = ''
        set -eu
        ${waitForState}
        run_fsck() {
          set +e
          fsck.f2fs -a --no-kernel-check "$dev"
          fsck_status=$?
          set -e
        }
        # The node can disappear while the kernel rereads the partition
        # table. The fsck or mount that hit that gap did not see the
        # filesystem, so it must not select the corruption policy.
        wait_state_back() {
          echo "<4>janus: JANUS_STATE block device disappeared; waiting" > /dev/kmsg
          for _ in $(seq 1 50); do
            [ -b "$dev" ] && return 0
            sleep 0.1
          done
          echo "<3>janus: JANUS_STATE did not return; not reformatting" > /dev/kmsg
          exit 1
        }
        run_fsck
        # 126/127 means the tool did not run. 0 is clean, 1 corrected,
        # 2 reboot requested, 3 both. 8 is an operational error: fsck did
        # not finish, and the filesystem may still mount. 4 is uncorrected
        # and 255 is a missing superblock. Mounting those can sit in the
        # kernel, so they follow the corruption policy without a mount.
        # 4 and 255 are repeated once the node is present. One miss while
        # the kernel is rereading the table is not a verdict.
        if [ "$fsck_status" -eq 126 ] || [ "$fsck_status" -eq 127 ]; then
          echo "<3>janus: fsck.f2fs did not run ($fsck_status)" > /dev/kmsg
          exit 1
        fi
        if [ "$fsck_status" -eq 4 ] || [ "$fsck_status" -eq 255 ] || [ ! -b "$dev" ]; then
          if [ ! -b "$dev" ]; then
            wait_state_back
          fi
          run_fsck
          if [ "$fsck_status" -eq 126 ] || [ "$fsck_status" -eq 127 ]; then
            echo "<3>janus: fsck.f2fs did not run ($fsck_status)" > /dev/kmsg
            exit 1
          fi
        fi
        if [ ! -b "$dev" ]; then
          echo "<3>janus: JANUS_STATE is not a block device; not reformatting" > /dev/kmsg
          exit 1
        fi
        action=mount
        case "$fsck_status" in
          4|255) action=broken ;;
        esac
        mount_status=1
        probe_once() {
          mount_status=1
          mounted=0
          set +e
          mount -t f2fs -o ro "$dev" "$probe"
          mount_status=$?
          set -e
          if mountpoint -q "$probe"; then
            mounted=1
            if [ -e "$probe/lib/janus/full-fsck" ]; then
              mkdir -p /run/janus
              : > /run/janus/full-fsck
              echo "<6>janus: full fsck of JANUS_STATE requested" > /dev/kmsg
            fi
            umount "$probe" || umount -l "$probe"
          fi
          if mountpoint -q "$probe"; then
            echo "<3>janus: JANUS_STATE stayed mounted after the probe" > /dev/kmsg
            exit 1
          fi
          if [ "$mounted" -eq 1 ]; then
            mount_status=0
          fi
        }
        if [ "$action" = mount ]; then
          modprobe f2fs || true
          probe=/run/janus-state-probe
          mkdir -p "$probe"
          probe_once
          # One repeat. A node that returned between the two calls can
          # fail the first mount and accept the second. A second failure
          # with the node present is the corruption policy.
          if [ "$mount_status" != 0 ]; then
            if [ ! -b "$dev" ]; then
              wait_state_back
            fi
            probe_once
          fi
        fi
        if [ "$mount_status" != 0 ]; then
          if [ ! -b "$dev" ]; then
            echo "<3>janus: JANUS_STATE is not a block device; not reformatting" > /dev/kmsg
            exit 1
          fi
          ${corruptState}
        fi
        resize.f2fs "$dev"
      '';
    };

    # Runs only when recover copied /var/lib/janus/full-fsck into /run.
    # The on-disk request is removed before fsck -f, so a hang is not repeated.
    # No start timeout: a full check of a large volume is allowed to finish.
    boot.initrd.systemd.services.janus-state-fsck-full = {
      description = "Full check of the Janus state partition";
      requiredBy = ["local-fs-pre.target"];
      before = ["local-fs-pre.target"];
      after = ["janus-state-recover.service"];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "/run/janus/full-fsck";
      };
      path = [pkgs.f2fs-tools pkgs.util-linux pkgs.kmod pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
      };
      script = ''
        set -eu
        ${waitForState}
        # The node can disappear while the kernel rereads the partition
        # table. Coming back is not corruption. Staying away fails the
        # unit without mkfs.
        wait_state_back() {
          echo "<4>janus: JANUS_STATE block device disappeared; waiting" > /dev/kmsg
          for _ in $(seq 1 50); do
            [ -b "$dev" ] && return 0
            sleep 0.1
          done
          echo "<3>janus: JANUS_STATE did not return; not reformatting" > /dev/kmsg
          exit 1
        }
        probe_rw() {
          mount_status=1
          mounted=0
          set +e
          mount -t f2fs -o rw "$dev" "$probe"
          mount_status=$?
          set -e
          if mountpoint -q "$probe"; then
            mounted=1
            rm -f "$probe/lib/janus/full-fsck"
            umount "$probe" || umount -l "$probe"
          fi
          if mountpoint -q "$probe"; then
            echo "<3>janus: JANUS_STATE stayed mounted" > /dev/kmsg
            exit 1
          fi
          if [ "$mounted" -eq 1 ]; then
            mount_status=0
          fi
        }
        # Drop the on-disk request before the long check. This boot still
        # runs because /run/janus/full-fsck is already set. A hang or a power
        # cut then comes up as a normal boot.
        modprobe f2fs || true
        probe=/run/janus-state-probe
        mkdir -p "$probe"
        probe_rw
        if [ "$mount_status" != 0 ] && [ ! -b "$dev" ]; then
          wait_state_back
          probe_rw
        fi
        set +e
        fsck.f2fs -f "$dev"
        fsck_status=$?
        set -e
        if [ "$fsck_status" -eq 126 ] || [ "$fsck_status" -eq 127 ]; then
          echo "<3>janus: fsck.f2fs -f did not run ($fsck_status)" > /dev/kmsg
          exit 1
        fi
        # Same rule as the boot check: 4 or 255 is repeated once the node
        # is present. A second 4 or 255 is the corruption policy.
        if [ "$fsck_status" -eq 4 ] || [ "$fsck_status" -eq 255 ] || [ ! -b "$dev" ]; then
          if [ ! -b "$dev" ]; then
            wait_state_back
          fi
          set +e
          fsck.f2fs -f "$dev"
          fsck_status=$?
          set -e
          if [ "$fsck_status" -eq 126 ] || [ "$fsck_status" -eq 127 ]; then
            echo "<3>janus: fsck.f2fs -f did not run ($fsck_status)" > /dev/kmsg
            exit 1
          fi
        fi
        if [ ! -b "$dev" ]; then
          echo "<3>janus: JANUS_STATE is not a block device; not reformatting" > /dev/kmsg
          exit 1
        fi
        case "$fsck_status" in
          4|255)
            ${corruptState}
            ;;
          *)
            probe_rw
            if [ "$mount_status" != 0 ]; then
              if [ ! -b "$dev" ]; then
                wait_state_back
              fi
              probe_rw
            fi
            if [ "$mount_status" != 0 ]; then
              if [ ! -b "$dev" ]; then
                echo "<3>janus: JANUS_STATE is not a block device; not reformatting" > /dev/kmsg
                exit 1
              fi
              ${corruptState}
            else
              rm -f /run/janus/full-fsck
              echo "<6>janus: full fsck of JANUS_STATE finished ($fsck_status)" > /dev/kmsg
            fi
            ;;
        esac
      '';
    };

    systemd.services.janus-state-reformat-log = {
      description = "Record a state-partition reformat in the journal";
      wantedBy = ["multi-user.target"];
      after = ["systemd-journald.service" "var.mount"];
      serviceConfig.Type = "oneshot";
      script = ''
        if [ -f /run/janus/state-reformatted ]; then
          echo "janus: reformatted JANUS_STATE during boot" >&2
        fi
      '';
    };

    # Ordered before the maintenance reboot. The reboot service itself stays
    # in janus.system and only reboots.
    systemd.services.janus-reboot-fsck = mkIf config.janus.system.reboot.fsck {
      description = "Request a full state check on the maintenance reboot";
      requiredBy = ["janus-reboot.service"];
      before = ["janus-reboot.service"];
      path = [pkgs.coreutils];
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        install -d -m 0755 /var/lib/janus
        : > /var/lib/janus/full-fsck
        sync
      '';
    };

    systemd.services.janus-seed = {
      description = "Create the Janus state tree and record the embedded seed";
      wantedBy = ["multi-user.target"];
      after = ["var.mount" "local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus";
      };
      script = ''
        set -eu
        # tmpfiles creates /var/lib/janus/root at 0700. ProtectHome follows
        # the /root symlink onto that directory, so this sandbox cannot chmod it.
        install -d -m 0755 \
          /var/lib/janus/etc \
          /var/lib/janus/etc/ssh \
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
        nixMinMiB = sizeMiB cfg.nix.minimumSize;
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
        hybridFatMbr = boardImage.hybridFatMbr or false;
        amlogicSd = boardImage.amlogicSd or false;
        gptFix =
          if boardImage.amlogicSd or false
          then pkgs.buildPackages.callPackage ../../../pkgs/janus-gpt-fix.nix {}
          else null;
        slots = cfg.slots.enable;
      };

    system.build.janusSlotImages = mkIf cfg.slots.enable (
      (pkgs.callPackage ../../../pkgs/slot-images.nix {}) {
        toplevel = config.system.build.toplevel;
        closureInfo = pkgs.closureInfo {rootPaths = [config.system.build.toplevel];};
        rootMinMiB = sizeMiB (cfg.layout.partitions.JANUS_ROOT.size or "64M");
        nixSlackPercent = slackPercent cfg.layout.partitions.JANUS_NIX.slack;
        nixMinMiB = sizeMiB cfg.nix.minimumSize;
        nixSizeMode = janusNixPartition.mode;
        nixExactMiB =
          if janusNixPartition.exactMiB == null
          then "0"
          else toString janusNixPartition.exactMiB;
      }
    );
  };
}
