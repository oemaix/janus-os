# SPDX-License-Identifier: Apache-2.0
# Shared recording and playback. Soloist and speech are the consumers.
# BlueZ starts here when playback or recording is bluetooth. D-0061.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.janus.audio;
  board = config.janus.hardware.board;
  profile = config.janus.system.kernelProfile;
  peripherals = lib.attrValues config.janus.hardware.peripherals;
  hasBtPeripheral = lib.any (p: p.class == "bluetooth") peripherals;
  btBoards = ["rpi-zero-2w" "rpi3" "rpi4" "rockpi-4c"];
  # The NanoPi R4S mainline tree has no sound card.
  embeddedBoards = [
    "rpi-zero-2w"
    "rpi2"
    "rpi3"
    "rpi4"
    "rockpi-4c"
    "le-potato"
    "visionfive2"
    "yanyu-stx-r19f"
    "x86_64-test"
  ];
  nonBlank = value: value != null && builtins.match "[ \t]*" value == null;
  bluetooth = cfg.enable && (playback == "bluetooth" || recording == "bluetooth");
  btAgent = pkgs.runCommandCC "janus-bt-agent" {
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [pkgs.dbus];
  } ''
    mkdir -p "$out/bin"
    cc -O2 -Wall -Wextra -o "$out/bin/janus-bt-agent" ${../../pkgs/janus-bt-agent.c} $(pkg-config --cflags --libs dbus-1)
  '';
  btCmd = pkgs.writeShellApplication {
    name = "janus-bluetooth";
    runtimeInputs = [
      pkgs.bluez
      btAgent
      pkgs.wireplumber
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = builtins.readFile ../../pkgs/janus-bluetooth.sh;
  };
  # PipeWire monitor names encode direction. A number or a custom name does not.
  # alsa_output.*.monitor is a source of that sink.
  monitorSource = name: builtins.match ".*[.]monitor" name != null;
  namedInput = name:
    builtins.match "(alsa_input|bluez_input)[.].*" name != null
    || (
      builtins.match "(alsa_output|bluez_output)[.].*" name != null
      && monitorSource name
    );
  namedOutput = name:
    builtins.match "(alsa_output|bluez_output)[.].*" name != null
    && !monitorSource name;
  alsa = kind: kind == "embedded" || kind == "usb";
  playback = cfg.playback.output;
  recording = cfg.recording.input;
  devicesUnset =
    playback == null
    && recording == null
    && cfg.playback.node == null
    && cfg.recording.node == null;
in {
  options.janus.audio = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Turn on the shared audio devices (D-0061).
        false leaves playback and recording unread and adds no kernel sound.
      '';
    };

    playback = {
      output = mkOption {
        type = types.nullOr (types.enum ["embedded" "usb" "bluetooth"]);
        default = null;
        description = ''
          Where shared playback goes, when janus.audio.enable is true.
          embedded is the board's own device. usb is a USB audio interface.
          bluetooth is an A2DP speaker with AVRCP. HFP and HSP stay off.
        '';
      };

      node = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          PipeWire sink for embedded and usb playback.
          bluetooth does not use it.
        '';
      };
    };

    recording = {
      input = mkOption {
        type = types.nullOr (types.enum ["embedded" "usb" "bluetooth"]);
        default = null;
        description = ''
          Where shared recording comes from, when janus.audio.enable is true.
          embedded and usb name a PipeWire source. bluetooth is rejected
          while HFP and HSP stay off.
        '';
      };

      node = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          PipeWire source for embedded and usb recording.
          A different name from playback.node.
        '';
      };
    };
  };

  config.assertions =
    [
      {
        assertion = cfg.enable || devicesUnset;
        message = ''
          janus.audio.playback and janus.audio.recording are read only when janus.audio.enable is true.
          Leave output, input, and node unset, or set enable = true.
        '';
      }
    ]
    ++ lib.optionals cfg.enable [
      {
        assertion = recording != "bluetooth";
        message = ''
          janus.audio.recording.input = bluetooth needs HFP or HSP.
          Those profiles stay off. A2DP does not carry a microphone. D-0061.
        '';
      }
      {
        assertion = !(alsa playback) || nonBlank cfg.playback.node;
        message = ''
          janus.audio.playback.output = ${toString playback} needs playback.node, a non-blank PipeWire sink.
        '';
      }
      {
        assertion = !(alsa recording) || nonBlank cfg.recording.node;
        message = ''
          janus.audio.recording.input = ${toString recording} needs recording.node, a non-blank PipeWire source.
        '';
      }
      {
        assertion = playback != "bluetooth" || cfg.playback.node == null;
        message = ''
          janus.audio.playback.output = bluetooth does not use playback.node.
        '';
      }
      {
        assertion = recording != "bluetooth" || cfg.recording.node == null;
        message = ''
          janus.audio.recording.input = bluetooth does not use recording.node.
        '';
      }
      {
        assertion = playback != "bluetooth" || hasBtPeripheral || lib.elem board btBoards;
        message = ''
          janus.audio.playback.output = bluetooth needs a bluetooth peripheral or onboard Bluetooth.
          Onboard Bluetooth is the Zero 2 W, the Pi 3, the Pi 4, and the ROCK Pi 4C.
        '';
      }
      {
        assertion = profile != "compact" || !(alsa playback || alsa recording);
        message = ''
          janus.audio embedded and usb need kernelProfile standard or matched.
          compact drops kernel sound (D-0057).
          bluetooth does not use that sound subsystem.
        '';
      }
      {
        assertion = (playback != "embedded" && recording != "embedded") || lib.elem board embeddedBoards;
        message = ''
          janus.audio embedded is not a device on ${board}.
          The NanoPi R4S mainline tree has no sound card. Use usb or bluetooth.
        '';
      }
      {
        assertion = cfg.playback.node == null || playback != null;
        message = "janus.audio.playback.node needs playback.output.";
      }
      {
        assertion = cfg.recording.node == null || recording != null;
        message = "janus.audio.recording.node needs recording.input.";
      }
      {
        assertion =
          !nonBlank cfg.playback.node
          || !nonBlank cfg.recording.node
          || cfg.playback.node != cfg.recording.node;
        message = ''
          janus.audio.playback.node and janus.audio.recording.node are the same string.
          The sink and the source are different PipeWire nodes.
        '';
      }
      {
        assertion = !nonBlank cfg.playback.node || !namedInput cfg.playback.node;
        message = ''
          janus.audio.playback.node names a PipeWire source.
          Use a sink: alsa_output or bluez_output, not alsa_input, bluez_input, or a .monitor node.
          A number or a custom name is not checked.
        '';
      }
      {
        assertion = !nonBlank cfg.recording.node || !namedOutput cfg.recording.node;
        message = ''
          janus.audio.recording.node names a PipeWire sink.
          Use a source: alsa_input, bluez_input, or an alsa_output name that ends in .monitor.
          A number or a custom name is not checked.
        '';
      }
    ];

  # recording.input = bluetooth still fails above, so that arm never boots.
  # The condition stays here so a later profile does not grow a second rule.
  config.services.pipewire = lib.mkIf bluetooth {
    enable = true;
    systemWide = true;
    audio.enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber = {
      enable = true;
      extraConfig = {
        "10-janus-bluez" = {
          "monitor.bluez.properties" = {
            "bluez5.roles" = ["a2dp_source"];
            "bluez5.hfphsp-backend" = "none";
          };
        };
      };
    };
  };

  config.hardware.bluetooth = lib.mkIf bluetooth {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        FastConnectable = "true";
      };
      Policy = {
        AutoEnable = "true";
        ReconnectAttempts = "7";
        ReconnectIntervals = "1,2,4,8,16,32,64";
      };
    };
  };
  config.hardware.enableRedistributableFirmware = lib.mkIf bluetooth true;
  config.janus.board.configTxt = lib.mkIf (bluetooth && lib.elem board btBoards && board != "rockpi-4c") ''
    dtparam=krnbt=on
  '';
  config.environment.etc."janus/bin/janus-bluetooth" = lib.mkIf bluetooth {
    source = "${btCmd}/bin/janus-bluetooth";
  };
  config.systemd.services.janus-bluetooth-reconnect = lib.mkIf bluetooth {
    description = "Reconnect the last Bluetooth speaker";
    wantedBy = ["multi-user.target"];
    after = ["bluetooth.service" "wireplumber.service"];
    requires = ["bluetooth.service"];
    environment.PIPEWIRE_RUNTIME_DIR = "/run";
    serviceConfig = {
      ExecStart = "${btCmd}/bin/janus-bluetooth reconnect";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
