# SPDX-License-Identifier: Apache-2.0
# Wi-Fi access points. docs/06 §11, docs/10 §4.4, §4.7, and §4.8.
{
  config,
  lib,
  pkgs,
  janusBuildPkgs ? pkgs,
  ...
}: let
  cfg = config.janus.network;
  hw = config.janus.hardware.peripherals;
  allow = import ../hardware/allowlist.nix;
  match = import ./wifi-match.nix {inherit lib;};
  apNames = lib.attrNames cfg.wifi;
  secretNames = lib.filter (name: cfg.wifi.${name}.passphraseSecret != null) apNames;

  onboardAp = ap: let
    periph = hw.${ap.peripheral} or null;
  in
    periph != null && periph.match.onboard;

  usbRow = ap: let
    periph = hw.${ap.peripheral} or null;
    id = if periph == null then null else periph.match.usbVendorProduct or null;
  in
    if id == null
    then null
    else allow.usb.${id} or null;

  # A USB row that lists bands is a fixed radio, same checks as onboard.
  limitedUsb = ap: let
    row = usbRow ap;
  in
    row != null && (row.bands or []) != [];

  onboardNames = lib.filter (name: onboardAp cfg.wifi.${name}) apNames;

  iface = name: "wifi-${name}";

  deviceUnit = name: "sys-subsystem-net-devices-${lib.replaceStrings ["-"] ["\\x2d"] (iface name)}.device";

  # systemd-escape -p of /sys/subsystem/net/devices/br-<lan>.
  bridgeUnit = lan: "sys-subsystem-net-devices-${lib.replaceStrings ["-"] ["\\x2d"] "br-${lan}"}.device";

  channel = ap:
    if ap.channel == "auto"
    then
      (
        if ap.band == "5g"
        then "36"
        else "6"
      )
    else toString ap.channel;

  bandMode = ap:
    if ap.band == "5g"
    then "a"
    else "g";

  keyMgmt = ap:
    if ap.security == "wpa3"
    then "SAE"
    else if ap.security == "wpa2+3"
    then "WPA-PSK SAE"
    else "WPA-PSK";

  start = name: ap: let
    dev = iface name;
    secret =
      if ap.passphraseSecret != null
      then config.sops.secrets.${ap.passphraseSecret}.path
      else if ap.passphraseFile != null
      then ap.passphraseFile
      else "/var/lib/janus/wifi/${name}.passphrase";
    onboard = onboardAp ap;
    # rtl8xxxu has no 40 MHz channels. Pin HT20 the way the onboard radios do.
    ht20 = onboard || limitedUsb ap;
    isolate = onboard && builtins.hasAttr ap.lan cfg.lans && cfg.lans.${ap.lan}.isolation;
    launch =
      if isolate
      then ''
        ${pkgs.hostapd}/bin/hostapd /run/janus/wifi/${name}.conf &
        pid=$!
        i=0
        joined=0
        while [ "$i" -lt 50 ]; do
          if ${pkgs.iproute2}/bin/bridge link show dev ${dev} >/dev/null 2>&1; then
            ${pkgs.iproute2}/bin/bridge link set dev ${dev} isolated on
            joined=1
            break
          fi
          if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || exit $?
            echo "janus: Wi-Fi ${name} exited before joining br-${ap.lan}" >&2
            exit 1
          fi
          i=$((i + 1))
          sleep 0.2
        done
        if [ "$joined" != 1 ]; then
          echo "janus: Wi-Fi ${name} did not join br-${ap.lan}" >&2
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          exit 1
        fi
        if ! ${pkgs.iproute2}/bin/bridge link show dev ${dev} | grep -q isolated; then
          echo "janus: Wi-Fi ${name} bridge port is not isolated" >&2
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          exit 1
        fi
        wait "$pid"
      ''
      else ''
        exec ${pkgs.hostapd}/bin/hostapd /run/janus/wifi/${name}.conf
      '';
  in
    pkgs.writeShellScript "hostapd-${name}" ''
      set -euo pipefail
      install -d -m 0755 /run/janus/wifi
      # The hot override is a board file. It wins over the sops passphrase.
      over=''${JANUS_WIFI_PASS:-/var/lib/janus/secrets/wifi-${name}}
      if [ -s "$over" ]; then
        src=$over
      else
        src=''${JANUS_WIFI_SOPS:-${lib.escapeShellArg secret}}
      fi
      if [ ! -s "$src" ]; then
        echo "janus: Wi-Fi ${name} has no passphrase" >&2
        exit 1
      fi
      umask 077
      pass=$(tr -d '\n' < "$src")
      ssid=${lib.escapeShellArg ap.ssid}
      {
        printf '%s\n' "interface=${dev}" "bridge=br-${ap.lan}" "driver=nl80211"
        printf 'ssid=%s\n' "$ssid"
        printf '%s\n' "wpa=2" "wpa_key_mgmt=${keyMgmt ap}" "rsn_pairwise=CCMP" "hw_mode=${bandMode ap}" "channel=${channel ap}" "ieee80211n=1" "country_code=${cfg.wifiCountry}" "ieee80211d=1"
        printf 'wpa_passphrase=%s\n' "$pass"
        ${lib.optionalString ht20 ''printf '%s\n' "wmm_enabled=1" "ht_capab=[HT20][SHORT-GI-20]"''}
        ${lib.optionalString (ap.security != "wpa2") ''printf '%s\n' "ieee80211w=1"''}
        ${lib.optionalString ap.hidden ''printf '%s\n' "ignore_broadcast_ssid=1"''}
      } > /run/janus/wifi/${name}.conf
      ${lib.optionalString onboard ''
        ${pkgs.iproute2}/bin/ip link set dev ${dev} nomaster || true
        ${pkgs.iproute2}/bin/ip link set dev ${dev} down
        ${pkgs.iw}/bin/iw dev ${dev} set type __ap
      ''}
      ${launch}
    '';

  # USB ids of declared peripherals. The board is not part of the match.
  declaredUsbIds = lib.mapAttrsToList (_: p: p.match.usbVendorProduct or null) hw;

  firmwareSlice = import ../hardware/firmware-slice.nix {
    inherit lib pkgs;
    builderPkgs = janusBuildPkgs;
  };
  # mt76x2u requests these two names at the firmware root. linux-firmware
  # ships them as links; the copy is a regular file at the requested path.
  mt7612uFirmware = firmwareSlice {
    pname = "mt7662-firmware";
    description = "Firmware for MT7612U";
    paths = ["mt7662.bin" "mt7662_rom_patch.bin"];
  };
  mt7921auFirmware = firmwareSlice {
    pname = "mt7921-firmware";
    description = "Firmware for MT7921AU";
    paths = [
      "mediatek/WIFI_RAM_CODE_MT7961_1.bin"
      "mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin"
    ];
  };
  # rtl8xxxu picks one of these three from the chip revision. docs/10 §4.4.
  rtl8188cusFirmware = firmwareSlice {
    pname = "rtl8192cu-firmware";
    description = "Firmware for RTL8188CUS";
    paths = [
      "rtlwifi/rtl8192cufw_A.bin"
      "rtlwifi/rtl8192cufw_B.bin"
      "rtlwifi/rtl8192cufw_TMSC.bin"
    ];
  };
  rtl8188eusFirmware = firmwareSlice {
    pname = "rtl8188eu-firmware";
    description = "Firmware for RTL8188EUS";
    paths = ["rtlwifi/rtl8188eufw.bin"];
  };
  rtl8192euFirmware = firmwareSlice {
    pname = "rtl8192eu-firmware";
    description = "Firmware for RTL8192EU";
    paths = ["rtlwifi/rtl8192eu_nic.bin"];
  };
  rtl8188fuFirmware = firmwareSlice {
    pname = "rtl8188fu-firmware";
    description = "Firmware for RTL8188FU";
    paths = ["rtlwifi/rtl8188fufw.bin"];
  };
  # The 43436s chip asks for its own CLM name. The Raspberry Pi package
  # ships that blob only as brcmfmac43436-sdio.clm_blob. docs/10 §4.7.
  zero2wClm = janusBuildPkgs.runCommand "brcmfmac43436s-clm" {
    preferLocalBuild = true;
    meta = {
      description = "43436 CLM blob under the 43436s names the Zero 2 W requests";
      license = lib.licenses.unfreeRedistributableFirmware;
      sourceProvenance = with lib.sourceTypes; [binaryFirmware];
    };
  } ''
    mkdir -p "$out/lib/firmware/brcm"
    src=${pkgs.raspberrypiWirelessFirmware}/lib/firmware/brcm/brcmfmac43436-sdio.clm_blob
    cp -L "$src" "$out/lib/firmware/brcm/brcmfmac43436s-sdio.clm_blob"
    cp -L "$src" "$out/lib/firmware/brcm/brcmfmac43436s-sdio.raspberrypi,model-zero-2-w.clm_blob"
  '';

  hasUsb = id: lib.elem id declaredUsbIds;
  # 8176, 8179, 818b, and f179. docs/10 §4.4.
  realtekUsb = lib.any hasUsb ["0bda:8176" "0bda:8179" "0bda:818b" "0bda:f179"];
  piBoards = ["rpi-zero-2w" "rpi3" "rpi4"];
  piRadio = lib.elem config.janus.hardware.board piBoards;
  # Pi 4 enables this host for the SD card in the board profile. docs/10 §4.12.
  piSdioAp = lib.elem config.janus.hardware.board ["rpi-zero-2w" "rpi3"];

  staUplinks = map (n: cfg.wans.${n}.uplink) (
    lib.filter (n: cfg.wans.${n}.mode == "wifi") (lib.attrNames cfg.wans)
  );
  wanOf = periph:
    lib.findFirst (n: cfg.wans.${n}.mode == "wifi" && cfg.wans.${n}.uplink == periph) null (
      lib.attrNames cfg.wans
    );
  # One radio used as the access point and the station. docs/06 §11, D-0066.
  concurrent = lib.filter (p: lib.elem p (map (n: cfg.wifi.${n}.peripheral) apNames)) staUplinks;
  apNameOf = periph: lib.findFirst (n: cfg.wifi.${n}.peripheral == periph) null apNames;

  rename = name: periph: let
    p = hw.${periph} or null;
    id = if p == null then null else p.match.usbVendorProduct or null;
  in
    if id == null
    then ""
    else
      match.renameRule {
        inherit id;
        inherit name;
        usbPath = p.match.usbPath or null;
        mac = p.match.mac or null;
      };

  vif = periph: let
    apName = apNameOf periph;
    wan = wanOf periph;
    apDev = iface apName;
    staDev = "wifi-${periph}";
  in
    pkgs.writeShellScript "wifi-vif-${periph}" ''
      set -eu
      if [ -e /sys/class/net/${staDev} ]; then
        exit 0
      fi
      phy=$(basename "$(readlink -f /sys/class/net/${apDev}/phy80211)")
      exec ${pkgs.iw}/bin/iw phy "$phy" interface add ${staDev} type managed
    '';
in {
  config = lib.mkMerge [
    {
      # One regulatory domain. The region is the censorship environment;
      # these letters are only the default country. docs/06 §11, D-0054.
      janus.network.wifiCountry = lib.mkOptionDefault (
        {
          cn = "CN";
          ru = "RU";
          ir = "IR";
        }
        .${
          config.janus.system.region
        }
      );
      assertions = [
        {
          # Reading the value applies the type. An unused access-point list would not.
          assertion = builtins.match "[A-Z]{2}" cfg.wifiCountry != null;
          message = "janus.network.wifiCountry must be two uppercase letters. docs/06 §11.";
        }
      ];
      # docs/10 §4.4 and §4.8. The stick is declared on whichever board the config names.
      hardware.firmware = lib.mkMerge [
        (lib.mkIf (lib.elem "0e8d:7612" declaredUsbIds) [mt7612uFirmware])
        (lib.mkIf (lib.elem "0e8d:7961" declaredUsbIds) [mt7921auFirmware])
        (lib.mkIf (hasUsb "0bda:8176") [rtl8188cusFirmware])
        (lib.mkIf (hasUsb "0bda:8179") [rtl8188eusFirmware])
        (lib.mkIf (hasUsb "0bda:818b") [rtl8192euFirmware])
        (lib.mkIf (hasUsb "0bda:f179") [rtl8188fuFirmware])
      ];
      # One driver. rtl8192cu still lists 0bda:8176, so that id keeps it
      # from autoloading. Do not blacklist rtl8xxxu. Do not rebind (T-0040).
      boot.kernelModules = lib.mkIf realtekUsb ["rtl8xxxu"];
      boot.blacklistedKernelModules = lib.mkIf (hasUsb "0bda:8176") ["rtl8192cu"];
    }
    (lib.mkIf (apNames != []) {
      boot.kernelModules = lib.mkMerge [
        # The Arasan host is not in the initrd. Stage 2 loads it with brcmfmac.
        # The Pi 4 host is built in, so it is not named here.
        (lib.mkIf (onboardNames != [] && lib.elem config.janus.hardware.board ["rpi-zero-2w" "rpi3"]) ["sdhci_iproc"])
        (lib.mkIf (onboardNames != []) ["brcmfmac"])
      ];
      # The NixOS arm64 config answers MMC_SDHCI_IPROC=m. The Pi 3 profile
      # pins n until this access point. The Pi 4 profile pins y because
      # that host is also the SD card. docs/10 §4.7 and §4.12, T-0007.
      # The ROCK Pi 4C radio is on dw_mmc.
      boot.kernelPatches = lib.mkIf (onboardNames != [] && piSdioAp) [
        {
          name = "janus-rpi-onboard-wifi";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            MMC_SDHCI_IPROC = module;
            BRCMFMAC = module;
            BRCMFMAC_SDIO = yes;
          };
        }
      ];
      hardware.firmware = lib.mkIf (onboardNames != [] && piRadio) (
        [pkgs.raspberrypiWirelessFirmware]
        ++ lib.optional (config.janus.hardware.board == "rpi-zero-2w") zero2wClm
      );
      systemd.network.links = lib.listToAttrs (map (name: {
          name = "10-wifi-${name}";
          value = {
            matchConfig = {
              Driver = "brcmfmac";
              Type = "wlan";
              OriginalName = "wlan*";
            };
            linkConfig.Name = iface name;
          };
        })
        onboardNames);

      assertions =
        lib.concatMap (name: let
          ap = cfg.wifi.${name};
          row = allow.onboard.${config.janus.hardware.board} or null;
        in
          lib.optionals (onboardAp ap) [
            {
              assertion = row != null && lib.elem ap.band (row.bands or []);
              message = "janus.network.wifi.${name}.band = ${ap.band} is not a band of the onboard radio. docs/10 §4.7, §4.10, and §4.12.";
            }
            {
              assertion = row != null && lib.elem ap.security (row.security or []);
              message = "janus.network.wifi.${name}.security = ${ap.security} is not supported on the onboard radio. docs/10 §4.7, §4.10, and §4.12.";
            }
            {
              assertion =
                row
                != null
                && (
                  ap.channel
                  == "auto"
                  || (lib.isInt ap.channel && lib.elem ap.channel (row.channels or []))
                );
              message = "janus.network.wifi.${name}.channel is not a channel of the onboard radio. docs/10 §4.7, §4.10, and §4.12.";
            }
          ])
        apNames
        ++ lib.concatMap (name: let
          ap = cfg.wifi.${name};
          row = usbRow ap;
        in
          lib.optionals (limitedUsb ap) [
            {
              assertion = lib.elem ap.band (row.bands or []);
              message = "janus.network.wifi.${name}.band = ${ap.band} is not a band of this USB radio. docs/10 §4.4.";
            }
            {
              assertion = lib.elem ap.security (row.security or []);
              message = "janus.network.wifi.${name}.security = ${ap.security} is not supported on this USB radio. docs/10 §4.4.";
            }
            {
              assertion =
                ap.channel
                == "auto"
                || (lib.isInt ap.channel && lib.elem ap.channel (row.channels or []));
              message = "janus.network.wifi.${name}.channel is not a channel of this USB radio. docs/10 §4.4.";
            }
          ])
        apNames
        ++ [
          {
            assertion = lib.length onboardNames <= 1;
            message = "Only one access point can use the onboard radio. docs/10 §4.7, §4.10, and §4.12.";
          }
        ];

      services.udev.extraRules = lib.concatMapStrings (name: rename (iface name) cfg.wifi.${name}.peripheral) apNames;

      systemd.services =
        lib.listToAttrs (map (name: {
            name = "janus-hostapd-${name}";
            value = {
              description = "Wi-Fi access point ${name}";
              wantedBy = ["multi-user.target"];
              enable = true;
              # networkd creates br-* after its own start. dnsmasq waits for
              # the same device. Onboard ports are unmanaged, so nothing else
              # joins the bridge if hostapd runs too early. docs/10 §4.7.
              after =
                ["systemd-networkd.service" (deviceUnit name) (bridgeUnit cfg.wifi.${name}.lan)]
                ++ lib.optional (cfg.wifi.${name}.passphraseSecret != null) "janus-wifi-secret-${name}.service"
                ++ lib.optional (lib.elem cfg.wifi.${name}.peripheral concurrent) "janus-wifi-vif-${cfg.wifi.${name}.peripheral}.service";
              wants =
                [(bridgeUnit cfg.wifi.${name}.lan)]
                ++ lib.optional (lib.elem cfg.wifi.${name}.peripheral concurrent) "janus-wifi-vif-${cfg.wifi.${name}.peripheral}.service";
              requires = lib.optional (cfg.wifi.${name}.passphraseSecret != null) "janus-wifi-secret-${name}.service";
              bindsTo = [(deviceUnit name)];
              serviceConfig = {
                Type = "simple";
                ExecStart = start name cfg.wifi.${name};
                Restart = "on-failure";
                RestartSec = "3s";
              };
            };
          })
          apNames)
        // lib.listToAttrs (map (periph: let
          apName = apNameOf periph;
          wan = wanOf periph;
        in {
          name = "janus-wifi-vif-${periph}";
          value = {
            description = "Second Wi-Fi interface on ${periph}";
            after = [(deviceUnit apName)];
            before = ["janus-hostapd-${apName}.service" "janus-wpa-${wan}.service"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = vif periph;
            };
          };
        })
        concurrent)
        // lib.listToAttrs (map (name: {
            name = "janus-wifi-secret-${name}";
            value = {
              description = "Wi-Fi passphrase for ${name}";
              before = ["janus-hostapd-${name}.service"];
              after = ["sops-install-secrets.service"];
              # wants, not requires. A failed sops unit must not hide a hot override.
              wants = ["sops-install-secrets.service"];
              # No Restart. An empty pair of files fails once and stays failed, so
              # install-age-key can restart it. hostapd still restarts on a crash.
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = pkgs.writeShellScript "janus-wifi-secret-${name}" ''
                  set -eu
                  over=''${JANUS_WIFI_PASS:-/var/lib/janus/secrets/wifi-${name}}
                  src=''${JANUS_WIFI_SOPS:-${lib.escapeShellArg config.sops.secrets.${cfg.wifi.${name}.passphraseSecret}.path}}
                  if [ -s "$over" ] || [ -s "$src" ]; then
                    exit 0
                  fi
                  echo "janus: Wi-Fi ${name} has no passphrase" >&2
                  exit 1
                '';
              };
            };
          })
          secretNames)
        // lib.optionalAttrs (lib.any (n: cfg.wifi.${n}.passphrase != null) apNames) {
          janus-wifi-passphrases = {
            description = "Install inline Wi-Fi passphrases";
            wantedBy = ["multi-user.target"];
            before = map (n: "janus-hostapd-${n}.service") apNames;
            serviceConfig.Type = "oneshot";
            script = ''
              umask 077
              mkdir -p /var/lib/janus/wifi
              ${lib.concatMapStrings (name: let
                ap = cfg.wifi.${name};
              in
                lib.optionalString (ap.passphrase != null) ''
                  printf '%s\n' ${lib.escapeShellArg ap.passphrase} > /var/lib/janus/wifi/${lib.escapeShellArg name}.passphrase
                '')
              apNames}
            '';
          };
        };

      environment.etc."janus/wifi.json".text = builtins.toJSON (lib.mapAttrs (name: ap: {
          lan = ap.lan;
          peripheral = ap.peripheral;
          passphraseSecret = ap.passphraseSecret;
        })
        cfg.wifi);
    })
  ];
}
