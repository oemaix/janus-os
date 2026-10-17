# SPDX-License-Identifier: Apache-2.0
# janus.remoteAccess option types. Lowering is lower.nix. docs/08 §9.
{
  config,
  lib,
  options,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options.janus.remoteAccess = {
    tailscale.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Join a tailnet. tailscale0 joins the mgmt zone.";
    };
    tailscale.authKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        sops secret name. One line in `secrets/tailscale/<host>.yaml`,
        encrypted to that host. When tailscale is enabled, exactly one of
        this and `authKeyFile` is set.
      '';
    };
    tailscale.authKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Auth key file from `janus secrets put`.";
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

  config.assertions = [
    {
      assertion =
        !config.janus.remoteAccess.tailscale.enable
        || (config.janus.remoteAccess.tailscale.authKeyFile != null)
        != (config.janus.remoteAccess.tailscale.authKeySecret != null);
      message = "janus.remoteAccess.tailscale.enable requires exactly one of authKeySecret and authKeyFile.";
    }
    {
      assertion =
        config.janus.remoteAccess.tailscale.authKeySecret == null
        || (
          (options ? sops)
          && (config.sops.secrets ? ${config.janus.remoteAccess.tailscale.authKeySecret})
          && (builtins.tryEval config.sops.secrets.${config.janus.remoteAccess.tailscale.authKeySecret}.sopsFile).success
        );
      message = "janus.remoteAccess.tailscale.authKeySecret needs sops.secrets.<name>.sopsFile.";
    }
  ];

  imports = [./lower.nix];
}
