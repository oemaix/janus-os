# SPDX-License-Identifier: Apache-2.0
# Spotify Soloist as a Connect playback device (FR-SVC-001).
# enable defaults to false. A false setting adds no unit, secret, or package.
# True downloads the locked official build for x86_64, aarch64, or armv7l.
{
  config,
  lib,
  pkgs,
  janusSoloist ? {},
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.janus.soloist;
  system = pkgs.stdenv.hostPlatform.system;
  src = janusSoloist.${system} or null;
  pkg =
    if src == null
    then null
    else pkgs.callPackage ../../pkgs/soloist.nix {inherit src;};
  connectName =
    if cfg.name != null
    then cfg.name
    else config.janus.system.hostName;
  secretName = cfg.apiKeySecret;
  secretReady = secretName != null && cfg.sopsFile != null;
  apiKeyFile =
    if secretReady
    then config.sops.secrets.${secretName}.path
    else null;
  zones = config.janus.firewall.zones;
  audio = config.janus.audio;
  nodeSet = audio.playback.node != null && builtins.match "[ \t]*" audio.playback.node == null;
  bluetooth = audio.enable && audio.playback.output == "bluetooth";
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
  run =
    if pkg == null
    then "${pkgs.coreutils}/bin/false"
    else
      pkgs.writeShellScript "soloist-run" ''
        set -eu
        key=$(${pkgs.coreutils}/bin/cat -- "$SOLOIST_KEY_FILE")
        if [ -n "''${SOLOIST_DEVICE:-}" ]; then
          exec ${pkg}/bin/soloist -n "$SOLOIST_NAME" -k "$key" -d "$SOLOIST_DEVICE"
        else
          exec ${pkg}/bin/soloist -n "$SOLOIST_NAME" -k "$key"
        fi
      '';
in {
  options.janus.soloist = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Spotify Soloist as a Connect playback device.
        False adds no unit, secret, or package to the image.
        True needs janus.audio.enable and a playback device.
        It installs the locked Linux build for x86_64, aarch64, or armv7l
        and starts it with system-wide PipeWire.
        Bluetooth starts only when janus.audio.playback.output is bluetooth.
        docs/08, FR-SVC-001, D-0056, D-0061.
      '';
    };

    apiKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        sops secret name for the Soloist API key.
        One line in the file named by sopsFile. Plaintext only in /run/secrets.
        Installed only when enable is true. FR-SEC-012.
      '';
    };

    sopsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        sops document for apiKeySecret. One line, value:.
        The secret is installed only when enable is true.
      '';
    };

    name = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Janus";
      description = "Spotify Connect name. The host name is used when this is unset.";
    };

    zones = mkOption {
      type = types.listOf types.str;
      default = ["lan"];
      example = ["lan"];
      description = ''
        Zones where a Spotify Connect client may find this router.
        UDP 5353 is accepted there and dropped elsewhere.
        wan fails evaluation. guest and iot only when the firewall defines them.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = src != null;
        message = ''
          janus.soloist.enable needs a board Spotify publishes a Linux build for: x86_64, aarch64, or armv7l.
          This board is ${system}.
          The archives are the soloist-* inputs in flake.lock.
          https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates
        '';
      }
      {
        assertion = secretReady;
        message = ''
          janus.soloist.enable needs janus.soloist.apiKeySecret and janus.soloist.sopsFile.
          The key is one line in that file. FR-SEC-012.
        '';
      }
      {
        assertion = audio.enable && audio.playback.output != null;
        message = ''
          janus.soloist.enable needs janus.audio.enable and janus.audio.playback.output.
          Playback is shared. Soloist has no playback option of its own. D-0061.
        '';
      }
      {
        assertion = cfg.zones != [];
        message = "janus.soloist.zones needs at least one zone.";
      }
      {
        assertion = lib.all (zone: zone != "wan") cfg.zones;
        message = "janus.soloist.zones must not include wan.";
      }
      {
        assertion = lib.all (zone: zones ? ${zone}) cfg.zones;
        message = ''
          janus.soloist.zones names a zone this firewall does not define.
          guest and iot are available only when the configuration defines them.
        '';
      }
    ];

    janus.firmware.extraUnfree = ["soloist"];

    # mDNS. confine drops UDP 5353 outside these zones, including wan.
    janus.firewall.services.soloist = {
      zones = cfg.zones;
      port = 5353;
      protocol = "udp";
      confine = true;
    };

    # The key stays root-owned in /run/secrets. ExecStartPre copies it for
    # this user. Soloist's -k flag still places the key in the process list.
    # The unit file in the store does not contain the key. The WebSocket
    # flag is not passed, so that socket stays off.
    users.users.soloist = {
      isSystemUser = true;
      group = "soloist";
      extraGroups = ["pipewire"];
    };
    users.groups.soloist = {};

    services.pipewire = {
      enable = true;
      systemWide = true;
      audio.enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber = {
        enable = true;
        extraConfig = lib.mkIf bluetooth {
          # A fragment merges by key. These two keys do not replace the
          # rest of monitor.bluez.properties.
          "10-janus-bluez" = {
            "monitor.bluez.properties" = {
              # a2dp_source sends audio to a speaker. AVRCP rides with it.
              # hfp and hsp are phone calls and stay off.
              "bluez5.roles" = ["a2dp_source"];
              "bluez5.hfphsp-backend" = "none";
            };
          };
        };
      };
    };

    # A2DP source and AVRCP are selected in WirePlumber, not in main.conf.
    # BlueZ ignores an Enable= list. HFP and HSP stay off because
    # bluez5.roles is only a2dp_source. D-0061.
    hardware.bluetooth = lib.mkIf bluetooth {
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
    hardware.enableRedistributableFirmware = lib.mkIf bluetooth true;
    janus.board.configTxt = lib.mkIf (bluetooth && lib.elem config.janus.hardware.board ["rpi-zero-2w" "rpi3" "rpi4"]) ''
      dtparam=krnbt=on
    '';

    environment.systemPackages = lib.optional (pkg != null) pkg;

    sops.secrets = lib.mkIf secretReady {
      ${secretName} = {
        sopsFile = cfg.sopsFile;
      };
    };

    systemd.services.soloist = {
      description = "Spotify Soloist";
      wantedBy = ["multi-user.target"];
      after = [
        "pipewire.service"
        "wireplumber.service"
        "sops-install-secrets.service"
      ];
      requires = [
        "pipewire.service"
        "sops-install-secrets.service"
      ];
        environment =
        {
          SOLOIST_NAME = connectName;
          SOLOIST_KEY_FILE = "/run/soloist/api-key";
          # System socket is /run/pipewire-0. T-0014.
          PIPEWIRE_RUNTIME_DIR = "/run";
        }
        // lib.optionalAttrs (nodeSet && !bluetooth) {
          SOLOIST_DEVICE = audio.playback.node;
        };
      serviceConfig = {
        User = "soloist";
        Group = "soloist";
        RuntimeDirectory = "soloist";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "soloist";
        CacheDirectory = "soloist";
        ExecStartPre = lib.optional (apiKeyFile != null) "+${pkgs.coreutils}/bin/install -m 0400 -o soloist -g soloist ${lib.escapeShellArg apiKeyFile} /run/soloist/api-key";
        ExecStart = run;
        Restart = "on-failure";
        RestartPreventExitStatus = 10;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    environment.etc."janus/bin/janus-bluetooth" = lib.mkIf bluetooth {
      source = "${btCmd}/bin/janus-bluetooth";
    };

    systemd.services.janus-bluetooth-reconnect = lib.mkIf bluetooth {
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

    environment.etc."janus/soloist.json".text = builtins.toJSON {
      inherit (cfg) zones;
      name = connectName;
      playback = {
        output = audio.playback.output;
        node = audio.playback.node;
      };
      apiKeyFile = apiKeyFile;
      websocket = "off";
      discovery = "mdns";
      bin =
        if pkg == null
        then null
        else "${pkg}/bin/soloist";
    };
  };
}
