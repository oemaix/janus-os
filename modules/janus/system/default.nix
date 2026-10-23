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
        subscriptions =
          lib.mapAttrs (_: sub: {
            enable = sub.enable;
            format = sub.format;
            via = sub.via;
            refresh = sub.refresh;
            secret = sub.urlSecret != null;
          })
          config.janus.proxy.subscriptions;
      };
      passAsFile = ["metaJson"];
    } ''
      date=$(date -u -d "@''${SOURCE_DATE_EPOCH:-0}" +%Y-%m-%dT%H:%M:%SZ)
      jq --arg date "$date" '. + {buildDate: $date}' "$metaJsonPath" > "$out"
    '';

  # JSON rejects a leading zero, and cron writes 08. All-zero is 0.
  decimal = v:
    if builtins.match "0+" v != null
    then 0
    else let
      m = builtins.match "0*([1-9][0-9]*)" v;
    in
      if m == null
      then -1
      else lib.toInt (builtins.head m);

  inRange = lo: hi: v: let
    n = decimal v;
  in
    n >= lo && n <= hi;

  pad2 = v:
    if lib.stringLength v < 2
    then "0${v}"
    else v;

  # monthly and yearly are fixed clocks. A cron may name the day and the
  # month. The weekday stays *, so this does not grow a second weekday dialect.
  # A short list returns null. It does not index past the end.
  rebootCalendar = s:
    if s == "monthly"
    then "*-*-01 04:00:00"
    else if s == "yearly"
    then "*-01-01 04:00:00"
    else let
      parts = lib.splitString " " s;
      minute = builtins.elemAt parts 0;
      hour = builtins.elemAt parts 1;
      day = builtins.elemAt parts 2;
      month = builtins.elemAt parts 3;
      dow = builtins.elemAt parts 4;
      dayPart =
        if day == "*"
        then "*"
        else pad2 day;
      monthPart =
        if month == "*"
        then "*"
        else pad2 month;
      cronOk =
        lib.length parts
        == 5
        && dow == "*"
        && inRange 0 59 minute
        && inRange 0 23 hour
        && (day == "*" || inRange 1 31 day)
        && (month == "*" || inRange 1 12 month);
    in
      if cronOk
      then "*-${monthPart}-${dayPart} ${pad2 hour}:${pad2 minute}:00"
      else null;
in {
  imports = [./kernel-profile.nix];

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
    reboot.schedule = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "monthly";
      description = "Maintenance reboot. Null is off. monthly is 04:00 on the 1st. yearly is 04:00 on 1 January. A five-field cron is minute, hour, day, month, and a day-of-week of *. Further actions on this reboot are sibling options.";
    };
    reboot.fsck = mkOption {
      type = types.bool;
      default = false;
      description = "On the maintenance reboot, run a full fsck of the state partition and let it finish. The request is removed before that check, so a check that does not finish is not repeated. A normal boot does not.";
    };
  };

  options.janus.security.allowInlineSecrets = mkOption {
    type = types.bool;
    default = false;
    description = "Allow secret strings in the Nix store. Prefer sops files under secrets/ (docs/08 §11).";
  };

  options.janus.build.strategy = mkOption {
    type = types.enum ["native" "emulated" "cross"];
    default = let
      target = (import ../../../lib/boards.nix).${config.janus.hardware.board} or "";
    in
      if target == "armv7l-linux" || target == "riscv64-linux"
      then "cross"
      else "emulated";
    description = ''
      How mkRouter builds a foreign system. aarch64 and x86_64 default to emulated.
      armv7l and riscv64 default to cross. An aarch64 build host sets native.
      docs/09 §4.
    '';
  };

  config = {
    assertions = [
      {
        assertion = !cfg.reboot.fsck || cfg.reboot.schedule != null;
        message = "janus.system.reboot.fsck needs janus.system.reboot.schedule.";
      }
      {
        assertion = cfg.reboot.schedule == null || rebootCalendar cfg.reboot.schedule != null;
        message = "janus.system.reboot.schedule is monthly, yearly, or a five-field cron whose day-of-week is *.";
      }
    ];

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

    systemd.timers.janus-reboot = mkIf (cfg.reboot.schedule != null) {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = rebootCalendar cfg.reboot.schedule;
        Persistent = true;
        RandomizedDelaySec = "10min";
        Unit = "janus-reboot.service";
      };
    };

    # The service only reboots. A switch such as reboot.fsck is a unit
    # that this service requires, so later maintenance can be added beside it.
    systemd.services.janus-reboot = mkIf (cfg.reboot.schedule != null) {
      description = "Reboot on the Janus maintenance schedule";
      serviceConfig.Type = "oneshot";
      path = [pkgs.systemd];
      script = ''
        set -eu
        systemctl reboot
      '';
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
