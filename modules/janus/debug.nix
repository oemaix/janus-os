# SPDX-License-Identifier: Apache-2.0
# Bench switches. Each defaults to off. docs/08 §13, D-0067, D-0068, D-0069.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types mkIf mkMerge;
  cfg = config.janus.debug;
  # The NixOS serial line is agetty <options> %I --keep-baud $TERM.
  # Insert --autologin root before the port. A copied argument list would
  # drop the next flag NixOS adds (D-0067).
  templateExec = config.systemd.services."serial-getty@".serviceConfig.ExecStart or [];
  templateCmd =
    if builtins.isList templateExec
    then lib.last (lib.filter (s: s != "") templateExec)
    else toString templateExec;
  autologinCmd = lib.replaceStrings [" %I "] [" --autologin root %I "] templateCmd;
  consoleName = param: let
    matched = builtins.match "console=([^,]+).*" param;
  in
    if matched == null
    then null
    else builtins.head matched;
  isSerial = name: builtins.match "tty(S|AMA|AML|GS|USB|MXC)[0-9]+" name != null;
  serialConsoles = lib.unique (builtins.filter isSerial (builtins.filter (n: n != null) (map consoleName config.boot.kernelParams)));
  # A failed grow must still reach janus-state-recover (D-0049).
  # The shell unit runs only when the check left the stamp (T-0028).
  shellOnFailure = {
    OnFailure = "janus-debug-shell.service";
    OnFailureJobMode = "replace-irreversibly";
  };
  initrdDropIn = pkgs.writeText "janus-debug-initrd.conf" ''
    [Unit]
    OnFailure=
  '';
in {
  options.janus.debug = {
    serialAutologin = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Log in as root on each serial console named by console=.
        Virtual terminals and any other UART keep a login prompt.
        SSH is unchanged. Anyone who can open that serial port gets a
        root shell. Default is off (D-0067).
      '';
    };
    initrdShell = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open a root shell on the console when the state check or the
        resize fails. A missing state device still stops the boot
        without that shell.
        fsck.f2fs is on the shell's path. A failed grow still continues
        into the check. Default is off (D-0068).
      '';
    };
    kernelLogLevel = mkOption {
      type = types.nullOr (types.ints.between 0 7);
      default = null;
      example = 7;
      description = ''
        Kernel console loglevel. Unset leaves the image at 4.
        7 prints debug. Default is unset (D-0068).
      '';
    };
    tools = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install tcpdump, ethtool, iw, conntrack, and strace.
        Default is off (D-0068).
      '';
    };
    engineLog = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Render the proxy engine log at debug. sing-box uses log.level
        and xray uses log.loglevel. The runtime render keeps the level.
        Default is off (D-0068).
      '';
    };
    closedFailLog = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Log packets the closed-fail path drops. sing-box logs the
        blackhole default in table 2022. xray logs mark 0x4a02 while
        the process is down. Default is off (D-0069).
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.serialAutologin {
      warnings =
        [
          ''
            janus.debug.serialAutologin is on. The serial console logs in as root with no password. Turn it off before an image leaves the bench.
          ''
        ]
        ++ lib.optional (serialConsoles == []) ''
          janus.debug.serialAutologin is on and this image has no serial console=. Nothing logs in.
        '';
      environment.etc = lib.mapAttrs' (dev: _: {
        name = "systemd/system/serial-getty@${dev}.service.d/autologin.conf";
        value.text = ''
          [Service]
          ExecStart=
          ExecStart=${autologinCmd}
        '';
      }) (lib.genAttrs serialConsoles (_: null));
    })
    (mkIf cfg.initrdShell {
      warnings = [
        ''
          janus.debug.initrdShell is on. A failed state check opens a root shell in the initrd. Turn it off before an image leaves the bench.
        ''
      ];
      # The shell's PATH is /bin. The recover unit's path does not apply
      # there. f2fs-tools also comes from the storage initrd support.
      boot.initrd.systemd.shell.enable = true;
      boot.initrd.systemd.initrdBin = [pkgs.f2fs-tools];
      # Vendor initrd.target starts emergency on every failed boot. That
      # would hand out a shell for a missing disk. Clear it. The bench
      # shell is janus-debug-shell, and only after a check (T-0028).
      boot.initrd.systemd.contents."/etc/systemd/system/initrd.target.d/janus-debug.conf".source = initrdDropIn;
      boot.initrd.systemd.services.janus-debug-shell = {
        description = "Root shell after a failed state check";
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/run/janus/state-check-failed";
        };
        serviceConfig = {
          Type = "simple";
          ExecStart = "/bin/sh";
          StandardInput = "tty-force";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/console";
        };
      };
      boot.initrd.systemd.services.janus-state-recover.unitConfig = shellOnFailure;
      boot.initrd.systemd.services.janus-state-fsck-full.unitConfig = shellOnFailure;
    })
    (mkIf (cfg.kernelLogLevel != null) {
      warnings = lib.optional (cfg.kernelLogLevel > 4) ''
        janus.debug.kernelLogLevel is ${toString cfg.kernelLogLevel}. The console prints kernel messages at that level. Unset leaves loglevel 4. Turn it off before an image leaves the bench.
      '';
      boot.consoleLogLevel = cfg.kernelLogLevel;
    })
    (mkIf cfg.tools {
      warnings = [
        ''
          janus.debug.tools is on. The image includes tcpdump, ethtool, iw, conntrack, and strace. Turn it off before an image leaves the bench.
        ''
      ];
      environment.systemPackages = [
        pkgs.tcpdump
        pkgs.ethtool
        pkgs.iw
        pkgs.conntrack-tools
        pkgs.strace
      ];
    })
    (mkIf cfg.engineLog {
      warnings = [
        ''
          janus.debug.engineLog is on. The proxy engine log level is debug. Turn it off before an image leaves the bench.
        ''
      ];
    })
    (mkIf cfg.closedFailLog {
      warnings = [
        ''
          janus.debug.closedFailLog is on. Dropped closed-fail packets are written to the kernel log. Turn it off before an image leaves the bench.
        ''
      ];
    })
  ];
}
