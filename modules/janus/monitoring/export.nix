# SPDX-License-Identifier: Apache-2.0
# IPFIX/NetFlow export and the Prometheus endpoint. FR-MON-003, FR-MON-004.
# docs/04 monitoring, docs/08 §8, docs/12 §8.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.monitoring;
  net = config.janus.network;

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

  # Names in janus.monitoring.interfaces are configuration names.
  # softflowd needs the kernel device (eth0, ppp-<wan>, br-<lan>).
  knownIface = name:
    if net.wans ? ${name}
    then wanIface name
    else if net.lans ? ${name}
    then "br-${name}"
    else if net.ports ? ${name}
    then portIface name
    else if vlanByRef name != null
    then vlanNetdev net.vlans.${vlanByRef name}
    else if net.wifi ? ${name}
    then "wifi-${name}"
    else null;

  unknownIfaces =
    if cfg.interfaces == "all"
    then []
    else lib.filter (name: knownIface name == null) cfg.interfaces;

  exportIfaces = lib.unique (
    if cfg.interfaces == "all"
    then
      map wanIface (lib.attrNames net.wans)
      ++ map (n: "br-${n}") (lib.attrNames net.lans)
    else lib.filter (name: name != null) (map knownIface cfg.interfaces)
  );

  flowVersion =
    if cfg.flows.export.protocol == "netflow9"
    then "9"
    else "10";

  flowPkg = pkgs.writeShellApplication {
    name = "janus-flow-export";
    runtimeInputs = [pkgs.softflowd pkgs.coreutils];
    text = builtins.readFile ../../../pkgs/janus-flow-export.sh;
  };

  metricsPkg = pkgs.writeShellApplication {
    name = "janus-metrics";
    runtimeInputs = with pkgs; [jq coreutils curl systemd];
    text = builtins.readFile ../../../pkgs/janus-metrics.sh;
  };

  exporting = cfg.flows.export.collector != null;
in {
  config = lib.mkMerge [
    {
      warnings = lib.optional (cfg.scope == "flows" && !exporting) ''
        janus.monitoring.scope is flows, and flows.export.collector is unset, so no flows are exported.
      '';
      assertions = [
        {
          assertion = unknownIfaces == [];
          message = "janus.monitoring.interfaces contains a name that is not a WAN, LAN, port, VLAN, or Wi-Fi network: ${lib.concatStringsSep ", " unknownIfaces}.";
        }
      ];
    }
    (lib.mkIf exporting {
      assertions = [
        {
          assertion = builtins.match "[0-9A-Za-z._-]+" cfg.flows.export.collector != null;
          message = "janus.monitoring.flows.export.collector must be a hostname or an IPv4 address.";
        }
        {
          assertion = exportIfaces != [];
          message = "janus.monitoring.flows.export.collector is set, and this router has no interface to export.";
        }
      ];
      systemd.tmpfiles.rules = [
        "d /var/lib/janus/monitoring 0755 root root -"
      ];
      systemd.services.janus-flow-export = {
        description = "Export IPFIX or NetFlow to the configured collector";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"];
        environment = {
          JANUS_COLLECTOR = "${cfg.flows.export.collector}:${toString cfg.flows.export.port}";
          JANUS_FLOW_VERSION = flowVersion;
          JANUS_FLOW_MAX = "8192";
        };
        serviceConfig = {
          Type = "simple";
          ExecStart = "${flowPkg}/bin/janus-flow-export ${lib.escapeShellArgs exportIfaces}";
          Restart = "on-failure";
          RestartSec = "5s";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
    })
    (lib.mkIf cfg.prometheus.enable {
      assertions =
        [
          {
            assertion = cfg.prometheus.zones != [];
            message = "janus.monitoring.prometheus.zones must name at least one zone.";
          }
        ]
        ++ map (zone: {
          assertion = config.janus.firewall.zones ? ${zone};
          message = "janus.monitoring.prometheus.zones contains '${zone}', which is not a firewall zone.";
        })
        cfg.prometheus.zones;

      services.prometheus.exporters.node = {
        enable = true;
        port = 9100;
        # [::] is dual-stack for this exporter: IPv6, and IPv4 on Linux.
        listenAddress = "[::]";
        openFirewall = false;
        extraFlags = [
          "--collector.textfile.directory=/var/lib/janus/monitoring/textfile"
        ];
      };

      janus.firewall.services.prometheus = {
        zones = cfg.prometheus.zones;
        port = 9100;
        # A LAN with input = accept must not reopen this port.
        confine = true;
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/janus/monitoring 0755 root root -"
        "d /var/lib/janus/monitoring/textfile 0755 root root -"
      ];

      systemd.services.janus-metrics = {
        description = "Write engine metrics for the Prometheus textfile collector";
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${metricsPkg}/bin/janus-metrics collect";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ReadWritePaths = "/var/lib/janus/monitoring";
        };
      };

      systemd.timers.janus-metrics = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "60s";
        };
      };
    })
  ];
}
