# SPDX-License-Identifier: Apache-2.0
# Tailscale and optional WireGuard into the mgmt zone. docs/08 §9.
# No reverse SSH.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.janus.remoteAccess;
  ts = cfg.tailscale;
  routes = lib.concatStringsSep "," ts.advertiseRoutes;
  routing =
    if ts.advertiseRoutes != [] && ts.exitNode
    then "both"
    else if ts.advertiseRoutes != [] || ts.exitNode
    then "server"
    else "none";
  authKey =
    if ts.authKeySecret != null
    then config.sops.secrets.${ts.authKeySecret}.path
    else ts.authKeyFile;
in {
  config = lib.mkMerge [
    (lib.mkIf ts.enable {
      services.tailscale = {
        enable = true;
        authKeyFile = authKey;
        extraUpFlags =
          lib.optional (ts.loginServer != null) "--login-server=${ts.loginServer}"
          ++ lib.optional (ts.advertiseRoutes != []) "--advertise-routes=${routes}"
          ++ lib.optional ts.exitNode "--advertise-exit-node";
        useRoutingFeatures = routing;
      };
      systemd.services = lib.mkIf (ts.authKeySecret != null) {
        tailscaled = {
          after = ["sops-install-secrets.service"];
          requires = ["sops-install-secrets.service"];
        };
        tailscale-autoconnect = {
          after = ["sops-install-secrets.service"];
          wants = ["sops-install-secrets.service"];
        };
        janus-tailscale-auth = {
          description = "Tailscale auth key is present";
          requiredBy = ["tailscaled.service"];
          before = ["tailscaled.service"];
          after = ["sops-install-secrets.service"];
          requires = ["sops-install-secrets.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/test -s ${lib.escapeShellArg authKey}";
          };
        };
      };
    })
    (lib.mkIf (cfg.wireguard != {}) {
      networking.wireguard.interfaces =
        lib.mapAttrs' (name: wg: {
          name = "wg-${name}";
          value =
            {
              ips = lib.optional (wg.address != null) wg.address;
              privateKeyFile = wg.privateKeyFile;
              peers = lib.optional (wg.peer.publicKey != null) {
                publicKey = wg.peer.publicKey;
                endpoint = wg.peer.endpoint;
                allowedIPs = wg.peer.allowedIPs;
                persistentKeepalive = wg.peer.persistentKeepalive;
              };
            }
            // lib.optionalAttrs (wg.via == "tunnel") {fwMark = "74";};
        })
        cfg.wireguard;
      janus.firewall.zones.mgmt.interfaces = ["tailscale0"] ++ map (n: "wg-${n}") (lib.attrNames cfg.wireguard);
    })
  ];
}
