# SPDX-License-Identifier: Apache-2.0
# janus.firewall option types and nftables lowering. docs/06 §7–8, docs/08 §5.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  imports = [./lower.nix];

  options.janus.firewall = {
    zones = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          interfaces = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Interfaces in this zone. Empty means the automatic set for that zone name.";
          };
          input = mkOption {
            type = types.enum ["accept" "drop" "reject" "ssh"];
            default = "drop";
            description = "Default policy for traffic to the router.";
          };
          forward = mkOption {
            type = types.enum ["accept" "drop" "reject"];
            default = "drop";
            description = "Default policy for traffic forwarded through the router.";
          };
        };
      });
      default = {
        wan = {
          input = "drop";
          forward = "drop";
        };
        lan = {
          input = "accept";
          forward = "accept";
        };
        mgmt = {
          interfaces = ["tailscale0"];
          input = "ssh";
          forward = "drop";
        };
      };
      description = "Firewall zones. docs/06 §8.";
    };
    policies = mkOption {
      type = types.listOf (types.submodule {
        options = {
          from = mkOption {
            type = types.str;
            description = "Source zone.";
          };
          to = mkOption {
            type = types.str;
            description = "Destination zone.";
          };
          action = mkOption {
            type = types.enum ["accept" "drop" "reject"];
            description = "Policy action.";
          };
        };
      });
      default = [
        {
          from = "lan";
          to = "wan";
          action = "accept";
        }
      ];
      description = "Zone-to-zone default policies.";
    };
    rules = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Rule name.";
          };
          from = mkOption {
            type = types.str;
            description = "Source zone.";
          };
          to = mkOption {
            type = types.str;
            description = "Destination zone.";
          };
          protocol = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Transport protocol.";
          };
          dport = mkOption {
            type = types.nullOr (types.either types.int types.str);
            default = null;
            description = "Destination port or range.";
          };
          dest = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Destination address.";
          };
          action = mkOption {
            type = types.enum ["accept" "drop" "reject"];
            description = "Rule action.";
          };
        };
      });
      default = [];
      description = "Extra zone rules.";
    };
    services = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          zones = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Zones where this service is accepted.";
          };
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = "Service port.";
          };
        };
      });
      default = {
        ssh = {
          zones = ["lan" "mgmt"];
          port = 22;
        };
        dns = {zones = ["lan"];};
        icmp = {zones = ["*"];};
      };
      description = "Router services opened in the named zones.";
    };
    portForwards = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          wan = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "WAN name, or null for every default WAN.";
          };
          protocol = mkOption {
            type = types.enum ["tcp" "udp" "tcp+udp"];
            default = "tcp";
            description = "Forwarded protocol.";
          };
          externalPort = mkOption {
            type = types.either types.int types.str;
            description = "External port or range.";
          };
          to.host = mkOption {
            type = types.str;
            description = "Internal host.";
          };
          to.port = mkOption {
            type = types.int;
            description = "Internal port.";
          };
          sourceAllow = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Source prefixes allowed to use the forward.";
          };
          hairpin = mkOption {
            type = types.bool;
            default = true;
            description = "NAT reflection.";
          };
        };
      });
      default = {};
      description = "Destination NAT. docs/06 §7.";
    };
    hooks = mkOption {
      type = types.submodule {
        options = {
          preroutingRaw = mkOption {
            type = types.str;
            default = "";
            description = "Raw nftables snippet in prerouting.";
          };
          forwardExtra = mkOption {
            type = types.str;
            default = "";
            description = "Raw nftables snippet in forward.";
          };
          inputExtra = mkOption {
            type = types.str;
            default = "";
            description = "Raw nftables snippet in input.";
          };
        };
      };
      default = {};
      description = "Raw nftables hooks.";
    };
    rateLimits.sshNew = mkOption {
      type = types.str;
      default = "10/minute";
      description = "Rate limit for new SSH connections.";
    };
  };
}
