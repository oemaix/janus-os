# SPDX-License-Identifier: Apache-2.0
# WWAN bring-up. docs/10 §4.2, ADR-0015. No ModemManager.
# usb_modeswitch runs only when the peripheral's modeSwitch set is non-empty.
# The allowlist has no MessageContent, so none is invented.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.network;
  hw = config.janus.hardware.peripherals;
  allow = import ../hardware/allowlist.nix;
  wwanNames = lib.filter (n: cfg.wans.${n}.mode == "wwan") (lib.attrNames cfg.wans);

  peripheral = name: hw.${cfg.wans.${name}.wwan.peripheral};
  usbId = name: (peripheral name).match.usbVendorProduct;
  vendor = id: builtins.substring 0 4 id;
  product = id: builtins.substring 5 4 id;

  effective = name: let
    periph = peripheral name;
    row = allow.usb.${usbId name} or {};
    modes = row.modes or [];
  in
    if periph.wwan.mode == "auto"
    then builtins.head modes
    else periph.wwan.mode;

  iface = name: "wwan-${cfg.wans.${name}.wwan.peripheral}";

  moduleOf = mode:
    {
      ecm = "cdc_ether";
      ncm = "cdc_ncm";
      rndis = "rndis_host";
      qmi = "qmi_wwan";
      mbim = "cdc_mbim";
    }
    .${
      mode
    };

  apnOf = name: let
    apn = cfg.wans.${name}.wwan.apn;
  in
    if apn == null
    then ""
    else apn;

  switchOf = name: (peripheral name).wwan.modeSwitch or {};

  switchConf = name:
    pkgs.writeText "modeswitch-${name}.conf" (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: value: "${key}=${toString value}") (switchOf name)
      )
      + "\n"
    );

  connect = name: let
    mode = effective name;
    periph = cfg.wans.${name}.wwan.peripheral;
    apn = lib.escapeShellArg (apnOf name);
  in
    pkgs.writeShellScript "wwan-connect-${name}" ''
      set -eu
      install -d -m 0755 /run/janus/wwan
      status=/run/janus/wwan/${periph}
      {
        echo "mode=${mode}"
        echo "peripheral=${periph}"
        echo "iface=${iface name}"
      } > "$status"
      apn=${apn}
      ${lib.optionalString (mode == "qmi") ''
        dev=/dev/janus-qmi-${periph}
        if [ ! -e "$dev" ]; then
          echo "qmi=missing" >> "$status"
          exit 1
        fi
        if [ -e /sys/class/net/${iface name}/qmi/raw_ip ]; then
          printf 'Y\n' > /sys/class/net/${iface name}/qmi/raw_ip
        fi
        ${pkgs.libqmi}/bin/qmicli -d "$dev" --device-open-proxy \
          --wds-start-network="apn=$apn,ip-type=4" --client-no-release-cid \
          >> "$status" 2>&1
      ''}
      ${lib.optionalString (mode == "mbim") ''
        dev=/dev/janus-mbim-${periph}
        if [ ! -e "$dev" ]; then
          echo "mbim=missing" >> "$status"
          exit 1
        fi
        ${pkgs.libmbim}/bin/mbimcli -d "$dev" --attach-packet-service >> "$status" 2>&1
        ${pkgs.libmbim}/bin/mbimcli -d "$dev" --connect="apn=$apn" >> "$status" 2>&1
      ''}
    '';

  health = name: let
    mode = effective name;
    periph = cfg.wans.${name}.wwan.peripheral;
  in
    pkgs.writeShellScript "wwan-health-${name}" ''
      set -eu
      install -d -m 0755 /run/janus/wwan
      status=/run/janus/wwan/${periph}
      {
        echo "mode=${mode}"
        echo "peripheral=${periph}"
        echo "iface=${iface name}"
        ${lib.optionalString (mode == "qmi") ''
        if [ -e /dev/janus-qmi-${periph} ]; then
          ${pkgs.libqmi}/bin/qmicli -d /dev/janus-qmi-${periph} --nas-get-signal-strength || true
        else
          echo "qmi=missing"
        fi
      ''}
        ${lib.optionalString (mode == "mbim") ''
        if [ -e /dev/janus-mbim-${periph} ]; then
          ${pkgs.libmbim}/bin/mbimcli -d /dev/janus-mbim-${periph} --query-signal-state || true
        else
          echo "mbim=missing"
        fi
      ''}
      } > "$status"
    '';
in {
  config = lib.mkIf (wwanNames != []) {
    boot.kernelModules = map (n: moduleOf (effective n)) wwanNames;

    services.udev.extraRules =
      lib.concatMapStrings (name: let
        id = usbId name;
        periph = cfg.wans.${name}.wwan.peripheral;
        mode = effective name;
      in ''
        SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", NAME="${iface name}"
        ${lib.optionalString (mode == "qmi") ''
          SUBSYSTEM=="usbmisc", ACTION=="add", KERNEL=="cdc-wdm*", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", SYMLINK+="janus-qmi-${periph}"
        ''}
        ${lib.optionalString (mode == "mbim") ''
          SUBSYSTEM=="usbmisc", ACTION=="add", KERNEL=="cdc-wdm*", ATTRS{idVendor}=="${vendor id}", ATTRS{idProduct}=="${product id}", SYMLINK+="janus-mbim-${periph}"
        ''}
      '')
      wwanNames;

    systemd.services =
      lib.listToAttrs (lib.concatMap (name:
        lib.optional (switchOf name != {}) {
          name = "janus-wwan-switch-${name}";
          value = {
            description = "WWAN mode switch ${name}";
            wantedBy = ["network-pre.target"];
            enable = true;
            before = ["systemd-networkd.service" "janus-wwan-${name}.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.usb-modeswitch}/bin/usb_modeswitch -c ${switchConf name}";
            };
          };
        })
      wwanNames)
      // lib.listToAttrs (map (name: {
          name = "janus-wwan-${name}";
          value = lib.mkIf (lib.elem (effective name) ["qmi" "mbim"]) {
            description = "WWAN connect ${name}";
            wantedBy = ["network-pre.target"];
            enable = true;
            before = ["systemd-networkd.service"];
            after = ["systemd-udev-settle.service"] ++ lib.optional (switchOf name != {}) "janus-wwan-switch-${name}.service";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = connect name;
              RemainAfterExit = true;
            };
          };
        })
        wwanNames)
      // lib.listToAttrs (map (name: {
          name = "janus-wwan-health-${name}";
          value = {
            description = "WWAN health ${name}";
            wantedBy = ["multi-user.target"];
            after = ["systemd-networkd.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = health name;
            };
          };
        })
        wwanNames);
  };
}
