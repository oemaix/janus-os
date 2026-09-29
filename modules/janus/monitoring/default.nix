# SPDX-License-Identifier: Apache-2.0
# janus.monitoring option types. Collectors are a later phase. docs/08 §8.
{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.janus.monitoring = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Per-interface counters.";
    };
    interfaces = mkOption {
      type = types.either (types.enum ["all"]) (types.listOf types.str);
      default = "all";
      description = "Interfaces to count. all means every WAN and LAN.";
    };
    scope = mkOption {
      type = types.enum ["counters" "per-host" "flows"];
      default = "counters";
      description = "How much traffic detail to keep.";
    };
    history.retentionDays = mkOption {
      type = types.int;
      default = 90;
      description = "vnstat retention in days.";
    };
    flows.export.collector = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "IPFIX collector address. Null disables export.";
    };
    flows.export.port = mkOption {
      type = types.port;
      default = 4739;
      description = "IPFIX port.";
    };
    flows.export.protocol = mkOption {
      type = types.enum ["ipfix" "netflow9"];
      default = "ipfix";
      description = "Flow export protocol.";
    };
    prometheus.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Prometheus endpoint on the management zone.";
    };
    prometheus.zones = mkOption {
      type = types.listOf types.str;
      default = ["mgmt"];
      description = "Zones that may scrape metrics.";
    };
    audit.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Connection audit log (FR-MON-007). One JSON object per line.";
    };
    audit.retention = mkOption {
      type = types.str;
      default = "7d";
      description = "Cap on audit records on the state partition.";
    };
    audit.interfaces = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Interfaces to audit. Empty means the proxied LANs.";
    };
  };
}
