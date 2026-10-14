# SPDX-License-Identifier: Apache-2.0
# Wi-Fi access points. docs/06 §11, docs/10 §4.4.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.network;
  hw = config.janus.hardware.peripherals;
  apNames = lib.attrNames cfg.wifi;

  iface = name: "wifi-${name}";

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
    secret =
      if ap.passphraseSecret != null
      then "/run/secrets/${ap.passphraseSecret}"
      else if ap.passphraseFile != null
      then ap.passphraseFile
      else "/var/lib/janus/wifi/${name}.passphrase";
  in
    pkgs.writeShellScript "hostapd-${name}" ''
      set -euo pipefail
      install -d -m 0755 /run/janus/wifi
      if [ -s /var/lib/janus/secrets/wifi-${name} ]; then
        src=/var/lib/janus/secrets/wifi-${name}
      else
        src=${lib.escapeShellArg secret}
      fi
      if [ ! -s "$src" ]; then
        echo "janus: Wi-Fi ${name} has no passphrase" >&2
        exit 1
      fi
      umask 077
      pass=$(tr -d '\n' < "$src")
      ssid=${lib.escapeShellArg ap.ssid}
      {
        printf '%s\n' "interface=${iface name}" "bridge=br-${ap.lan}" "driver=nl80211"
        printf 'ssid=%s\n' "$ssid"
        printf '%s\n' "wpa=2" "wpa_key_mgmt=${keyMgmt ap}" "rsn_pairwise=CCMP" "hw_mode=${bandMode ap}" "channel=${channel ap}" "ieee80211n=1"
        printf 'wpa_passphrase=%s\n' "$pass"
        ${lib.optionalString (ap.security != "wpa2") ''printf '%s\n' "ieee80211w=1"''}
        ${lib.optionalString ap.hidden ''printf '%s\n' "ignore_broadcast_ssid=1"''}
      } > /run/janus/wifi/${name}.conf
      exec ${pkgs.hostapd}/bin/hostapd /run/janus/wifi/${name}.conf
    '';

  usbId = name: hw.${cfg.wifi.${name}.peripheral}.match.usbVendorProduct or null;

  vendor = id: builtins.substring 0 4 id;
  product = id: builtins.substring 5 4 id;
in {
  config = lib.mkIf (apNames != []) {
    boot.kernelModules = lib.mkIf (lib.any (n: usbId n == "0bda:8176") apNames) ["rtl8192cu"];
    boot.blacklistedKernelModules = lib.mkIf (lib.any (n: usbId n == "0bda:8176") apNames) ["rtl8xxxu"];

    services.udev.extraRules = lib.concatMapStrings (name: let
      id = usbId name;
    in
      lib.optionalString (id != null) ''
        SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", NAME="${iface name}"
      '')
    apNames;

    systemd.services =
      lib.listToAttrs (map (name: {
          name = "janus-hostapd-${name}";
          value = {
            description = "Wi-Fi access point ${name}";
            wantedBy = ["multi-user.target"];
            enable = true;
            after = ["systemd-networkd.service" "sys-subsystem-net-devices-${iface name}.device"];
            bindsTo = ["sys-subsystem-net-devices-${iface name}.device"];
            serviceConfig = {
              Type = "simple";
              ExecStart = start name cfg.wifi.${name};
              Restart = "on-failure";
              RestartSec = "3s";
            };
          };
        })
        apNames)
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
  };
}
