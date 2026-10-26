# SPDX-License-Identifier: Apache-2.0
# Bench switches. Each defaults to off. docs/08 §13, D-0056, D-0057.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types mkIf mkForce mkMerge;
  cfg = config.janus.debug;
  getty = config.services.getty;
  # Same agetty line as nixos/modules/services/ttys/getty.nix, plus --autologin
  # root. %I and $TERM stay systemd tokens, so they are not shell-quoted.
  # --keep-baud keeps the speed from console= (1500000 on ROCK Pi 4C).
  baseArgs =
    [
      "--login-program"
      getty.loginProgram
      "--issue-file"
      "/etc/issue:/etc/issue.d:/run/issue:/run/issue.d"
      "--autologin"
      "root"
    ]
    ++ lib.optionals (getty.loginOptions != null) [
      "--login-options"
      getty.loginOptions
    ]
    ++ getty.extraArgs;
  serialCmd = "${lib.getExe' pkgs.util-linux "agetty"} ${lib.escapeShellArgs baseArgs} %I --keep-baud $TERM";
  # A failed grow must still reach janus-state-recover (D-0049).
  shellOnFailure = {
    OnFailure = "emergency.target";
    OnFailureJobMode = "replace-irreversibly";
  };
in {
  options.janus.debug = {
    serialAutologin = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Log in as root on the board serial console, with no password.
        Virtual terminals keep a login prompt. SSH is unchanged.
        Anyone who can open the UART gets a root shell. Default is off (D-0056).
      '';
    };
    initrdShell = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open a root shell on the console when janus-state-recover or the
        full state check exits non-zero. fsck.f2fs is on that shell's
        path. A failed grow still continues into recover. Default is off (D-0057).
      '';
    };
    kernelLogLevel = mkOption {
      type = types.nullOr (types.ints.between 0 7);
      default = null;
      example = 7;
      description = ''
        Kernel console loglevel. Unset leaves the image at 4.
        7 prints debug. Default is unset (D-0057).
      '';
    };
    tools = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install tcpdump, ethtool, iw, and conntrack. Default is off (D-0057).
      '';
    };
    engineLog = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Render the proxy engine log at debug. sing-box uses log.level
        and xray uses log.loglevel. The runtime render keeps the level.
        Default is off (D-0057).
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.serialAutologin {
      warnings = [
        ''
          janus.debug.serialAutologin is on. The serial console logs in as root with no password. Turn it off before an image leaves the bench.
        ''
      ];
      systemd.services."serial-getty@".serviceConfig.ExecStart = mkForce [
        ""
        serialCmd
      ];
    })
    (mkIf cfg.initrdShell {
      warnings = [
        ''
          janus.debug.initrdShell is on. A failed state check opens a root shell in the initrd. Turn it off before an image leaves the bench.
        ''
      ];
      boot.initrd.systemd.emergencyAccess = true;
      # The emergency shell's PATH is /bin. The recover unit's path
      # does not apply there. The f2fs initrd support also installs
      # this package; the line keeps fsck.f2fs next to the shell.
      boot.initrd.systemd.initrdBin = [pkgs.f2fs-tools];
      boot.initrd.systemd.services.janus-state-recover.unitConfig = shellOnFailure;
      boot.initrd.systemd.services.janus-state-fsck-full.unitConfig = shellOnFailure;
    })
    (mkIf (cfg.kernelLogLevel != null) {
      warnings = [
        ''
          janus.debug.kernelLogLevel is ${toString cfg.kernelLogLevel}. The console prints kernel messages at that level. Unset leaves loglevel 4.
        ''
      ];
      boot.consoleLogLevel = cfg.kernelLogLevel;
    })
    (mkIf cfg.tools {
      warnings = [
        ''
          janus.debug.tools is on. The image includes tcpdump, ethtool, iw, and conntrack. Turn it off before an image leaves the bench.
        ''
      ];
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.ethtool
        pkgs.iw
        pkgs.conntrack-tools
      ];
    })
    (mkIf cfg.engineLog {
      warnings = [
        ''
          janus.debug.engineLog is on. The proxy engine log level is debug. Turn it off before an image leaves the bench.
        ''
      ];
    })
  ];
}
