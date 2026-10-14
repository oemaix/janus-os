# SPDX-License-Identifier: Apache-2.0
# Backup WAN failover. docs/06: a backup becomes active when the health
# checks of every lower-metric default fail. A backup's targets are used
# for a default that has none. Empty targets and no backup install no timer.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.network;
  names = lib.attrNames cfg.wans;
  watched = lib.filter (n: cfg.wans.${n}.healthCheck.enable && cfg.wans.${n}.healthCheck.targets != []) names;
  defaults = lib.filter (n: cfg.wans.${n}.role == "default") names;
  backup = lib.findFirst (n: cfg.wans.${n}.role == "backup") null names;
  backupOn =
    backup
    != null
    && cfg.wans.${backup}.healthCheck.enable
    && cfg.wans.${backup}.healthCheck.targets != [];

  targetsOf = name: let
    own = cfg.wans.${name}.healthCheck.targets;
  in
    if own != []
    then own
    else if backupOn
    then cfg.wans.${backup}.healthCheck.targets
    else [];

  probed = lib.unique (lib.filter (n: targetsOf n != []) ((lib.optionals backupOn defaults) ++ watched));

  portIface = name: let
    port = cfg.ports.${name} or null;
  in
    if port == null
    then name
    else if port.device != null
    then port.device
    else name;

  wanIface = name: let
    wan = cfg.wans.${name};
  in
    if wan.mode == "pppoe"
    then "ppp-${name}"
    else if wan.mode == "wwan"
    then "wwan-${wan.wwan.peripheral}"
    else portIface wan.uplink;

  backupIface =
    if backup == null
    then ""
    else wanIface backup;

  script = pkgs.writeShellScript "janus-wan-health" ''
    set -eu
    install -d -m 0755 /run/janus/wan
    backup=${lib.escapeShellArg (
      if backup == null
      then ""
      else backup
    )}
    probe() {
      iface=$1
      shift
      for target in "$@"; do
        if ${pkgs.iputils}/bin/ping -I "$iface" -c 1 -W 2 "$target" >/dev/null 2>&1; then
          return 0
        fi
      done
      return 1
    }
    healthy=0
    failed=0
    ${lib.concatMapStrings (name: ''
        name=${lib.escapeShellArg name}
        role=${lib.escapeShellArg cfg.wans.${name}.role}
        iface=${lib.escapeShellArg (wanIface name)}
        fails=/run/janus/wan/$name/fails
        install -d -m 0755 "/run/janus/wan/$name"
        count=0
        if [ -f "$fails" ]; then
          count=$(cat "$fails" || echo 0)
        fi
        if probe "$iface" ${lib.escapeShellArgs (targetsOf name)}; then
          count=0
          echo up > "/run/janus/wan/$name/health"
        else
          count=$((count + 1))
          echo down > "/run/janus/wan/$name/health"
        fi
        printf '%s\n' "$count" > "$fails"
        limit=${toString cfg.wans.${name}.healthCheck.failures}
        if [ "$role" = default ]; then
          if [ "$count" -ge "$limit" ]; then
            failed=$((failed + 1))
          else
            healthy=$((healthy + 1))
          fi
        fi
      '')
      probed}
    if [ -z "$backup" ] || [ "$failed" -eq 0 ] || [ "$healthy" -gt 0 ]; then
      if [ -n "$backup" ]; then
        bif=${lib.escapeShellArg backupIface}
        ${pkgs.iproute2}/bin/ip route del default dev "$bif" metric 50 2>/dev/null || true
      fi
      exit 0
    fi
    bif=${lib.escapeShellArg backupIface}
    gw=$(${pkgs.iproute2}/bin/ip -4 route show default dev "$bif" | ${pkgs.gawk}/bin/awk '{print $3; exit}')
    if [ -n "$gw" ]; then
      ${pkgs.iproute2}/bin/ip route replace default via "$gw" dev "$bif" metric 50
    fi
  '';
in {
  config = lib.mkIf (probed != []) {
    systemd.services.janus-wan-health = {
      description = "Probe WAN health and fail over to the backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = script;
      };
    };
    systemd.timers.janus-wan-health = {
      enable = true;
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.wans.${lib.head probed}.healthCheck.interval;
        AccuracySec = "1s";
      };
    };
  };
}
