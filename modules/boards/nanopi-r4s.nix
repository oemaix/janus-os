# SPDX-License-Identifier: Apache-2.0
# NanoPi R4S. docs/10 §3. RK3399, mainline U-Boot at sector 64, GPT, no Wi-Fi.
# The two onboard NICs are eth0 and eth1. The profile does not choose a WAN jack.
# The silkscreen WAN and LAN LEDs are GPIO lines with no trigger in the DTB.
# docs/10 §3.2. WAN is the RTL8111H (r8169). LAN is the RTL8211E (rk_gmac-dwmac).
# r8169 applies rtl_nic/rtl8168h-2.fw on every open of that chip. docs/10 §3.3.
{
  config,
  lib,
  pkgs,
  janusBuildPkgs ? pkgs,
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
  # One PHY script, copied from the pinned package. The full collection,
  # and hardware.enableRedistributableFirmware, would also install
  # Raspberry Pi wireless blobs on a board with no radio.
  rtl8168hFirmware = import ../janus/hardware/firmware-slice.nix {
    inherit lib pkgs;
    builderPkgs = janusBuildPkgs;
  } {
    pname = "rtl8168h-firmware";
    description = "PHY script for the NanoPi R4S RTL8168h/8111h";
    paths = ["rtl_nic/rtl8168h-2.fw"];
  };
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
  # Text only. The builder is the build host; the shebang and sleep
  # are the board's binaries. An x86_64 check can build this without qemu.
  ledScript = jack: led:
    janusBuildPkgs.writeTextFile {
      name = "janus-r4s-${jack}-led";
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}
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
      checkPhase = ''
        ${janusBuildPkgs.stdenv.shellDryRun} "$target"
      '';
    };
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
    # The profile turns that trigger on, and turns LEDS_TRIGGER_HEARTBEAT on
    # for the SYS LED. The green SYS LED is red:power on GPIO0_B5.
    # SDR104 switches the SD I/O rail to 1.8 V and leaves it there. The boot
    # ROM and U-Boot read the card at 3.3 V, so the next start finds no card.
    # High-speed stays. no-1-8-v blocks a later UHS mode from the same switch.
    boot.kernelPatches = [
      {
        name = "janus-r4s-netdev-led";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          LEDS_TRIGGER_HEARTBEAT = yes;
          LEDS_TRIGGER_NETDEV = yes;
        };
      }
      {
        name = "janus-r4s-sys-led";
        patch = ./janus-r4s-sys-led.patch;
      }
      {
        name = "janus-r4s-sd-uhs";
        patch = ./janus-r4s-sd-uhs.patch;
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
    hardware.firmware = [rtl8168hFirmware];
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
