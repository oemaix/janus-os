# SPDX-License-Identifier: Apache-2.0
# Compact kernel config, merged by generate-config.pl. The eval check only
# reads the Nix list. This one builds the .config for every board system.
# Cross keeps aarch64, armv7, and riscv on the x86_64 build host.
{
  pkgs,
  self,
}: let
  key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-eval";
  mk = board:
    self.lib.mkRouter {
      modules = [
        {
          janus.hardware.board = board;
          janus.access.ssh.authorizedKeys = [key];
          janus.system.kernelProfile = "compact";
          janus.build.strategy = "cross";
        }
      ];
      buildSystem = "x86_64-linux";
      source = self;
      configRevision = self.rev or "unknown";
      name = "kernel-config";
    };
  configOf = board: (mk board).config.boot.kernelPackages.kernel.configfile;
in
  pkgs.runCommand "eval-kernel-config" {
    x86 = configOf "x86_64-test";
    arm64 = configOf "nanopi-r4s";
    armv7 = configOf "rpi2";
    riscv = configOf "visionfive2";
  } ''
    set -eu
    fail=0
    state() {
      name=$1
      file=$2
      if grep -qx "CONFIG_''${name}=y" "$file"; then
        echo y
      elif grep -qx "CONFIG_''${name}=m" "$file"; then
        echo m
      elif grep -qx "# CONFIG_''${name} is not set" "$file"; then
        echo n
      else
        echo ABSENT
      fi
    }
    off() {
      arch=$1
      name=$2
      file=$3
      got=$(state "$name" "$file")
      case $got in
        n|ABSENT) ;;
        *) printf '%s: %s is %s\n' "$arch" "$name" "$got" >&2; fail=1 ;;
      esac
    }
    on() {
      arch=$1
      name=$2
      file=$3
      got=$(state "$name" "$file")
      case $got in
        y|m) ;;
        *) printf '%s: %s is %s\n' "$arch" "$name" "$got" >&2; fail=1 ;;
      esac
    }
    each() {
      arch=$1
      file=$2
      mode=$3
      shift 3
      for name in "$@"; do
        "$mode" "$arch" "$name" "$file"
      done
    }
    check() {
      arch=$1
      file=$2
      printf '%s SOUND=%s DRM_VC4=%s DRM_ROCKCHIP=%s DRM_MESON=%s DRM_SIMPLEDRM=%s\n' \
        "$arch" \
        "$(state SOUND "$file")" \
        "$(state DRM_VC4 "$file")" \
        "$(state DRM_ROCKCHIP "$file")" \
        "$(state DRM_MESON "$file")" \
        "$(state DRM_SIMPLEDRM "$file")"
      each "$arch" "$file" off \
        SOUND SND MEDIA_SUPPORT IIO COMEDI INFINIBAND NVME_TARGET \
        DRM_AMDGPU DRM_NOUVEAU DRM_PANFROST DRM_VC4 TARGET_CORE RC_CORE \
        SCSI_SAS_ATTRS SCSI_SAS_LIBSAS
      each "$arch" "$file" on \
        USB CFG80211 BLK_DEV_NVME SCSI_VIRTIO F2FS_FS DRM DRM_SIMPLEDRM \
        HWMON MMC R8169 BRCMFMAC
    }
    check x86_64 "$x86"
    check aarch64 "$arm64"
    check armv7 "$armv7"
    check riscv64 "$riscv"
    on aarch64 DRM_ROCKCHIP "$arm64"
    on aarch64 DRM_MESON "$arm64"
    on armv7 DRM_ROCKCHIP "$armv7"
    on armv7 DRM_MESON "$armv7"
    on aarch64 LEDS_TRIGGER_NETDEV "$arm64"
    on aarch64 LEDS_TRIGGER_HEARTBEAT "$arm64"
    on x86_64 E1000E "$x86"
    on x86_64 DRM_BOCHS "$x86"
    on x86_64 DRM_VIRTIO_GPU "$x86"
    if [ "$fail" -ne 0 ]; then
      exit 1
    fi
    echo ok > "$out"
  ''
