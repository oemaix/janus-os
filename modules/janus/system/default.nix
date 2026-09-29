# SPDX-License-Identifier: Apache-2.0
# janus.system and the appliance settings that keep the board from evaluating Nix.
# docs/08 §1, docs/05 §4, docs/09 §7.
{
  config,
  lib,
  pkgs,
  janusSource ? null,
  janusConfigRevision ? null,
  janusRevision ? "unknown",
  nixpkgsRevision ? "unknown",
  ...
}: let
  inherit (lib) mkOption types mkDefault mkIf;
  cfg = config.janus.system;
  buildJson =
    pkgs.runCommand "janus-build.json" {
      nativeBuildInputs = [pkgs.jq];
      metaJson = builtins.toJSON {
        janusRevision = janusRevision;
        nixpkgsRevision = nixpkgsRevision;
        configRevision =
          if janusConfigRevision == null
          then "unknown"
          else janusConfigRevision;
        board = config.janus.hardware.board;
        subscriptions = {};
      };
      passAsFile = ["metaJson"];
    } ''
      date=$(date -u -d "@''${SOURCE_DATE_EPOCH:-0}" +%Y-%m-%dT%H:%M:%SZ)
      jq --arg date "$date" '. + {buildDate: $date}' "$metaJsonPath" > "$out"
    '';
in {
  options.janus.system = {
    hostName = mkOption {
      type = types.str;
      default = "janus";
      description = "Router host name.";
    };
    timeZone = mkOption {
      type = types.str;
      default = "UTC";
      description = "Time zone passed to NixOS.";
    };
    ntp.servers = mkOption {
      type = types.listOf types.str;
      default = [
        "0.nixos.pool.ntp.org"
        "1.nixos.pool.ntp.org"
        "2.nixos.pool.ntp.org"
      ];
      description = "NTP servers. Resolved through DNS policy once that path exists.";
    };
    ntp.via = mkOption {
      type = types.enum ["direct" "tunnel"];
      default = "direct";
      description = "Path for NTP when a tunnel exists. tunnel is not lowered yet.";
    };
    journal.persistent = mkOption {
      type = types.bool;
      default = false;
      description = "Persist the journal on the state partition. Default is volatile.";
    };
    journal.maxUse = mkOption {
      type = types.str;
      default = "64M";
      description = "journald SystemMaxUse when the journal is persistent.";
    };
    embedSource = mkOption {
      type = types.bool;
      default = true;
      description = "Embed the flake source tree at /etc/janus/source (FR-CFG-008).";
    };
  };

  options.janus.security.allowInlineSecrets = mkOption {
    type = types.bool;
    default = false;
    description = "Allow secret strings in the Nix store. Prefer sops files under secrets/ (docs/08 §11).";
  };

  options.janus.build.strategy = mkOption {
    type = types.enum ["native" "emulated" "cross"];
    default = "emulated";
    description = ''
      How mkRouter builds a foreign system. aarch64 defaults to emulated.
      armv7l and riscv64 default to cross. An aarch64 build host sets native.
      docs/09 §4.
    '';
  };

  config = {
    networking.hostName = cfg.hostName;
    time.timeZone = cfg.timeZone;
    system.stateVersion = mkDefault "26.05";

    services.timesyncd.enable = mkDefault true;
    services.timesyncd.servers = cfg.ntp.servers;

    services.journald.storage =
      if cfg.journal.persistent
      then "persistent"
      else "volatile";
    services.journald.extraConfig = mkIf cfg.journal.persistent ''
      SystemMaxUse=${cfg.journal.maxUse}
      Compress=yes
    '';

    # The board does not evaluate and does not switch generations (FR-OPS-001).
    nix.enable = false;
    system.switch.enable = false;
    system.disableInstallerTools = true;
    users.mutableUsers = false;
    documentation.enable = mkDefault false;
    programs.command-not-found.enable = mkDefault false;

    # The nix binary stays for boot-time activation and nix-store --import.
    # nix.enable = false does not install it. janus-build is not installed.
    environment.systemPackages = [
      pkgs.nix
      pkgs.f2fs-tools
    ];

    environment.etc."janus/build.json".source = buildJson;
    environment.etc."janus/source" = mkIf (cfg.embedSource && janusSource != null) {
      source = janusSource;
    };

    users.users.root.home = lib.mkForce "/var/lib/janus/root";
    systemd.tmpfiles.rules = [
      "d /var/lib/janus/root 0700 root root -"
      "L+ /root - - - - /var/lib/janus/root"
    ];

    warnings =
      lib.optional (cfg.embedSource && janusSource == null) ''
        janus.system.embedSource is true and mkRouter was not given source, so /etc/janus/source is absent.
        Pass source to lib.mkRouter, or set janus.system.embedSource = false.
      ''
      ++ lib.optional (cfg.ntp.via == "tunnel") ''
        janus.system.ntp.via = "tunnel" is not lowered yet. NTP uses the direct path.
      '';
  };
}
