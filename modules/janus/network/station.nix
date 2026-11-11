# SPDX-License-Identifier: Apache-2.0
# WPA2 station uplink. docs/06 §4 and §11, docs/10 §4.11, D-0063.
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.janus.network;
  hw = config.janus.hardware.peripherals;
  staNames = lib.filter (n: cfg.wans.${n}.mode == "wifi") (lib.attrNames cfg.wans);

  iface = wan: "wifi-${cfg.wans.${wan}.uplink}";

  deviceUnit = wan: "sys-subsystem-net-devices-${lib.replaceStrings ["-"] ["\\x2d"] (iface wan)}.device";

  quote = s: "\"${lib.replaceStrings ["\\" "\""] ["\\\\" "\\\""] s}\"";

  indexed = wan:
    lib.imap0 (i: net: net // {i = i;}) cfg.wans.${wan}.wifi.networks;

  ordered = wan: lib.sort (a: b: a.priority > b.priority) (indexed wan);

  hasSecret = wan: lib.any (net: net.passphraseSecret != null) cfg.wans.${wan}.wifi.networks;

  hasInline = wan: lib.any (net: net.passphrase != null) cfg.wans.${wan}.wifi.networks;

  sourceOf = wan: net:
    if net.passphraseSecret != null
    then
      if (options ? sops) && config.sops.secrets ? ${net.passphraseSecret}
      then config.sops.secrets.${net.passphraseSecret}.path
      else "/run/secrets/${net.passphraseSecret}"
    else if net.passphraseFile != null
    then net.passphraseFile
    else "/var/lib/janus/wifi/sta-${wan}-${toString net.i}.passphrase";

  usbId = wan: hw.${cfg.wans.${wan}.uplink}.match.usbVendorProduct or null;
  vendor = id: builtins.substring 0 4 id;
  product = id: builtins.substring 5 4 id;

  start = wan:
    pkgs.writeShellScript "wpa-${wan}" ''
      set -euo pipefail
      install -d -m 0755 /run/janus/wifi
      umask 077
      {
        printf '%s\n' "country=${cfg.wifiCountry}"
        ${lib.concatMapStrings (net: ''
            src=${lib.escapeShellArg (sourceOf wan net)}
            if [ ! -s "$src" ]; then
              echo "janus: station ${wan} has no passphrase" >&2
              exit 1
            fi
            pass=$(tr -d '\n' < "$src")
            len=''${#pass}
            if [ "$len" -lt 8 ] || [ "$len" -gt 63 ]; then
              echo "janus: station ${wan} passphrase must be 8 to 63 characters" >&2
              exit 1
            fi
            pass=$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '%s\n' "network={"
            printf 'ssid=%s\n' ${lib.escapeShellArg (quote net.ssid)}
            printf 'psk="%s"\n' "$pass"
            printf '%s\n' "key_mgmt=WPA-PSK" "proto=RSN" "pairwise=CCMP" "priority=${toString net.priority}" "scan_ssid=1" "}"
          '')
          (ordered wan)}
      } > /run/janus/wifi/sta-${wan}.conf
      exec ${pkgs.wpa_supplicant}/bin/wpa_supplicant -s -i ${iface wan} -D nl80211 -c /run/janus/wifi/sta-${wan}.conf
    '';
in {
  config = lib.mkIf (staNames != []) {
    services.udev.extraRules = lib.concatMapStrings (wan: let
      id = usbId wan;
    in
      lib.optionalString (id != null) ''
        SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", NAME="${iface wan}"
      '')
    staNames;

    systemd.services =
      lib.listToAttrs (map (wan: {
          name = "janus-wpa-${wan}";
          value = {
            description = "WPA2 station ${wan}";
            wantedBy = ["multi-user.target"];
            after =
              ["systemd-networkd.service" (deviceUnit wan)]
              ++ lib.optional (hasSecret wan) "sops-install-secrets.service"
              ++ lib.optional (hasInline wan) "janus-wifi-sta-passphrases.service";
            wants = lib.optional (hasSecret wan) "sops-install-secrets.service";
            bindsTo = [(deviceUnit wan)];
            serviceConfig = {
              Type = "simple";
              ExecStart = start wan;
              Restart = "on-failure";
              RestartSec = "3s";
            };
          };
        })
        staNames)
      // lib.optionalAttrs (lib.any hasInline staNames) {
        janus-wifi-sta-passphrases = {
          description = "Install inline station passphrases";
          wantedBy = ["multi-user.target"];
          before = map (wan: "janus-wpa-${wan}.service") staNames;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            umask 077
            mkdir -p /var/lib/janus/wifi
            ${lib.concatMapStrings (wan:
                lib.concatMapStrings (net:
                  lib.optionalString (net.passphrase != null) ''
                    printf '%s\n' ${lib.escapeShellArg net.passphrase} > /var/lib/janus/wifi/sta-${wan}-${toString net.i}.passphrase
                  '')
                (indexed wan))
              staNames}
          '';
        };
      };
  };
}
