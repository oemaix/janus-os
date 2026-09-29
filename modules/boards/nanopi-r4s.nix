# SPDX-License-Identifier: Apache-2.0
# NanoPi R4S. docs/10 §3. RK3399, mainline U-Boot at sector 64, GPT, no Wi-Fi.
# The two onboard NICs are eth0 and eth1. The profile does not choose a WAN jack.
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
    boot.initrd.availableKernelModules = [
      "dwmmc_rockchip"
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
