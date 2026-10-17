# SPDX-License-Identifier: Apache-2.0
# Connection audit log. FR-MON-007, docs/14 §5.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.monitoring;
  lans = config.janus.network.lans;
  names =
    if cfg.audit.interfaces != []
    then cfg.audit.interfaces
    else lib.filter (n: lans.${n}.internal.intercept) (lib.attrNames lans);
  cidrs = map (n: "${lans.${n}.address}/${toString lans.${n}.prefixLength}") names;
  auditPkg = pkgs.writeShellApplication {
    name = "janus-audit";
    runtimeInputs = with pkgs; [jq gawk coreutils util-linux curl conntrack-tools systemd];
    text = builtins.readFile ../../../pkgs/janus-audit.sh;
  };
in {
  config = lib.mkIf cfg.audit.enable {
    assertions =
      [
        {
          assertion = builtins.match "[0-9]+[smhd]" cfg.audit.retention != null;
          message = "janus.monitoring.audit.retention must be a number followed by s, m, h, or d.";
        }
      ]
      ++ map (name: {
        assertion = lans ? ${name};
        message = "janus.monitoring.audit.interfaces contains '${name}', which is not a LAN.";
      })
      cfg.audit.interfaces;

    boot.kernel.sysctl."net.netfilter.nf_conntrack_acct" = 1;

    environment.etc."janus/audit.json".text = builtins.toJSON {
      enable = true;
      retention = cfg.audit.retention;
      path = "/var/lib/janus/audit/connections.jsonl";
      inherit cidrs;
    };

    environment.etc."janus/bin/janus-audit".source = "${auditPkg}/bin/janus-audit";

    systemd.services.janus-audit = {
      description = "Connection audit log";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      unitConfig.ConditionPathExists = "!/var/lib/janus/audit/paused";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${auditPkg}/bin/janus-audit record";
        Restart = "on-failure";
        RestartSec = "2s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = "/var/lib/janus/audit";
      };
    };
  };
}
