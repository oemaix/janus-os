# SPDX-License-Identifier: Apache-2.0
# INA219 readings and the early cutoff in docs/10 §4.5.
{
  config,
  lib,
  pkgs,
  ...
}: let
  hw = config.janus.hardware;
  allow = import ../hardware/allowlist.nix;
  pi = lib.elem hw.board ["rpi-zero-2w" "rpi3"];

  exposed = lib.filter (name: let
    p = hw.peripherals.${name};
    row =
      if p.class != "power" || p.match.i2cAddress == null
      then null
      else allow.i2c.${p.match.i2cAddress} or null;
  in
    row != null && (row.dischargeSign or null) != null) (lib.attrNames hw.peripherals);

  chosen =
    if exposed == []
    then null
    else lib.head exposed;
  peripheral =
    if chosen == null
    then null
    else hw.peripherals.${chosen};
  row =
    if peripheral == null
    then null
    else allow.i2c.${peripheral.match.i2cAddress};
  armed =
    peripheral != null && peripheral.power.shutdown.enable;

  powerPkg = pkgs.writeShellApplication {
    name = "janus-power";
    runtimeInputs = with pkgs; [gawk coreutils systemd];
    text = builtins.readFile ../../../pkgs/janus-power.sh;
  };

  addresses = map (name: hw.peripherals.${name}.match.i2cAddress) exposed;
  # The overlay is data. dtc runs on the build machine, and only a
  # Raspberry Pi image installs the file. Another board uses the hwmon
  # node that already exists.
  dts = ''
    /dts-v1/;
    /plugin/;
    / {
        compatible = "brcm,bcm2835";
    ${lib.concatImapStrings (i: addr: ''
      fragment@${toString (i - 1)} {
          target = <&i2c_arm>;
          __overlay__ {
              #address-cells = <1>;
              #size-cells = <0>;
              ina219@${lib.removePrefix "0x" addr} {
                  compatible = "ti,ina219";
                  reg = <${addr}>;
                  shunt-resistor = <100000>;
                  status = "okay";
              };
          };
      };
    '')
    addresses}
    };
  '';
  dtbo = pkgs.buildPackages.runCommand "janus-ina219.dtbo" {
    nativeBuildInputs = [pkgs.buildPackages.dtc];
  } ''
    cat > ina219.dts << EOF
    ${dts}
    EOF
    dtc -@ -I dts -O dtb -o "$out" ina219.dts
  '';

  conf = ''
    bin	${powerPkg}/bin/janus-power
    name	${chosen}
    sign	${row.dischargeSign}
    armed	${
      if armed
      then "1"
      else "0"
    }
    warn	${toString peripheral.power.shutdown.warnVolts}
    shutdown	${toString peripheral.power.shutdown.volts}
    critical	${toString peripheral.power.shutdown.criticalVolts}
  '';
in {
  config = lib.mkIf (chosen != null) {
    warnings =
      lib.optional (lib.length exposed > 1) ''
        More than one power peripheral has a discharge sign. Shutdown follows ${chosen}.
      ''
      ++ lib.optional (!pi) ''
        ${chosen} is an INA219. The device-tree overlay is installed on Raspberry Pi boards.
        On this board the sensor must already appear under /sys/class/hwmon.
      '';

    boot.kernelModules = ["ina2xx"] ++ lib.optionals pi ["i2c-bcm2835"];
    system.build.janusIna219Dts = lib.mkIf pi dts;
    system.build.janusIna219Dtbo = lib.mkIf pi dtbo;
    janus.board.bootScript = lib.mkIf pi ''
      mkdir -p overlays
      cp ${dtbo} overlays/janus-ina219.dtbo
    '';
    janus.board.configTxt = lib.mkIf pi ''
      dtparam=i2c_arm=on
      dtoverlay=janus-ina219
    '';

    environment.etc."janus/power.conf".text = conf;

    systemd.services.janus-power-guard = lib.mkIf armed {
      description = "Power off a discharging cell before the network starts";
      # network-pre.target is passive: nothing else pulls it in. multi-user
      # starts this unit, and the unit pulls the target so Before= is ordered.
      wantedBy = ["multi-user.target"];
      wants = ["network-pre.target"];
      before = ["network-pre.target" "janus-engine.service"];
      after = ["systemd-udevd.service" "systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
        ExecStart = "${powerPkg}/bin/janus-power guard /etc/janus/power.conf";
      };
    };

    systemd.services.janus-power = {
      description = "Watch the cell and power off while it is discharging";
      wantedBy = ["multi-user.target"];
      after = ["janus-power-guard.service" "systemd-modules-load.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${powerPkg}/bin/janus-power watch /etc/janus/power.conf";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
