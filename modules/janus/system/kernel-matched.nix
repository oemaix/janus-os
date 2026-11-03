# SPDX-License-Identifier: Apache-2.0
# Extra kernel symbols for janus.system.kernelProfile = "matched".
# docs/08 §1, D-0052. The compact cut is applied by kernel-profile.nix.
# A driver stays only when this board, or a peripheral declared on it, uses it.
{lib}: {
  board,
  peripherals,
}: let
  allow = import ../hardware/allowlist.nix;
  ps = lib.attrValues peripherals;
  usbOf = p: p.match.usbVendorProduct or null;
  hasUsb = id: lib.any (p: usbOf p == id) ps;
  hasClass = class: lib.any (p: p.class == class) ps;
  onboardWifi = lib.any (p: p.class == "wifi" && (p.match.onboard or false)) ps;
  pi = lib.elem board ["rpi-zero-2w" "rpi2" "rpi3" "rpi4"];
  hmiPi = lib.elem board ["rpi-zero-2w" "rpi3" "rpi4"];

  modeOf = p:
    if p.class != "wwan"
    then null
    else if p.wwan.mode != "auto"
    then p.wwan.mode
    else let
      modes = (allow.usb.${usbOf p} or {}).modes or [];
    in
      if modes == []
      then null
      else builtins.head modes;
  wwanModes = lib.unique (lib.filter (m: m != null) (map modeOf ps));
  hasMode = mode: lib.elem mode wwanModes;
  # Huawei NCM selects USB_WDM. The generic cdc_ncm driver does not bind
  # 12d1:1506. docs/10 §4.2.
  wantHuaweiNcm =
    lib.any (
      p:
        modeOf p
        == "ncm"
        && (usbOf p != null)
        && lib.hasPrefix "12d1:" (usbOf p)
    )
    ps;

  # sh1106, st7789, and the e-paper HAT are SPI. ssd1306 is I²C.
  # The Waveshare profile's driver defaults to sh1106. docs/10 §4.6.
  hmiDrivers = lib.unique (
    lib.filter (d: d != null) (map (p:
      if p.class != "hmi"
      then null
      else p.hmi.driver or null)
    ps)
  );
  wantSpi = hmiPi && (hasClass "hmi") && (hmiDrivers == [] || lib.any (d: lib.elem d ["sh1106" "st7789" "waveshare-epd-2in13"]) hmiDrivers);
  wantI2c = (pi && hasClass "power") || (hmiPi && lib.elem "ssd1306" hmiDrivers);

  wifiUsb =
    (lib.optional (hasUsb "0e8d:7612") "MT76x2U")
    ++ (lib.optional (hasUsb "0e8d:7961") "MT7921U")
    ++ (lib.optional (hasUsb "0bda:8176") "RTL8192CU");
  wantWifi = onboardWifi || wifiUsb != [];

  usbNet =
    (lib.optional (hasUsb "0bda:8153" || hasUsb "0bda:8156") "USB_RTL8152")
    ++ (lib.optional (hasUsb "0b95:1790") "USB_NET_AX88179_178A")
    ++ (lib.optional (board == "rpi2" || board == "rpi3") "USB_NET_SMSC95XX")
    ++ (lib.optional (board == "rpi3") "USB_LAN78XX")
    ++ (lib.optional (hasMode "ecm" || hasMode "ncm") "USB_NET_CDCETHER")
    ++ (lib.optional (hasMode "ncm") "USB_NET_CDC_NCM")
    ++ (lib.optional (hasMode "rndis") "USB_NET_RNDIS_HOST")
    ++ (lib.optional (hasMode "qmi") "USB_NET_QMI_WWAN")
    ++ (lib.optional (hasMode "mbim") "USB_NET_CDC_MBIM")
    ++ (lib.optional (hasMode "qmi" || hasMode "mbim" || wantHuaweiNcm) "USB_WDM");
  wantUsbNet = usbNet != [];
  wantSerial = wwanModes != [];
  wantBt = hasClass "bluetooth";
  wantNvme = board == "rockpi-4c" || board == "visionfive2";
  wantAhci = board == "yanyu-stx-r19f";
  wantVirtio = board == "x86_64-test";

  # Tristate drivers. defconfig turns many of these on for every board.
  modCatalog = [
    "E1000"
    "E1000E"
    "R8169"
    "BCMGENET"
    "STMMAC_ETH"
    "DWMAC_ROCKCHIP"
    "DWMAC_MESON"
    "DWMAC_STARFIVE"
    "DWMAC_MEDIATEK"
    "DWMAC_TEGRA"
    "DWMAC_THEAD"
    "SMSC911X"
    "HIBMCGE"
    "USB_RTL8150"
    "USB_RTL8152"
    "USB_RTL8153_ECM"
    "USB_LAN78XX"
    "USB_USBNET"
    "USB_NET_AX8817X"
    "USB_NET_AX88179_178A"
    "USB_NET_CDCETHER"
    "USB_NET_CDC_NCM"
    "USB_NET_HUAWEI_CDC_NCM"
    "USB_NET_CDC_MBIM"
    "USB_NET_RNDIS_HOST"
    "USB_NET_QMI_WWAN"
    "USB_NET_SMSC75XX"
    "USB_NET_SMSC95XX"
    "USB_NET_DM9601"
    "USB_NET_SR9800"
    "USB_NET_PLUSB"
    "USB_NET_MCS7830"
    "USB_NET_AQC111"
    "USB_WDM"
    "USB_SERIAL"
    "USB_SERIAL_OPTION"
    "USB_SERIAL_FTDI_SIO"
    "USB_SERIAL_CP210X"
    "CFG80211"
    "MAC80211"
    "BRCMFMAC"
    "MT76x2U"
    "MT7921U"
    "RTL8192CU"
    "RTL8XXXU"
    "ATH10K"
    "ATH11K"
    "ATH12K"
    "IWLWIFI"
    "RTW88"
    "BT_HCIBTUSB"
    "BT_HCIUART"
    "BT_MRVL"
    "BT_QCA"
    "BLK_DEV_NVME"
    "SATA_AHCI"
    "SATA_AHCI_PLATFORM"
    "USB_STORAGE"
    "USB_UAS"
    "VIRTIO_PCI"
    "VIRTIO_BLK"
    "VIRTIO_NET"
    "VIRTIO_BALLOON"
    "VIRTIO_MMIO"
    "VIRTIO_CONSOLE"
    "VIRTIO_INPUT"
    "SCSI_VIRTIO"
    "DRM_VIRTIO_GPU"
    "DRM_BOCHS"
    "DRM_ROCKCHIP"
    "DRM_MESON"
    "DRM_SIMPLEDRM"
    "MMC_DW_ROCKCHIP"
    "MMC_MESON_GX"
    "MMC_BCM2835"
    "MMC_SDHCI_IPROC"
    "MMC_DW_STARFIVE"
    "MMC_SDHCI_OF_ARASAN"
    "REALTEK_PHY"
    "NET_DSA_REALTEK"
    "MESON_GXL_PHY"
    "MOTORCOMM_PHY"
    "BROADCOM_PHY"
    "SPI_BCM2835"
    "SPI_BCM2835AUX"
    "SPI_SPIDEV"
    "SENSORS_INA2XX"
    "I2C_BCM2835"
    "NVME_HWMON"
  ];

  # Bool menus. A driver under one of these is not asked while the menu is n.
  yesCatalog = [
    "WLAN"
    "WLAN_VENDOR_BROADCOM"
    "WLAN_VENDOR_MEDIATEK"
    "WLAN_VENDOR_REALTEK"
    "WLAN_VENDOR_ATH"
    "WLAN_VENDOR_INTEL"
    "USB_NET_DRIVERS"
    "NET_VENDOR_REALTEK"
    "NET_VENDOR_INTEL"
    "NET_VENDOR_BROADCOM"
    "NET_VENDOR_STMICRO"
    "NET_VENDOR_MEDIATEK"
    "NET_VENDOR_SMSC"
    "NET_VENDOR_HISILICON"
    "BRCMFMAC_SDIO"
    "BRCMFMAC_USB"
    "BRCMFMAC_PCIE"
    "BT"
    "NVME_MULTIPATH"
  ];

  keepMod =
    (lib.optional (board == "yanyu-stx-r19f") "E1000E")
    ++ (lib.optional (board == "nanopi-r4s") "R8169")
    ++ (lib.optional (board == "rpi4") "BCMGENET")
    ++ (lib.optionals (lib.elem board ["nanopi-r4s" "rockpi-4c" "le-potato" "visionfive2"]) ["STMMAC_ETH"])
    ++ (lib.optionals (lib.elem board ["nanopi-r4s" "rockpi-4c"]) ["DWMAC_ROCKCHIP" "REALTEK_PHY"])
    ++ (lib.optionals (board == "le-potato") ["DWMAC_MESON" "MESON_GXL_PHY"])
    ++ (lib.optionals (board == "visionfive2") ["DWMAC_STARFIVE" "MOTORCOMM_PHY"])
    ++ (lib.optional (board == "rpi4") "BROADCOM_PHY")
    ++ (lib.optionals (lib.elem board ["nanopi-r4s" "rockpi-4c"]) ["MMC_DW_ROCKCHIP"])
    ++ (lib.optional (board == "rockpi-4c") "MMC_SDHCI_OF_ARASAN")
    ++ (lib.optionals (lib.elem board ["rpi2" "rpi4"]) ["MMC_SDHCI_IPROC"])
    ++ (lib.optional (board == "rpi2") "MMC_BCM2835")
    ++ (lib.optional (board == "rpi-zero-2w" && onboardWifi) "MMC_SDHCI_IPROC")
    ++ (lib.optional (board == "visionfive2") "MMC_DW_STARFIVE")
    ++ (lib.optional wantNvme "BLK_DEV_NVME")
    ++ (lib.optionals wantAhci ["SATA_AHCI" "SATA_AHCI_PLATFORM" "USB_STORAGE" "USB_UAS"])
    ++ (lib.optionals wantVirtio [
      "VIRTIO_PCI"
      "VIRTIO_BLK"
      "VIRTIO_NET"
      "SCSI_VIRTIO"
      "DRM_VIRTIO_GPU"
      "DRM_BOCHS"
      "DRM_SIMPLEDRM"
    ])
    ++ (lib.optional wantUsbNet "USB_USBNET")
    ++ usbNet
    ++ (lib.optional wantHuaweiNcm "USB_NET_HUAWEI_CDC_NCM")
    ++ (lib.optionals wantSerial ["USB_SERIAL" "USB_SERIAL_OPTION"])
    ++ (lib.optionals wantWifi ["CFG80211" "MAC80211"])
    ++ (lib.optional onboardWifi "BRCMFMAC")
    ++ wifiUsb
    ++ (lib.optional wantBt "BT_HCIBTUSB")
    ++ (lib.optional (hasClass "power") "SENSORS_INA2XX")
    ++ (lib.optional wantI2c "I2C_BCM2835")
    ++ (lib.optionals wantSpi ["SPI_BCM2835" "SPI_SPIDEV"]);

  keepYes =
    (lib.optional (board == "yanyu-stx-r19f") "NET_VENDOR_INTEL")
    ++ (lib.optional (board == "nanopi-r4s") "NET_VENDOR_REALTEK")
    ++ (lib.optional (board == "rpi4") "NET_VENDOR_BROADCOM")
    ++ (lib.optionals (lib.elem board ["nanopi-r4s" "rockpi-4c" "le-potato" "visionfive2"]) ["NET_VENDOR_STMICRO"])
    ++ (lib.optional wantUsbNet "USB_NET_DRIVERS")
    ++ (lib.optional wantWifi "WLAN")
    ++ (lib.optionals onboardWifi ["WLAN_VENDOR_BROADCOM" "BRCMFMAC_SDIO"])
    ++ (lib.optional (hasUsb "0e8d:7612" || hasUsb "0e8d:7961") "WLAN_VENDOR_MEDIATEK")
    ++ (lib.optional (hasUsb "0bda:8176") "WLAN_VENDOR_REALTEK")
    ++ (lib.optional wantBt "BT")
    ++ (lib.optional wantNvme "NVME_MULTIPATH");

  # Built in. The initrd does not list the module, so m cannot mount the root.
  # Le Potato: meson-gx-mmc. Zero 2 W, Pi 3, and Pi 3+: sdhost. docs/10 §3
  # and §4.7. On those Pis the Arasan host is the radio, not the card.
  keepBuiltin =
    (lib.optional (board == "le-potato") "MMC_MESON_GX")
    ++ (lib.optionals (lib.elem board ["rpi-zero-2w" "rpi3"]) ["MMC_BCM2835"]);

  # Nixpkgs sets these as required answers. Once the parent menu is n they
  # are not asked, and a required answer then fails the config. optional n
  # replaces that answer. A hidden symbol is ignored.
  childOff =
    [
      "8139TOO_8129"
      "8139TOO_PIO"
      "BT_HCIUART_QCA"
      "BT_HCIUART_SERDEV"
      "NVIDIA_SHIELD_FF"
      "USB_SERIAL_CONSOLE"
      "VIRTIO_MMIO_CMDLINE_DEVICES"
      "MT7986_WMAC"
      "MT798X_WMAC"
      "ROCKCHIP_DW_HDMI_QP"
      "ROCKCHIP_DW_MIPI_DSI2"
      "RT2800USB_RT53XX"
      "RT2800USB_RT55XX"
      "RTW88_8822BE"
      "RTW88_8822CE"
    ]
    ++ lib.optionals (!wantBt) ["BT_HCIBTUSB_AUTOSUSPEND" "BT_HCIBTUSB_MTK"]
    ++ lib.optionals (!wantWifi) [
      "CFG80211_DEBUGFS"
      "MAC80211_DEBUGFS"
    ]
    ++ lib.optionals (!wantNvme) ["NVME_AUTH" "NVME_HOST_AUTH"]
    ++ lib.optionals (!wantSerial) ["USB_SERIAL_GENERIC"];

  drop = names: keep: lib.filter (n: !lib.elem n keep) names;
  # optional n: a symbol this arch does not ask is ignored. mkForce still
  # replaces a defconfig y or m when the symbol is asked.
  off = names: lib.genAttrs names (_: lib.mkForce (lib.kernel.option lib.kernel.no));
  asMod = names: lib.genAttrs names (_: lib.mkForce lib.kernel.module);
  asYes = names: lib.genAttrs names (_: lib.mkForce lib.kernel.yes);
in
  off (drop modCatalog (keepMod ++ keepBuiltin))
  // off (drop yesCatalog keepYes)
  // off childOff
  // asMod keepMod
  // asYes (keepYes ++ keepBuiltin)
  # An int. n is not a legal answer. optional replaces the required nixpkgs
  # value once AHCI is off and the question is no longer asked.
  // lib.optionalAttrs (!wantAhci) {
    SATA_MOBILE_LPM_POLICY = lib.mkForce (lib.kernel.option (lib.kernel.freeform "3"));
  }
