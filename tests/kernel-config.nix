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
  audioEmbedded = {
    janus.audio.enable = true;
    janus.audio.playback.output = "embedded";
    janus.audio.playback.node = "alsa_output.platform-analog";
  };
  audioUsb = {
    janus.audio.enable = true;
    janus.audio.playback.output = "usb";
    janus.audio.playback.node = "alsa_output.usb";
  };
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
    # janus.audio.enable on matched. generate-config.pl, not the attrset. T-0008.
    matchedPi4Audio = matched "rpi4" audioEmbedded;
    matchedPi2Audio = matched "rpi2" audioEmbedded;
    matchedRockAudio = matched "rockpi-4c" audioEmbedded;
    matchedPotatoAudio = matched "le-potato" audioEmbedded;
    matchedVf2Audio = matched "visionfive2" audioEmbedded;
    matchedYanyuAudio = matched "yanyu-stx-r19f" audioEmbedded;
    matchedX86Usb = matched "x86_64-test" audioUsb;
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
    exact aarch64 MMC_SDHCI_IPROC y "$matchedPi4"
    exact riscv64 MMC_DW_STARFIVE m "$matchedVf2"
    exact riscv64 BLK_DEV_NVME m "$matchedVf2"
    exact riscv64 MOTORCOMM_PHY m "$matchedVf2"
    off riscv64 REALTEK_PHY "$matchedVf2"
    off riscv64 NET_DSA_REALTEK "$matchedVf2"
    exact aarch64 SOUND m "$matchedPi4Audio"
    exact aarch64 SND_BCM2835 m "$matchedPi4Audio"
    exact aarch64 SND_USB_AUDIO n "$matchedPi4Audio"
    # Not asked once the parent menu is n, so the line is absent. That is off.
    off aarch64 DRM_VC4 "$matchedPi4Audio"
    off aarch64 SND_SOC_MT8183 "$matchedPi4Audio"
    exact armv7 SOUND m "$matchedPi2Audio"
    exact armv7 SND_BCM2835 m "$matchedPi2Audio"
    exact aarch64 SOUND m "$matchedRockAudio"
    exact aarch64 SND_SOC_ROCKCHIP_I2S m "$matchedRockAudio"
    exact aarch64 SND_SOC_ES8316 m "$matchedRockAudio"
    exact aarch64 SND_SOC_SPDIF m "$matchedRockAudio"
    exact aarch64 SND_USB_AUDIO n "$matchedRockAudio"
    exact aarch64 SOUND m "$matchedPotatoAudio"
    exact aarch64 SND_MESON_GX_SOUND_CARD m "$matchedPotatoAudio"
    exact aarch64 SND_DYNAMIC_MINORS y "$matchedPotatoAudio"
    exact riscv64 SOUND m "$matchedVf2Audio"
    exact riscv64 SND_SOC_JH7110_PWMDAC m "$matchedVf2Audio"
    exact riscv64 SND_SIMPLE_CARD m "$matchedVf2Audio"
    exact x86_64 SOUND m "$matchedYanyuAudio"
    exact x86_64 SND_HDA_INTEL m "$matchedYanyuAudio"
    exact x86_64 SND_HDA_HWDEP y "$matchedYanyuAudio"
    exact x86_64 SND_HDA_GENERIC m "$matchedYanyuAudio"
    exact x86_64 SND_HDA_CODEC_REALTEK m "$matchedYanyuAudio"
    exact x86_64 SND_HDA_CODEC_ALC269 m "$matchedYanyuAudio"
    exact x86_64 SND_USB_AUDIO n "$matchedYanyuAudio"
    exact x86_64 SOUND m "$matchedX86Usb"
    exact x86_64 SND_USB_AUDIO m "$matchedX86Usb"
    exact x86_64 SND_HDA_INTEL n "$matchedX86Usb"
    exact x86_64 SND_VIRTIO n "$matchedX86Usb"
    if [ "$fail" -ne 0 ]; then
      exit 1
    fi
    echo ok > "$out"
  ''
