# SPDX-License-Identifier: Apache-2.0
# NanoPi R4S. docs/10 §3. RK3399, mainline U-Boot at sector 64, GPT, no Wi-Fi.
# The two onboard NICs are eth0 and eth1. The profile does not choose a WAN jack.
# The silkscreen WAN and LAN LEDs are GPIO lines with no trigger in the DTB.
# docs/10 §3.2. WAN is the RTL8111H (r8169). LAN is the RTL8211E (rk_gmac-dwmac).
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Same open RK3399 recipe as ubootRockPro64, with the R4S defconfig
  # shipped in U-Boot 2026.04. The combined image is written at sector 64
  # (doc/board/rockchip/rockchip.rst: dd if=u-boot-rockchip.bin seek=64).
  uboot = pkgs.ubootRockPro64.override {
    defconfig = "nanopi-r4s-rk3399_defconfig";
    filesToInstall = [
      "u-boot-rockchip.bin"
      "idbloader.img"
      "u-boot.itb"
    ];
  };
  dtb = "${config.boot.kernelPackages.kernel}/dtbs/rockchip/rk3399-nanopi-r4s.dtb";
  portLeds = {
    wan = {
      driver = "r8169";
      led = "green:wan";
      label = "WAN";
    };
    lan = {
      driver = "rk_gmac-dwmac";
      led = "green:lan";
      label = "LAN";
    };
  };
  ledScript = jack: led:
    pkgs.writeShellScript "janus-r4s-${jack}-led" ''
      set -eu
      iface=$1
      led=/sys/class/leds/${led}
      n=0
      while [ ! -e "$led/trigger" ]; do
        n=$((n + 1))
        if [ "$n" -gt 50 ]; then
          echo "janus: $led is not registered" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/sleep 0.1
      done
      printf '%s\n' netdev > "$led/trigger"
      printf '%s\n' "$iface" > "$led/device_name"
      printf '%s\n' 1 > "$led/link"
      printf '%s\n' 1 > "$led/tx"
      printf '%s\n' 1 > "$led/rx"
    '';
in {
  config = lib.mkIf (config.janus.hardware.board == "nanopi-r4s") {
    # Boot partition starts at 16 MiB, past the FIT inside u-boot-rockchip.bin.
    janus.storage.firmwareOffsetMiB = lib.mkDefault 15;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
      eth1 = {};
    };
    boot.kernelParams = [
      "console=ttyS2,1500000n8"
      "net.ifnames=0"
    ];
    # arm64 defconfig builds gpio-leds in and leaves LEDS_TRIGGER_NETDEV off.
    boot.kernelPatches = [
      {
        name = "janus-r4s-netdev-led";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          LEDS_TRIGGER_NETDEV = yes;
        };
      }
    ];
    systemd.services =
      lib.mapAttrs' (
        jack: spec:
          lib.nameValuePair "janus-r4s-${jack}-led@" {
            description = "NanoPi R4S ${spec.label} LED follows that jack";
            bindsTo = ["sys-subsystem-net-devices-%i.device"];
            after = ["sys-subsystem-net-devices-%i.device"];
            # udev starts the unit once. A failed oneshot stays failed, and
            # unplugging the cable leaves the netdev in place, so retry here.
            startLimitBurst = 6;
            startLimitIntervalSec = 60;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = "1s";
              ExecStart = "${ledScript jack spec.led} %i";
            };
          }
      )
      portLeds;
    services.udev.extraRules = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        jack: spec: ''
          ACTION=="add", SUBSYSTEM=="net", DRIVERS=="${spec.driver}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="janus-r4s-${jack}-led@%k.service"
        ''
      )
      portLeds
    );
    # Built in as dw_mmc-rockchip. modprobe has no alias for dwmmc_rockchip.
    boot.initrd.availableKernelModules = [
      "dw_mmc-rockchip"
      "mmc_block"
      "phy_rockchip_inno_usb2"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      dtbName = "rk3399-nanopi-r4s.dtb";
      dtbSource = dtb;
      firmwareInstall = ''
        fw=${uboot}/u-boot-rockchip.bin
        size=$(stat -c %s "$fw")
        end=$(( 64 * 512 + size ))
        limit=$(( boot_start * 1024 * 1024 ))
        if [ "$end" -ge "$limit" ]; then
          echo "janus: U-Boot ($end bytes from the start) overlaps the boot partition at ''${limit}" >&2
          exit 1
        fi
        dd if="$fw" of=disk.img bs=512 seek=64 conv=notrunc status=none
      '';
    };
  };
}
