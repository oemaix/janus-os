# SPDX-License-Identifier: Apache-2.0
# Option types for janus.hardware. docs/08 §2, docs/10.
# Board profiles live in modules/boards. Peripheral bring-up is a later phase.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types mkIf;
  cfg = config.janus.hardware;
  allow = import ./allowlist.nix;

  peripheral = types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      class = mkOption {
        type = types.enum ["wifi" "nic" "wwan" "bluetooth" "hmi" "power"];
        description = "Peripheral class. docs/10 §4.1.";
      };
      match = mkOption {
        type = types.submodule {
          options = {
            usbVendorProduct = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "0bda:8153";
              description = "USB vendor:product id, lowercase hex.";
            };
            usbPath = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Stable USB bus path.";
            };
            pciSlot = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "01:00.0";
              description = "PCI slot address.";
            };
            mac = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "MAC address match.";
            };
            i2cAddress = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "0x40";
              description = "I²C address for a power peripheral.";
            };
          };
        };
        default = {};
        description = "How the peripheral is identified on the bus.";
      };
      wwan.mode = mkOption {
        type = types.enum ["auto" "ecm" "ncm" "rndis" "qmi" "mbim"];
        default = "auto";
        description = "Data-plane mode. auto uses the single mode recorded for that USB id.";
      };
      wwan.modeSwitch = mkOption {
        type = types.attrs;
        default = {};
        description = "usb_modeswitch parameters. Empty uses the allowlist row.";
      };
      wwan.atPort = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Serial device for AT status. Null selects the allowlist port.";
      };
      hmi.profile = mkOption {
        type = types.nullOr (types.enum ["waveshare-1.3-oled-hat"]);
        default = null;
        description = "HMI profile. Behaviour is docs/15. The Waveshare map is docs/10 §4.6.";
      };
      hmi.driver = mkOption {
        type = types.nullOr (types.enum ["sh1106" "ssd1306" "st7789" "waveshare-epd-2in13"]);
        default = null;
        description = "Panel driver. Null uses the profile default.";
      };
      hmi.keys = mkOption {
        type = types.attrsOf (types.enum ["refresh" "reboot-hold" "factory-reset" "unbound"]);
        default = {};
        description = "Replace one key action. The joystick stays navigation.";
      };
      wifi.capabilities = mkOption {
        type = types.listOf (types.enum ["ap" "sta"]);
        default = [];
        description = "Requested Wi-Fi roles. Empty uses the allowlist.";
      };
      power.shutdown.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Early cutoff while the cell is discharging. docs/10 §4.5.";
      };
      power.shutdown.warnVolts = mkOption {
        type = types.float;
        default = 3.60;
        description = "Warning voltage. Must be at least the shutdown voltage.";
      };
      power.shutdown.volts = mkOption {
        type = types.float;
        default = 3.50;
        description = "Shutdown voltage, sustained 60 s. Must not be set below 3.50.";
      };
      power.shutdown.criticalVolts = mkOption {
        type = types.float;
        default = 3.30;
        description = "Fast shutdown voltage, sustained 10 s. Must not be set below 3.30.";
      };
    };
    config = {
      # Armed only when the profile records a discharge sign (docs/10 §4.5).
      power.shutdown.enable = let
        addr = config.match.i2cAddress;
        row =
          if addr == null
          then null
          else allow.i2c.${addr} or null;
      in
        lib.mkDefault (
          if row == null
          then false
          else row.armShutdown or false
        );
    };
  });
in {
  options.janus.hardware = {
    board = mkOption {
      type = types.enum (builtins.attrNames (import ../../../lib/boards.nix));
      example = "x86_64-test";
      description = "Board profile. Required. docs/10 §3.";
    };
    peripherals = mkOption {
      type = types.attrsOf peripheral;
      default = {};
      description = "Add-on devices, keyed by a name the rest of the configuration uses.";
    };
  };

  config = {
    assertions = let
      rows =
        lib.mapAttrsToList (name: p: {
          inherit name;
          inherit (p) class match wwan wifi power;
        })
        cfg.peripherals;
    in
      lib.concatMap (
        {
          name,
          class,
          match,
          wwan,
          wifi,
          power,
        }: let
          usb =
            if match.usbVendorProduct == null
            then null
            else allow.usb.${match.usbVendorProduct} or null;
          i2c =
            if match.i2cAddress == null
            then null
            else allow.i2c.${match.i2cAddress} or null;
          row =
            if class == "power"
            then i2c
            else usb;
        in
          lib.optionals (class == "wwan") [
            {
              assertion = match.usbVendorProduct != null && usb != null && (usb.class or "") == "wwan";
              message = ''
                janus.hardware.peripherals.${name}: wwan USB id ${toString match.usbVendorProduct} is not on the allowlist.
                See docs/10-hardware-support.md §4.3.
              '';
            }
            {
              assertion =
                wwan.mode
                == "auto"
                -> (usb != null && builtins.length (usb.modes or []) == 1);
              message = ''
                janus.hardware.peripherals.${name}.wwan.mode is auto, and the allowlist records more than one mode for ${toString match.usbVendorProduct}.
                Set ecm, ncm, rndis, qmi, or mbim.
              '';
            }
            {
              assertion = wwan.mode == "auto" || usb == null || lib.elem wwan.mode (usb.modes or []);
              message = ''
                janus.hardware.peripherals.${name}.wwan.mode = ${wwan.mode} is not a mode recorded for ${toString match.usbVendorProduct}.
              '';
            }
          ]
          ++ lib.optionals (class == "power") [
            {
              assertion = match.i2cAddress != null && i2c != null;
              message = ''
                janus.hardware.peripherals.${name}: power peripheral address ${toString match.i2cAddress} is not on the allowlist (docs/10 §4.5).
              '';
            }
            {
              assertion = power.shutdown.volts >= 3.50;
              message = "janus.hardware.peripherals.${name}.power.shutdown.volts must not be below 3.50.";
            }
            {
              assertion = power.shutdown.criticalVolts >= 3.30;
              message = "janus.hardware.peripherals.${name}.power.shutdown.criticalVolts must not be below 3.30.";
            }
            {
              assertion = power.shutdown.warnVolts >= power.shutdown.volts;
              message = "janus.hardware.peripherals.${name}.power.shutdown.warnVolts must be at least the shutdown voltage.";
            }
            {
              assertion = !(power.shutdown.enable && i2c != null && !(i2c.armShutdown or false));
              message = ''
                janus.hardware.peripherals.${name}: address ${match.i2cAddress} has no discharge measurement, so shutdown stays unarmed.
              '';
            }
          ]
          ++ lib.optionals (class == "wifi" && wifi.capabilities != []) [
            {
              assertion =
                usb
                != null
                && !(usb.unsupported or false)
                && lib.all (cap: lib.elem cap (usb.capabilities or [])) wifi.capabilities;
              message = ''
                janus.hardware.peripherals.${name}: Wi-Fi capabilities ${toString wifi.capabilities} are not advertised for ${toString match.usbVendorProduct}.
                See docs/10 §4.3.
              '';
            }
          ]
      )
      rows;

    warnings =
      lib.concatMap (
        {
          name,
          class,
          match,
          ...
        }: let
          usb =
            if match.usbVendorProduct == null
            then null
            else allow.usb.${match.usbVendorProduct} or null;
        in
          lib.optional (usb != null && usb.unsupported or false) ''
            janus.hardware.peripherals.${name} (${match.usbVendorProduct}) is in the matrix as unsupported. docs/10 §4.3.
          ''
          ++ lib.optional (class != "wwan" && class != "power" && match.usbVendorProduct != null && usb == null) ''
            janus.hardware.peripherals.${name}: USB id ${match.usbVendorProduct} is not in docs/10 §4.3.
          ''
      ) (lib.mapAttrsToList (name: p: {
          inherit name;
          inherit (p) class match;
        })
        cfg.peripherals);
  };
}
