# SPDX-License-Identifier: Apache-2.0
# Extra kernel symbols for janus.system.kernelProfile = "matched".
# docs/08 §1, D-0052. The compact cut is applied by kernel-profile.nix.
# A driver stays only when this board, or a peripheral declared on it, uses it.
{lib}: {
  board,
  peripherals,
  bluetoothPlayback ? false,
  wantUsbAudio ? false,
  wantEmbeddedAudio ? false,
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
  # Onboard controllers are UART (Broadcom). A USB dongle stays btusb.
  # A2DP is BlueZ, not ALSA. D-0061, T-0011.
  wantOnboardBt = bluetoothPlayback && lib.elem board ["rpi-zero-2w" "rpi3" "rpi4" "rockpi-4c"];
  # ALSA follows janus.audio.enable plus an embedded or USB device.
  # Bluetooth playback does not turn SOUND on. T-0018.
  wantSound = wantUsbAudio || wantEmbeddedAudio;
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
    ++ (lib.optional (board == "rpi2") "MMC_SDHCI_IPROC")
    ++ (lib.optional (board == "rpi2") "MMC_BCM2835")
    ++ (lib.optional ((board == "rpi-zero-2w" || board == "rpi3") && onboardWifi) "MMC_SDHCI_IPROC")
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
    ++ (lib.optional wantOnboardBt "BT_HCIUART")
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
    ++ (lib.optional (wantBt || wantOnboardBt) "BT")
    ++ (lib.optionals wantOnboardBt ["BT_HCIUART_BCM" "BT_HCIUART_SERDEV"])
    ++ (lib.optional wantNvme "NVME_MULTIPATH");

  # Built in. The initrd does not list the module, so m cannot mount the root.
  # Le Potato: meson-gx-mmc. Zero 2 W, Pi 3, and Pi 3+: sdhost. The Pi 4
  # card is the Arasan host, so that symbol stays y on every image.
  # docs/10 §3, §4.7, and §4.12. T-0005.
  keepBuiltin =
    (lib.optional (board == "le-potato") "MMC_MESON_GX")
    ++ (lib.optionals (lib.elem board ["rpi-zero-2w" "rpi3"]) ["MMC_BCM2835"])
    ++ (lib.optional (board == "rpi4") "MMC_SDHCI_IPROC");

  # Nixpkgs sets these as required answers. Once the parent menu is n they
  # are not asked, and a required answer then fails the config. optional n
  # replaces that answer. A hidden symbol is ignored.
  childOff =
    [
      "8139TOO_8129"
      "8139TOO_PIO"
      "BT_HCIUART_QCA"
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
    ++ lib.optionals (!wantOnboardBt) ["BT_HCIUART_SERDEV"]
    ++ lib.optionals (!wantBt) ["BT_HCIBTUSB_AUTOSUSPEND" "BT_HCIBTUSB_MTK"]
    ++ lib.optionals (!wantWifi) [
      "CFG80211_DEBUGFS"
      "MAC80211_DEBUGFS"
    ]
    ++ lib.optionals (!wantNvme) ["NVME_AUTH" "NVME_HOST_AUTH"]
    ++ lib.optionals (!wantSerial) ["USB_SERIAL_GENERIC"];

  # Drivers the architecture defconfig turns on once SOUND is no longer n.
  # Keepers are removed below. A name with no Kconfig symbol is not listed:
  # SND_SOC_ROCKCHIP is a stale defconfig entry in 6.18. T-0018.
  soundCatalog = [
    "SND_ALOOP"
    "SND_HDA_TEGRA"
    "SND_HDA_CODEC_HDMI"
    "SND_HDA_CODEC_HDMI_GENERIC"
    "SND_HDA_CODEC_HDMI_NVIDIA"
    "SND_HDA_CODEC_HDMI_TEGRA"
    "SND_HDA_CODEC_REALTEK"
    "SND_HDA_CODEC_ALC269"
    "SND_HDA_GENERIC"
    "SND_HDA_INTEL"
    "SND_HDA_HWDEP"
    "SND_HRTIMER"
    "SND_SEQUENCER"
    "SND_SEQ_DUMMY"
    "SND_USB_AUDIO"
    "SND_SOC"
    "SND_BCM2835"
    "SND_BCM2835_SOC_I2S"
    "SND_DESIGNWARE_I2S"
    "SND_SOC_FSL_ASRC"
    "SND_SOC_FSL_MICFIL"
    "SND_SOC_FSL_EASRC"
    "SND_IMX_SOC"
    "SND_SOC_IMX_SGTL5000"
    "SND_SOC_FSL_ASOC_CARD"
    "SND_SOC_IMX_AUDMIX"
    "SND_SOC_MT8183"
    "SND_SOC_MT8183_MT6358_TS3A227E_MAX98357A"
    "SND_SOC_MT8183_DA7219_MAX98357A"
    "SND_SOC_MT8188"
    "SND_SOC_MT8188_MT6359"
    "SND_SOC_MT8192"
    "SND_SOC_MT8192_MT6359_RT1015_RT5682"
    "SND_SOC_MT8195"
    "SND_SOC_MT8195_MT6359"
    "SND_SOC_MT8365"
    "SND_SOC_MT8365_MT6357"
    "SND_MESON_AXG_SOUND_CARD"
    "SND_MESON_GX_SOUND_CARD"
    "SND_SOC_QCOM"
    "SND_SOC_APQ8016_SBC"
    "SND_SOC_MSM8996"
    "SND_SOC_SDM845"
    "SND_SOC_SM8250"
    "SND_SOC_SC8280XP"
    "SND_SOC_SC7180"
    "SND_SOC_SC7280"
    "SND_SOC_X1E80100"
    "SND_SOC_ROCKCHIP_I2S_TDM"
    "SND_SOC_ROCKCHIP_SAI"
    "SND_SOC_ROCKCHIP_SPDIF"
    "SND_SOC_ROCKCHIP_MAX98090"
    "SND_SOC_ROCKCHIP_RT5645"
    "SND_SOC_RK3399_GRU_SOUND"
    "SND_SOC_RCAR"
    "SND_SOC_MSIOF"
    "SND_SOC_RZ"
    "SND_SOC_SAMSUNG"
    "SND_SOC_SAMSUNG_SMDK_WM8994"
    "SND_SOC_SMDK_WM8994_PCM"
    "SND_SOC_SNOW"
    "SND_SOC_ODROID"
    "SND_SOC_ARNDALE"
    "SND_SOC_SAMSUNG_MIDAS_WM1811"
    "SND_SOC_SH4_FSI"
    "SND_SOC_STI"
    "SND_SOC_STM32_SAI"
    "SND_SOC_STM32_I2S"
    "SND_SOC_STM32_SPDIFRX"
    "SND_SOC_STM32_DFSDM"
    "SND_SOC_SOF_TOPLEVEL"
    "SND_SOC_SOF_OF"
    "SND_SOC_SOF_MTK_TOPLEVEL"
    "SND_SOC_SOF_MT8186"
    "SND_SOC_SOF_MT8195"
    "SND_SUN4I_CODEC"
    "SND_SUN8I_CODEC"
    "SND_SUN8I_CODEC_ANALOG"
    "SND_SUN50I_CODEC_ANALOG"
    "SND_SUN4I_I2S"
    "SND_SUN4I_SPDIF"
    "SND_SOC_TEGRA"
    "SND_SOC_TEGRA20_I2S"
    "SND_SOC_TEGRA20_SPDIF"
    "SND_SOC_TEGRA30_I2S"
    "SND_SOC_TEGRA_RT5640"
    "SND_SOC_TEGRA_WM8753"
    "SND_SOC_TEGRA_WM8903"
    "SND_SOC_TEGRA_WM9712"
    "SND_SOC_TEGRA_TRIMSLICE"
    "SND_SOC_TEGRA_ALC5632"
    "SND_SOC_TEGRA_MAX98090"
    "SND_SOC_TEGRA210_AHUB"
    "SND_SOC_TEGRA210_DMIC"
    "SND_SOC_TEGRA210_I2S"
    "SND_SOC_TEGRA210_OPE"
    "SND_SOC_TEGRA186_ASRC"
    "SND_SOC_TEGRA186_DSPK"
    "SND_SOC_TEGRA210_ADMAIF"
    "SND_SOC_TEGRA210_MVC"
    "SND_SOC_TEGRA210_SFC"
    "SND_SOC_TEGRA210_AMX"
    "SND_SOC_TEGRA210_ADX"
    "SND_SOC_TEGRA210_MIXER"
    "SND_SOC_TEGRA_AUDIO_GRAPH_CARD"
    "SND_SOC_DAVINCI_MCASP"
    "SND_SOC_J721E_EVM"
    "SND_SOC_AK4613"
    "SND_SOC_AK4619"
    "SND_SOC_AK4642"
    "SND_SOC_DA7213"
    "SND_SOC_ES7134"
    "SND_SOC_ES7241"
    "SND_SOC_ES8316"
    "SND_SOC_ES8328_I2C"
    "SND_SOC_GTM601"
    "SND_SOC_MSM8916_WCD_ANALOG"
    "SND_SOC_MSM8916_WCD_DIGITAL"
    "SND_SOC_PCM3168A_I2C"
    "SND_SOC_RK3308"
    "SND_SOC_RK817"
    "SND_SOC_RT5640"
    "SND_SOC_RT5659"
    "SND_SOC_SIMPLE_AMPLIFIER"
    "SND_SOC_SIMPLE_MUX"
    "SND_SOC_TAS2552"
    "SND_SOC_TAS571X"
    "SND_SOC_TLV320AIC32X4"
    "SND_SOC_TLV320AIC32X4_I2C"
    "SND_SOC_TLV320AIC3X_I2C"
    "SND_SOC_WCD9335"
    "SND_SOC_WCD934X"
    "SND_SOC_WCD939X_SDW"
    "SND_SOC_WM8524"
    "SND_SOC_WM8904"
    "SND_SOC_WM8960"
    "SND_SOC_WM8962"
    "SND_SOC_WM8978"
    "SND_SOC_WSA881X"
    "SND_SOC_WSA883X"
    "SND_SOC_WSA884X"
    "SND_SOC_NAU8822"
    "SND_SOC_LPASS_WSA_MACRO"
    "SND_SOC_LPASS_VA_MACRO"
    "SND_SOC_LPASS_RX_MACRO"
    "SND_SOC_LPASS_TX_MACRO"
    "SND_SOC_AC97_CODEC"
    "SND_SOC_CPCAP"
    "SND_SOC_CS42L51_I2C"
    "SND_SOC_SGTL5000"
    "SND_SOC_STI_SAS"
    "SND_ATMEL_SOC"
    "SND_ATMEL_SOC_WM8904"
    "SND_ATMEL_SOC_PDMIC"
    "SND_ATMEL_SOC_I2S"
    "SND_PXA_SOC_SSP"
    "SND_MMP_SOC_SSPA"
    "SND_PXA910_SOC"
    "SND_SIMPLE_CARD"
    "SND_AUDIO_GRAPH_CARD"
    "SND_AUDIO_GRAPH_CARD2"
    "SND_SOC_JH7110_PWMDAC"
    "SND_SOC_JH7110_TDM"
    "SND_VIRTIO"
    "SOUNDWIRE"
    "SOUNDWIRE_QCOM"
  ];
  keepSound = lib.unique (
    (lib.optional wantUsbAudio "SND_USB_AUDIO")
    ++ (lib.optional (wantEmbeddedAudio && pi) "SND_BCM2835")
    ++ (lib.optionals (wantEmbeddedAudio && board == "rockpi-4c") [
      "SND_SOC"
      "SND_SOC_ROCKCHIP_I2S"
      "SND_SOC_ES8316"
      "SND_AUDIO_GRAPH_CARD"
      "SND_SOC_ROCKCHIP_SPDIF"
      "SND_SOC_SPDIF"
    ])
    ++ (lib.optionals (wantEmbeddedAudio && board == "le-potato") [
      "SND_SOC"
      "SND_MESON_GX_SOUND_CARD"
      "SND_MESON_AIU"
      "SND_SOC_MESON_T9015"
    ])
    ++ (lib.optionals (wantEmbeddedAudio && board == "visionfive2") [
      "SND_SOC"
      "SND_SOC_JH7110_PWMDAC"
      "SND_SIMPLE_CARD"
      "SND_SOC_SPDIF"
    ])
    ++ (lib.optionals (wantEmbeddedAudio && board == "yanyu-stx-r19f") [
      "SND_HDA_INTEL"
      "SND_HDA_GENERIC"
      "SND_HDA_CODEC_REALTEK"
      # ALC269 defaults to y once that menu is on. Forcing it n, or forcing
      # the hidden REALTEK_LIB n, drops the parser the controller selects.
      "SND_HDA_CODEC_ALC269"
    ])
    ++ (lib.optional (wantEmbeddedAudio && board == "x86_64-test") "SND_VIRTIO")
  );
  # SND_HDA_HWDEP is a bool. m is not an answer. T-0001.
  keepSoundYes = lib.optionals (wantEmbeddedAudio && board == "yanyu-stx-r19f") [
    "SND_HDA_HWDEP"
  ];
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
  // lib.optionalAttrs wantSound (
    off (drop soundCatalog (keepSound ++ keepSoundYes))
    // asMod keepSound
    // asYes keepSoundYes
    // {
      SOUND = lib.mkForce lib.kernel.module;
      SND = lib.mkForce lib.kernel.module;
      # Pi HDMI scanout depends on SND. The consoles stay serial.
      DRM_VC4 = lib.mkForce (lib.kernel.option lib.kernel.no);
    }
    // lib.optionalAttrs (wantEmbeddedAudio && board == "le-potato") {
      # SND_MESON_CARD_UTILS selects this bool. optional n fights the select.
      SND_DYNAMIC_MINORS = lib.mkForce lib.kernel.yes;
    }
  )
