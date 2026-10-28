# SPDX-License-Identifier: Apache-2.0
# Status panel. docs/15. The first profile is the Waveshare 1.3" OLED HAT.
{
  config,
  lib,
  pkgs,
  ...
}: let
  hw = config.janus.hardware;
  net = config.janus.network;
  proxy = config.janus.proxy;
  allow = import ../hardware/allowlist.nix;

  hmiNames = lib.filter (n: hw.peripherals.${n}.class == "hmi") (lib.attrNames hw.peripherals);
  panels = lib.genAttrs hmiNames (n: hw.peripherals.${n});
  waveshare = lib.any (n: panels.${n}.hmi.profile == "waveshare-1.3-oled-hat") hmiNames;

  panelPkg = pkgs.callPackage ../../../pkgs/hmi-panel.nix {};
  hmiPkg = pkgs.writeShellApplication {
    name = "janus-hmi";
    runtimeInputs = [pkgs.janet];
    text = ''
      exec ${pkgs.janet}/bin/janet ${../../../janet/hmi.janet} run "$@"
    '';
  };
  snapshotPkg = pkgs.writeShellApplication {
    name = "janus-hmi-snapshot";
    runtimeInputs = with pkgs; [gawk jq iproute2 curl systemd coreutils];
    text = builtins.readFile ../../../pkgs/janus-hmi-snapshot.sh;
  };
  # Mainline trees leave &spi disabled and have no firmware dtparam.
  # GPIO 7-11 are the header SPI. rohm,dh2228fv is the in-tree spidev
  # binding, so the node appears as /dev/spidev0.0. The panel clock is 4 MHz.
  spiDts = ''
    /dts-v1/;
    /plugin/;
    / {
        compatible = "brcm,bcm2837", "brcm,bcm2711";
        fragment@0 {
            target = <&spi>;
            __overlay__ {
                pinctrl-names = "default";
                pinctrl-0 = <&spi0_gpio7>;
                status = "okay";
                #address-cells = <1>;
                #size-cells = <0>;
                spidev@0 {
                    compatible = "rohm,dh2228fv";
                    reg = <0>;
                    spi-max-frequency = <4000000>;
                };
            };
        };
        fragment@1 {
            target-path = "/aliases";
            __overlay__ {
                spi0 = "/soc/spi@7e204000";
            };
        };
    };
  '';
  spiDtbo =
    pkgs.buildPackages.runCommand "janus-spi.dtbo" {
      nativeBuildInputs = [pkgs.buildPackages.dtc];
    } ''
      cat > spi.dts << EOF
      ${spiDts}
      EOF
      dtc -@ -I dts -O dtb -o "$out" spi.dts
    '';

  portIface = name: let
    port = net.ports.${name};
  in
    if port.device != null
    then port.device
    else name;

  vlanNetdev = vlan: "${vlan.port}.${toString vlan.id}";

  vlanByRef = ref:
    lib.findFirst (
      n: n == ref || vlanNetdev net.vlans.${n} == ref
    )
    null (lib.attrNames net.vlans);

  resolve = name:
    if net.ports ? ${name}
    then portIface name
    else if vlanByRef name != null
    then vlanNetdev net.vlans.${vlanByRef name}
    else if net.wifi ? ${name}
    then "wifi-${name}"
    else name;

  wanIface = name: let
    wan = net.wans.${name};
  in
    if wan.mode == "pppoe"
    then "ppp-${name}"
    else if wan.mode == "wwan"
    then "wwan-${wan.wwan.peripheral}"
    else resolve wan.uplink;

  keyCap = keys: name: default: keys.${name} or default;

  controlsOf = p:
    if p.hmi.profile != "waveshare-1.3-oled-hat"
    then []
    else
      lib.filter (row: row.cap != "unbound") [
        {
          name = "left";
          cap = "page-prev";
          gpio = 5;
        }
        {
          name = "right";
          cap = "page-next";
          gpio = 26;
        }
        {
          name = "up";
          cap = "item-prev";
          gpio = 6;
        }
        {
          name = "down";
          cap = "item-next";
          gpio = 19;
        }
        {
          name = "press";
          cap = "confirm";
          gpio = 13;
        }
        {
          name = "KEY1";
          cap = keyCap p.hmi.keys "KEY1" "refresh";
          gpio = 21;
        }
        {
          name = "KEY2";
          cap = keyCap p.hmi.keys "KEY2" "unbound";
          gpio = 20;
        }
        {
          name = "KEY3";
          cap = keyCap p.hmi.keys "KEY3" "reboot-hold";
          gpio = 16;
        }
      ];

  groupNames = lib.attrNames proxy.groups;
  groupList =
    if proxy.enable && proxy.groupsAuto && !(lib.elem "Auto" groupNames)
    then groupNames ++ ["Auto"]
    else groupNames;

  groupOf = name:
    if proxy.groups ? ${name}
    then proxy.groups.${name}
    else {
      strategy = "url-test";
      default = null;
      members = [];
    };

  nodeMembers = members:
    map (lib.removePrefix "node:") (lib.filter (lib.hasPrefix "node:") members);

  powerNames = lib.filter (n: hw.peripherals.${n}.class == "power") (lib.attrNames hw.peripherals);
  powerName =
    if powerNames == []
    then null
    else lib.head powerNames;
  power =
    if powerName == null
    then null
    else hw.peripherals.${powerName};
  powerRow =
    if power == null || power.match.i2cAddress == null
    then null
    else allow.i2c.${power.match.i2cAddress} or null;
  discharge =
    if powerRow == null || (powerRow.dischargeSign or null) == null
    then "-"
    else powerRow.dischargeSign;

  confFor = name: p: let
    driver =
      if p.hmi.driver == null
      then ""
      else p.hmi.driver;
    lines =
      [
        "width\t128"
        "height\t64"
        "driver\t${driver}"
        "spi\t/dev/spidev0.0"
        "dc\t24"
        "reset\t25"
        "chip\t/dev/gpiochip0"
        "host\t${config.janus.system.hostName}"
        "mode\t${proxy.mode}"
        "proxy\t${
          if proxy.enable
          then "1"
          else "0"
        }"
        "runtime\t/run/janus-hmi-${name}"
        "bin\tjanus\t/run/current-system/sw/bin/janus"
        "bin\tpanel\t${panelPkg}/bin/janus-hmi-panel"
        "bin\tsnapshot\t${snapshotPkg}/bin/janus-hmi-snapshot"
        "subject\twan\t${
          if net.wans == {}
          then "0"
          else "1"
        }"
        "subject\tlan\t${
          if net.lans == {}
          then "0"
          else "1"
        }"
        "subject\tproxy\t${
          if proxy.enable
          then "1"
          else "0"
        }"
        "subject\tpower\t${
          if powerName == null
          then "0"
          else "1"
        }"
      ]
      ++ map (c: "control\t${c.name}\t${c.cap}\t${toString c.gpio}") (controlsOf p)
      ++ lib.mapAttrsToList (n: _: "wan\t${n}\t${wanIface n}") net.wans
      ++ lib.mapAttrsToList (n: lan: "lan\t${n}\t${lan.address}/${toString lan.prefixLength}") net.lans
      ++ lib.optionals proxy.enable (lib.concatMap (g: let
        group = groupOf g;
        fallback =
          if group.default == null
          then "-"
          else group.default;
      in
        ["group\t${g}\t${group.strategy}\t${fallback}"]
        ++ map (m: "member\t${g}\t${m}") (nodeMembers group.members))
      groupList)
      ++ lib.optionals (powerName != null) [
        "power\t${discharge}\t${
          if power.power.shutdown.enable
          then "1"
          else "0"
        }\t${toString power.power.shutdown.warnVolts}"
      ];
  in
    lib.concatStringsSep "\n" lines + "\n";
in {
  config = lib.mkIf (hmiNames != []) {
    assertions = [
      {
        assertion = config.janus.access.cli.enable;
        message = "An HMI peripheral runs janus commands, so janus.access.cli.enable must stay on.";
      }
    ];

    boot.kernelModules = lib.mkIf waveshare ["spi-bcm2835" "spidev"];
    system.build.janusSpiDts = lib.mkIf waveshare spiDts;
    system.build.janusSpiDtbo = lib.mkIf waveshare spiDtbo;
    janus.board.bootScript = lib.mkIf waveshare ''
      mkdir -p overlays
      cp ${spiDtbo} overlays/janus-spi.dtbo
    '';
    janus.board.configTxt = lib.mkIf waveshare ''
      dtoverlay=janus-spi
      gpio=6,19,5,26,13,21,20,16=pu
    '';

    environment.etc =
      lib.mapAttrs' (name: p: {
        name = "janus/hmi-${name}.conf";
        value.text = confFor name p;
      })
      panels;

    systemd.services =
      lib.mapAttrs' (name: _: {
        name = "janus-hmi-${name}";
        value = {
          description = "Janus panel ${name}";
          wantedBy = ["multi-user.target"];
          after = ["janus-seed.service" "systemd-udevd.service"];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${hmiPkg}/bin/janus-hmi /etc/janus/hmi-${name}.conf";
            Restart = "on-failure";
            RestartSec = "2s";
            RuntimeDirectory = "janus-hmi-${name}";
          };
        };
      })
      panels;
  };
}
