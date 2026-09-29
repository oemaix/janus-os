# SPDX-License-Identifier: Apache-2.0
# janus.remoteAccess option types. Tailscale lowering is phase 3. docs/08 §9.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.janus.remoteAccess;
in {
  options.janus.remoteAccess = {
    tailscale.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Join a tailnet. tailscale0 joins the mgmt zone.";
    };
    tailscale.authKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Auth key file from sops.";
    };
    tailscale.loginServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Headscale URL. Null uses Tailscale coordination.";
    };
    tailscale.advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "LAN prefixes offered to the tailnet.";
    };
    tailscale.exitNode = mkOption {
      type = types.bool;
      default = false;
      description = "Offer the router as an exit node.";
    };
    wireguard = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          privateKeyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "WireGuard private key file.";
          };
          address = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Interface address.";
          };
          peer.publicKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Peer public key.";
          };
          peer.endpoint = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Peer endpoint.";
          };
          peer.allowedIPs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Allowed IPs.";
          };
          peer.persistentKeepalive = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Keepalive in seconds.";
          };
          via = mkOption {
            type = types.enum ["direct" "tunnel"];
            default = "direct";
            description = "Path used to reach the peer.";
          };
        };
      });
      default = {};
      description = "Optional WireGuard tunnel to a user endpoint. The interface joins mgmt.";
    };
  };

  config.warnings = lib.optional cfg.tailscale.enable ''
    janus.remoteAccess.tailscale is not lowered yet.
  '';
}
