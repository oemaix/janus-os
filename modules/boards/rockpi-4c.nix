# SPDX-License-Identifier: Apache-2.0
# ROCK Pi 4C, lab unit v1.2. docs/10 §3.5, D-0053.
# RK3399, mainline U-Boot at sector 64, GPT. One RTL8211E on the SoC GMAC.
# The profile does not choose a WAN jack. A second port is a USB peripheral.
# nixpkgs ubootRockPi4 is the 4A/4B defconfig and does not install the
# combined image. The override follows the NanoPi R4S profile.
# The boot ROM tries SPI NOR before eMMC and SD. This image does not program SPI.
# U-Boot then tries eMMC (mmc0) and falls through to SD (mmc1). The serial
# console offers that order, or the SD card alone, for two seconds.
# The onboard AP6256 is an access point when match.onboard is set. docs/10 §4.10.
# Bluetooth stays unused.
{
  config,
  lib,
  pkgs,
  janusBuildPkgs ? pkgs,
  ...
}: let
  onboardWifi = lib.any (
    peripheral: (peripheral.class or null) == "wifi" && (peripheral.match.onboard or false)
  ) (lib.attrValues config.janus.hardware.peripherals);
  fetch = janusBuildPkgs.fetchurl;
  # Armbian names this NVRAM for radxa,rockpi4c. The driver asks for it
  # before brcmfmac43456-sdio.txt. Pinned linux-firmware has neither file.
  ap6256Src = name: sha256:
    fetch {
      inherit name sha256;
      url = "https://raw.githubusercontent.com/armbian/firmware/9934dbd5541bb49e2063089437a981f752c87b7f/brcm/${name}";
    };
  ap6256Bin = ap6256Src "brcmfmac43456-sdio.bin" "0z665kijvwwzdng5v2pipvp2ki98aywq58pnrb7w9zrcgdm9arri";
  ap6256Clm = ap6256Src "brcmfmac43456-sdio.clm_blob" "12jyl9mxvigsdc6d07aang3in8bdchcmpd7a1ibfpw4szhi7vg9d";
  ap6256Txt = ap6256Src "brcmfmac43456-sdio.txt" "17pxmidfykrq9zj4cgvgjjq411jp6i8p6rkb7119vi277fsixiv6";
  ap6256Firmware = janusBuildPkgs.stdenvNoCC.mkDerivation {
    pname = "ap6256-firmware";
    version = "1.1-08252017";
    dontUnpack = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out/lib/firmware/brcm"
      cp ${ap6256Bin} "$out/lib/firmware/brcm/brcmfmac43456-sdio.bin"
      cp ${ap6256Clm} "$out/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob"
      cp ${ap6256Txt} "$out/lib/firmware/brcm/brcmfmac43456-sdio.txt"
      cp ${ap6256Txt} "$out/lib/firmware/brcm/brcmfmac43456-sdio.radxa,rockpi4c.txt"
    '';
    meta = {
      description = "AP6256 firmware and NVRAM for the ROCK Pi 4C radio";
      license = lib.licenses.unfreeRedistributableFirmware;
      sourceProvenance = with lib.sourceTypes; [binaryFirmware];
    };
  };
  uboot = pkgs.ubootRockPi4.override {
    defconfig = "rock-pi-4c-rk3399_defconfig";
    # bootcmd is bootmenu. The entries must call bootflow scan. The
    # command boot would run bootcmd and open this menu again.
    extraPatches = [./janus-rockpi-4c-boot.patch];
    filesToInstall = [
      "u-boot-rockchip.bin"
      "idbloader.img"
      "u-boot.itb"
    ];
  };
  dtb = "${config.boot.kernelPackages.kernel}/dtbs/rockchip/rk3399-rock-pi-4c.dtb";
in {
  config = lib.mkIf (config.janus.hardware.board == "rockpi-4c") {
    # Boot partition starts at 16 MiB, past the FIT inside u-boot-rockchip.bin.
    janus.storage.firmwareOffsetMiB = lib.mkDefault 15;
    janus.network.ports = lib.mkDefault {
      eth0 = {};
    };
    boot.kernelParams = [
      "console=ttyS2,1500000n8"
      "net.ifnames=0"
    ];
    # brcmfmac stays unloaded until an access point declares this radio.
    # hci_uart binds the onboard brcm,bcm4345c5 node. btusb stays available.
    boot.blacklistedKernelModules =
      ["hci_uart"]
      ++ lib.optionals (!onboardWifi) ["brcmfmac"];
    hardware.firmware = lib.mkIf onboardWifi [ap6256Firmware];
    # SD is dw_mmc-rockchip, built in. eMMC is sdhci-of-arasan, built in.
    # Both stay listed so a modular build can still mount the root.
    boot.initrd.availableKernelModules = [
      "dw_mmc-rockchip"
      "sdhci-of-arasan"
      "phy-rockchip-emmc"
      "mmc_block"
      "phy_rockchip_inno_usb2"
    ];
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault false;
    system.build.janusBoardImage = {
      dtbName = "rk3399-rock-pi-4c.dtb";
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
