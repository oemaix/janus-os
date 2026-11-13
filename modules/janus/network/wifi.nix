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
  apNames = lib.attrNames cfg.wifi;
  secretNames = lib.filter (name: cfg.wifi.${name}.passphraseSecret != null) apNames;

  onboardAp = ap: let
    periph = hw.${ap.peripheral} or null;
  in
    periph != null && periph.match.onboard;

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
    isolate = onboard && builtins.hasAttr ap.lan cfg.lans && cfg.lans.${ap.lan}.isolation;
  launch =
    if usbId name == "0bda:8176"
    then ''
      # The shell stays up. A recreated wifi-* does not start this unit
      # again while it is active, and a zero exit does not trigger
      # Restart= (T-0034).
      sysroot=''${JANUS_SYS:-/sys}
      rtl_ready() {
        local link
        [ -L "$sysroot/class/net/${dev}/device/driver" ] || return 1
        link=$(readlink "$sysroot/class/net/${dev}/device/driver") || return 1
        [ "$(basename "$link")" = rtl8192cu ]
      }
      fails=0
      while true; do
        i=0
        while ! rtl_ready; do
          if [ "$i" -ge 150 ]; then
            echo "janus: ${dev} is not on rtl8192cu" >&2
            exit 1
          fi
          i=$((i + 1))
          sleep 0.2
        done
        ${pkgs.hostapd}/bin/hostapd "$run/${name}.conf" &
        pid=$!
        miss=0
        while kill -0 "$pid" 2>/dev/null; do
          if rtl_ready; then
            miss=0
          else
            miss=$((miss + 1))
            if [ "$miss" -ge 2 ]; then
              kill "$pid" 2>/dev/null || true
              k=0
              while kill -0 "$pid" 2>/dev/null && [ "$k" -lt 10 ]; do
                k=$((k + 1))
                sleep 0.2
              done
              kill -9 "$pid" 2>/dev/null || true
              break
            fi
          fi
          sleep 1
        done
        wait "$pid" || true
        if rtl_ready; then
          fails=$((fails + 1))
          if [ "$fails" -ge 5 ]; then
            echo "janus: ${dev} hostapd exited" >&2
            exit 1
          fi
          sleep 3
        else
          fails=0
        fi
      done
    ''
    else if isolate
    then ''
        ${pkgs.hostapd}/bin/hostapd "$run/${name}.conf" &
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
        exec ${pkgs.hostapd}/bin/hostapd "$run/${name}.conf"
      '';
  in
    pkgs.writeShellScript "hostapd-${name}" ''
      set -euo pipefail
      run=''${JANUS_WIFI_RUN:-/run/janus/wifi}
      install -d -m 0755 "$run"
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
        ${lib.optionalString onboard ''printf '%s\n' "wmm_enabled=1" "ht_capab=[HT20][SHORT-GI-20]"''}
        ${lib.optionalString (ap.security != "wpa2") ''printf '%s\n' "ieee80211w=1"''}
        ${lib.optionalString ap.hidden ''printf '%s\n' "ignore_broadcast_ssid=1"''}
      } > "$run/${name}.conf"
      ${lib.optionalString onboard ''
        ${pkgs.iproute2}/bin/ip link set dev ${dev} nomaster || true
        ${pkgs.iproute2}/bin/ip link set dev ${dev} down
        ${pkgs.iw}/bin/iw dev ${dev} set type __ap
      ''}
      ${launch}
    '';

  usbId = name: hw.${cfg.wifi.${name}.peripheral}.match.usbVendorProduct or null;

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
  # rtl8192cu picks one of these names from the chip revision.
  rtl8188cusFirmware = firmwareSlice {
    pname = "rtl8192cu-firmware";
    description = "Firmware for RTL8188CUS";
    paths = [
      "rtlwifi/rtl8192cufw.bin"
      "rtlwifi/rtl8192cufw_A.bin"
      "rtlwifi/rtl8192cufw_B.bin"
      "rtlwifi/rtl8192cufw_TMSC.bin"
    ];
  };
  # rtl8xxxu requests this name for 0bda:8179. docs/10 §4.11.
  rtl8188euFirmware = firmwareSlice {
    pname = "rtl8188eu-firmware";
    description = "Firmware for RTL8188EUS";
    paths = ["rtlwifi/rtl8188eufw.bin"];
  };
  # 0bda:8176 is also in the rtl8xxxu table. Bind that ID to rtl8192cu
  # and leave rtl8xxxu loaded for 0bda:8179. remove_id does not drop a
  # static id, so driver_override is set before the unbind (T-0033).
  # docs/10 §4.4, D-0063.
  rtl8192cuBind = pkgs.writeShellScript "janus-rtl8192cu-bind" ''
    set -eu
    # JANUS_SYS is the sysfs root. The image leaves it unset.
    sysroot=''${JANUS_SYS:-/sys}
    iface_sys() {
      case "$1" in
        "$sysroot"/*) printf '%s\n' "$1" ;;
        /*) printf '%s\n' "$sysroot$1" ;;
        *) printf '%s\n' "$sysroot/$1" ;;
      esac
    }
    driver_of() {
      if [ -L "$1/driver" ]; then
        basename "$(readlink "$1/driver")"
      fi
    }
    # devices/1-2:1.0 is a symlink into 1-2/1-2:1.0. dirname of the bus
    # path is devices/, which has no idVendor (T-0033).
    usb_device_dir() {
      dirname "$(readlink -f "$1")"
    }
    # driver_override is set before the unbind. remove_id leaves the
    # static id, so rtl8xxxu would take the stick back (T-0033).
    override_is() {
      local cur
      [ -f "$1/driver_override" ] || return 1
      cur=$(cat "$1/driver_override" 2>/dev/null || true)
      [ "$cur" = rtl8192cu ]
    }
    bind_one() {
      local sys kernel drv
      sys=$(iface_sys "$1")
      kernel=$2
      [ -e "$sys" ] || return 0
      if [ -f "$sys/driver_override" ]; then
        printf '%s\n' rtl8192cu > "$sys/driver_override" || true
      fi
      drv=$(driver_of "$sys" || true)
      if [ "$drv" = rtl8192cu ]; then
        return 0
      fi
      if [ "$drv" = rtl8xxxu ]; then
        override_is "$sys" || return 0
        printf '%s\n' "$kernel" > "$sysroot/bus/usb/drivers/rtl8xxxu/unbind" || true
      fi
      if [ -e "$sysroot/bus/usb/drivers/rtl8192cu/bind" ]; then
        printf '%s\n' "$kernel" > "$sysroot/bus/usb/drivers/rtl8192cu/bind" || true
      fi
    }
    # The USB driver link flips to rtl8192cu before the netdev is
    # registered and renamed off wlanN (T-0034).
    iface_ready() {
      local sys ent base
      sys=$(readlink -f "$(iface_sys "$1")")
      [ "$(driver_of "$sys" || true)" = rtl8192cu ] || return 1
      for ent in "$sys"/net/*; do
        [ -e "$ent" ] || return 1
        base=$(basename "$ent")
        case "$base" in
          wlan[0-9]*) return 1 ;;
        esac
        return 0
      done
      return 1
    }
    # A bind write while the probe is running can restart it, so retry
    # about once a second instead of on every poll (T-0033).
    wait_bound() {
      local sys kernel i j drv
      sys=$1
      kernel=$2
      i=0
      while [ "$i" -lt 60 ]; do
        if iface_ready "$sys"; then
          return 0
        fi
        bind_one "$sys" "$kernel"
        j=0
        while [ "$j" -lt 5 ]; do
          if iface_ready "$sys"; then
            return 0
          fi
          j=$((j + 1))
          sleep 0.2
        done
        i=$((i + 1))
      done
      drv=$(driver_of "$(iface_sys "$sys")" || true)
      echo "janus: 0bda:8176 stayed on ''${drv:-unbound}" >&2
      return 1
    }
    bind_present() {
      for sys in "$sysroot"/bus/usb/devices/*:*; do
        [ -d "$sys" ] || continue
        parent=$(usb_device_dir "$sys")
        vendor=$(cat "$parent/idVendor" 2>/dev/null || true)
        product=$(cat "$parent/idProduct" 2>/dev/null || true)
        if [ "$vendor" = 0bda ] && [ "$product" = 8176 ]; then
          name=$(basename "$(readlink -f "$sys")")
          wait_bound "$sys" "$name"
        fi
      done
    }
    if [ "$#" -eq 2 ]; then
      wait_bound "$(iface_sys "$1")" "$2"
      exit 0
    fi
    # udev-settle does not wait for this port. A stick that shows up
    # during this window is bound here; a later add starts the oneshot
    # again (T-0033).
    i=0
    while [ "$i" -lt 30 ]; do
      found=0
      for sys in "$sysroot"/bus/usb/devices/*:*; do
        [ -d "$sys" ] || continue
        parent=$(usb_device_dir "$sys")
        vendor=$(cat "$parent/idVendor" 2>/dev/null || true)
        product=$(cat "$parent/idProduct" 2>/dev/null || true)
        if [ "$vendor" = 0bda ] && [ "$product" = 8176 ]; then
          found=1
          break
        fi
      done
      if [ "$found" = 1 ]; then
        bind_present
        exit 0
      fi
      i=$((i + 1))
      sleep 1
    done
  '';

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

  piBoards = ["rpi-zero-2w" "rpi3" "rpi4"];
  piRadio = lib.elem config.janus.hardware.board piBoards;
  # Pi 4 enables this host for the SD card in the board profile. docs/10 §4.12.
  piSdioAp = lib.elem config.janus.hardware.board ["rpi-zero-2w" "rpi3"];

  vendor = id: builtins.substring 0 4 id;
  product = id: builtins.substring 5 4 id;
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
        (lib.mkIf (lib.elem "0bda:8176" declaredUsbIds) [rtl8188cusFirmware])
        (lib.mkIf (lib.elem "0bda:8179" declaredUsbIds) [rtl8188euFirmware])
      ];
      # Declaring the stick loads its driver. An access point is not required.
      boot.kernelModules = lib.mkMerge [
        (lib.mkIf (lib.elem "0bda:8176" declaredUsbIds) ["rtl8192cu"])
        (lib.mkIf (lib.elem "0bda:8179" declaredUsbIds) ["rtl8xxxu"])
      ];
      services.udev.extraRules = lib.mkIf (lib.elem "0bda:8176" declaredUsbIds) ''
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8176", TAG+="systemd", ENV{SYSTEMD_WANTS}+="janus-rtl8192cu-bind.service"
      '';
      systemd.services = lib.mkIf (lib.elem "0bda:8176" declaredUsbIds) {
        janus-rtl8192cu-bind = {
          description = "Bind 0bda:8176 to rtl8192cu";
          wantedBy = ["multi-user.target"];
          after = ["systemd-modules-load.service" "systemd-udev-settle.service"];
          # Stay inactive after a successful run. A later USB add can start
          # this again. RemainAfterExit would make that add a no-op (T-0033).
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
            ExecStart = rtl8192cuBind;
          };
        };
      };
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
        ++ [
          {
            assertion = lib.length onboardNames <= 1;
            message = "Only one access point can use the onboard radio. docs/10 §4.7, §4.10, and §4.12.";
          }
        ];

      services.udev.extraRules = lib.concatMapStrings (name: let
        id = usbId name;
      in
        lib.optionalString (id != null) ''
          SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", NAME="${iface name}"${
            lib.optionalString (id == "0bda:8176") '', TAG+="systemd", ENV{SYSTEMD_WANTS}+="janus-hostapd-${name}.service"''
          }
        '')
      apNames;

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
                ++ lib.optional (usbId name == "0bda:8176") "janus-rtl8192cu-bind.service";
              # The rebind destroys wifi-*. Want the bind oneshot. Requiring
              # it would stop hostapd when that oneshot exits, because it
              # does not stay active (T-0033). 0bda:8176 does not bind to
              # the netdev unit. The shell stays up and starts hostapd
              # again when wifi-* returns (T-0034).
              wants =
                [(bridgeUnit cfg.wifi.${name}.lan)]
                ++ lib.optional (usbId name == "0bda:8176") "janus-rtl8192cu-bind.service";
              requires = lib.optional (cfg.wifi.${name}.passphraseSecret != null) "janus-wifi-secret-${name}.service";
              bindsTo = lib.optionals (usbId name != "0bda:8176") [(deviceUnit name)];
              serviceConfig = {
                Type = "simple";
                ExecStart = start name cfg.wifi.${name};
                Restart = "on-failure";
                RestartSec = "3s";
              };
            };
          })
          apNames)
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
