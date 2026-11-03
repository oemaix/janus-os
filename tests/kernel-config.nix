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
  matched = board: extra:
    (self.lib.mkRouter {
      modules = [
        {
          janus.hardware.board = board;
          janus.access.ssh.authorizedKeys = [key];
          janus.system.kernelProfile = "matched";
          janus.build.strategy = "cross";
        }
        extra
      ];
      buildSystem = "x86_64-linux";
      source = self;
      configRevision = self.rev or "unknown";
      name = "kernel-config-matched";
    }).config
    .boot
    .kernelPackages
    .kernel
    .configfile;
in
  pkgs.runCommand "eval-kernel-config" {
    x86 = configOf "x86_64-test";
    arm64 = configOf "nanopi-r4s";
    armv7 = configOf "rpi2";
    riscv = configOf "visionfive2";
    matchedX86 = matched "x86_64-test" {};
    matchedR4s = matched "nanopi-r4s" {};
    matchedR4sNic = matched "nanopi-r4s" {
      janus.hardware.peripherals.nic = {
        class = "nic";
        match.usbVendorProduct = "0bda:8153";
      };
    };
    matchedYanyu = matched "yanyu-stx-r19f" {};
    matchedRock = matched "rockpi-4c" {};
    matchedPotato = matched "le-potato" {
      janus.hardware.peripherals.cell = {
        class = "wwan";
        match.usbVendorProduct = "12d1:1506";
        wwan.mode = "ncm";
      };
    };
    matchedZero = matched "rpi-zero-2w" {};
    matchedZeroRadio = matched "rpi-zero-2w" {
      janus.hardware.peripherals.radio = {
        class = "wifi";
        match.onboard = true;
      };
    };
    matchedPi2 = matched "rpi2" {};
    matchedPi3 = matched "rpi3" {};
    matchedPi4 = matched "rpi4" {};
    matchedVf2 = matched "visionfive2" {};
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
      elif line=$(grep -m1 "^CONFIG_''${name}=" "$file"); then
        printf '%s\n' "''${line#*=}"
      else
        echo ABSENT
      fi
    }
    exact() {
      arch=$1
      name=$2
      want=$3
      file=$4
      got=$(state "$name" "$file")
      if [ "$got" != "$want" ]; then
        printf '%s: %s is %s, want %s\n' "$arch" "$name" "$got" "$want" >&2
        fail=1
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
    # matched: the same compact cut, then drivers this board does not use.
    each x86_64 "$matchedX86" off E1000E R8169 BRCMFMAC WLAN BT SATA_AHCI BLK_DEV_NVME SOUND
    on x86_64 VIRTIO_NET "$matchedX86"
    each aarch64 "$matchedR4s" off E1000E BCMGENET BRCMFMAC USB_RTL8152 BLK_DEV_NVME SATA_AHCI DRM_ROCKCHIP VIRTIO_NET WLAN
    each aarch64 "$matchedR4s" on R8169 DWMAC_ROCKCHIP
    off aarch64 USB_RTL8152 "$matchedR4s"
    off aarch64 USB_NET_HUAWEI_CDC_NCM "$matchedR4s"
    exact aarch64 SATA_MOBILE_LPM_POLICY ABSENT "$matchedR4s"
    on aarch64 USB_RTL8152 "$matchedR4sNic"
    on aarch64 R8169 "$matchedR4sNic"
    off aarch64 USB_NET_CDC_NCM "$matchedR4sNic"
    exact x86_64 E1000E m "$matchedYanyu"
    exact x86_64 SATA_AHCI m "$matchedYanyu"
    exact x86_64 USB_STORAGE m "$matchedYanyu"
    exact x86_64 SATA_MOBILE_LPM_POLICY 3 "$matchedYanyu"
    exact aarch64 MMC_DW_ROCKCHIP m "$matchedRock"
    exact aarch64 MMC_SDHCI_OF_ARASAN m "$matchedRock"
    exact aarch64 BLK_DEV_NVME m "$matchedRock"
    exact aarch64 MMC_MESON_GX y "$matchedPotato"
    exact aarch64 USB_NET_HUAWEI_CDC_NCM m "$matchedPotato"
    exact aarch64 USB_WDM m "$matchedPotato"
    exact aarch64 USB_NET_CDC_NCM m "$matchedPotato"
    exact aarch64 MMC_BCM2835 y "$matchedZero"
    exact aarch64 MMC_SDHCI_IPROC n "$matchedZero"
    exact aarch64 MMC_BCM2835 y "$matchedZeroRadio"
    exact aarch64 MMC_SDHCI_IPROC m "$matchedZeroRadio"
    exact aarch64 BRCMFMAC m "$matchedZeroRadio"
    exact armv7 MMC_BCM2835 m "$matchedPi2"
    exact armv7 MMC_SDHCI_IPROC m "$matchedPi2"
    exact armv7 USB_NET_SMSC95XX m "$matchedPi2"
    exact aarch64 USB_NET_SMSC95XX m "$matchedPi3"
    exact aarch64 USB_LAN78XX m "$matchedPi3"
    exact aarch64 MMC_BCM2835 y "$matchedPi3"
    exact aarch64 MMC_SDHCI_IPROC n "$matchedPi3"
    exact aarch64 BCMGENET m "$matchedPi4"
    exact aarch64 MMC_SDHCI_IPROC m "$matchedPi4"
    exact riscv64 MMC_DW_STARFIVE m "$matchedVf2"
    exact riscv64 BLK_DEV_NVME m "$matchedVf2"
    exact riscv64 MOTORCOMM_PHY m "$matchedVf2"
    off riscv64 REALTEK_PHY "$matchedVf2"
    off riscv64 NET_DSA_REALTEK "$matchedVf2"
    if [ "$fail" -ne 0 ]; then
      exit 1
    fi
    echo ok > "$out"
  ''
