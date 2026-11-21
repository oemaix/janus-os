# SPDX-License-Identifier: Apache-2.0
# Header LED with the kernel heartbeat trigger. docs/10 §3.8, D-0075.
# Off unless janus.hardware.heartbeat.enable is true. Pin numbers are the
# 40-pin header: pin 1 is 3.3 V, pins 2 and 4 are 5 V, pins 6 and 9 are GND.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.hardware.heartbeat;
  board = config.janus.hardware.board;

  # Header pin → BCM number. The same six pins on every Raspberry Pi header.
  piBcm = {
    "7" = 4;
    "11" = 17;
    "12" = 18;
    "13" = 27;
    "15" = 22;
    "16" = 23;
  };
  piPins = lib.mapAttrs (_: bcm: {bcm = bcm;}) piBcm;

  # SoC GPIO cell for boards whose header is the same shape and not BCM.
  # Le Potato pin 11 is GPIOAO_8, shared with HDMI CEC through switch 9J3,
  # and the boot tree enables CEC on that pad. It is not in this map.
  rockPins = {
    "7" = {
      controller = "gpio2";
      line = 11;
    }; # GPIO2_B3
    "11" = {
      controller = "gpio4";
      line = 18;
    }; # GPIO4_C2
    "12" = {
      controller = "gpio4";
      line = 3;
    }; # GPIO4_A3
    "13" = {
      controller = "gpio4";
      line = 22;
    }; # GPIO4_C6
    "15" = {
      controller = "gpio4";
      line = 21;
    }; # GPIO4_C5
    "16" = {
      controller = "gpio4";
      line = 26;
    }; # GPIO4_D2
  };
  potatoPins = {
    "7" = {
      controller = "gpio";
      line = 98;
    }; # GPIOCLK_0
    "12" = {
      controller = "gpio_ao";
      line = 6;
    }; # GPIOAO_6
    "13" = {
      controller = "gpio_ao";
      line = 9;
    }; # GPIOAO_9
    "15" = {
      controller = "gpio_ao";
      line = 10;
    }; # GPIO_TEST_N
    "16" = {
      controller = "gpio";
      line = 93;
    }; # GPIOX_14
  };
  vfPins = {
    "7" = {
      controller = "sysgpio";
      line = 55;
    };
    "11" = {
      controller = "sysgpio";
      line = 42;
    };
    "12" = {
      controller = "sysgpio";
      line = 38;
    };
    "13" = {
      controller = "sysgpio";
      line = 43;
    };
    "15" = {
      controller = "sysgpio";
      line = 47;
    };
    "16" = {
      controller = "sysgpio";
      line = 54;
    };
  };

  pinsByBoard = {
    rpi-zero-2w = piPins;
    rpi2 = piPins;
    rpi3 = piPins;
    rpi4 = piPins;
    rockpi-4c = rockPins;
    le-potato = potatoPins;
    visionfive2 = vfPins;
  };

  pinKey = toString cfg.pin;
  onHeader = pinsByBoard ? ${board};
  spec =
    if onHeader && pinsByBoard.${board} ? ${pinKey}
    then pinsByBoard.${board}.${pinKey}
    else null;

  piCompatible = {
    rpi2 = "brcm,bcm2836";
    rpi3 = "brcm,bcm2837";
    rpi4 = "brcm,bcm2711";
    rpi-zero-2w = "brcm,bcm2837";
  };

  # Boot trees that select alt0 or i2s_alt0 own the header pin. Drop that
  # group from the GPIO controller before gpio-leds requests it (T-0044, T-0060).
  # Pi 3 and Pi 4 define the groups and do not select them.
  piRelease =
    if spec == null || !(piCompatible ? ${board})
    then null
    else if spec.bcm == 4 && board == "rpi2"
    then "&gpioout &i2s_alt0"
    else if spec.bcm == 4 && board == "rpi-zero-2w"
    then "&gpioout"
    else if spec.bcm == 18 && board == "rpi2"
    then "&gpioout &alt0"
    else null;

  piDts = ''
    /dts-v1/;
    /plugin/;
    / {
        compatible = "${piCompatible.${board}}";
        ${lib.optionalString (piRelease != null) ''
      fragment@0 {
          target = <&gpio>;
          __overlay__ {
              pinctrl-0 = <${piRelease}>;
          };
      };
    ''}
        fragment@${
      if piRelease == null
      then "0"
      else "1"
    } {
            target-path = "/";
            __overlay__ {
                janus-heartbeat {
                    compatible = "gpio-leds";
                    led-heartbeat {
                        label = "janus:heartbeat";
                        gpios = <&gpio ${toString spec.bcm} 0>;
                        linux,default-trigger = "heartbeat";
                    };
                };
            };
        };
    };
  '';

  socDts = compatible: ''
    /dts-v1/;
    /plugin/;
    / {
        compatible = ${compatible};
        fragment@0 {
            target-path = "/";
            __overlay__ {
                janus-heartbeat {
                    compatible = "gpio-leds";
                    led-heartbeat {
                        label = "janus:heartbeat";
                        gpios = <&${spec.controller} ${toString spec.line} 0>;
                        linux,default-trigger = "heartbeat";
                    };
                };
            };
        };
    };
  '';

  dts =
    if spec == null
    then null
    else if piCompatible ? ${board}
    then piDts
    else if board == "rockpi-4c"
    then socDts ''"radxa,rockpi4c", "radxa,rockpi4", "rockchip,rk3399"''
    else if board == "le-potato"
    then socDts ''"libretech,aml-s905x-cc", "amlogic,s905x", "amlogic,meson-gxl"''
    else socDts ''"starfive,visionfive-2-v1.2a", "starfive,visionfive-2-v1.3b", "starfive,jh7110"'';

  dtbo =
    pkgs.buildPackages.runCommand "janus-heartbeat.dtbo" {
      nativeBuildInputs = [pkgs.buildPackages.dtc];
    } ''
      cat > heartbeat.dts << EOF
      ${dts}
      EOF
      dtc -@ -I dts -O dtb -o "$out" heartbeat.dts
    '';
in {
  options.janus.hardware.heartbeat = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Blink a header GPIO with the kernel heartbeat trigger. docs/10 §3.8.";
    };
    pin = lib.mkOption {
      type = lib.types.enum [7 11 12 13 15 16];
      default = 7;
      description = "40-pin header pin. Default 7. A pin this board does not wire as a GPIO fails evaluation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = onHeader;
        message = ''
          janus.hardware.heartbeat is not available on ${board}.
          The header LED is defined for rpi-zero-2w, rpi2, rpi3, rpi4, rockpi-4c, le-potato, and visionfive2.
          See docs/10-hardware-support.md §3.8.
        '';
      }
      {
        assertion = !onHeader || pinsByBoard.${board} ? ${pinKey};
        message = ''
          janus.hardware.heartbeat.pin ${pinKey} is not a GPIO on ${board}.
          See docs/10-hardware-support.md §3.8.
        '';
      }
    ];

    # gpio-leds is already built in on the SoC defconfigs. The trigger is
    # not. Force it when this LED is on, so a default image keeps its kernel.
    boot.kernelPatches = lib.mkIf (spec != null) [
      {
        name = "janus-heartbeat-led";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          LEDS_CLASS = yes;
          LEDS_GPIO = yes;
          LEDS_TRIGGERS = yes;
          LEDS_TRIGGER_HEARTBEAT = yes;
        };
      }
    ];

    system.build.janusHeartbeatDts = lib.mkIf (spec != null) dts;
    system.build.janusHeartbeatDtbo = lib.mkIf (spec != null) dtbo;

    janus.board.bootScript = lib.mkIf (spec != null && piCompatible ? ${board}) ''
      mkdir -p overlays
      cp ${dtbo} overlays/janus-heartbeat.dtbo
    '';
    janus.board.configTxt = lib.mkIf (spec != null && piCompatible ? ${board}) ''
      dtoverlay=janus-heartbeat
    '';
  };
}
