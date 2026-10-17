# SPDX-License-Identifier: Apache-2.0
# Age key path for sops-nix. ADR-0014, ADR-0022, docs/08 §11.
# The private key is installed with `janus secrets install-age-key`.
# It is not an output of the image.
{
  config,
  lib,
  options,
  ...
}: let
  cfg = config.janus;
  # secret set stores one credential under the key `value`.
  # "" asks sops-nix for the whole document. PPPoE is username and password.
  # Node files are whole documents too, and WireGuard is `value`, but neither
  # has a secret-name option, so the fleet sets that key.
  oneLine =
    lib.optional (cfg.access.web.passphraseSecret != null) cfg.access.web.passphraseSecret
    ++ lib.optional (cfg.remoteAccess.tailscale.authKeySecret != null) cfg.remoteAccess.tailscale.authKeySecret
    ++ lib.mapAttrsToList (_: ap: ap.passphraseSecret) (
      lib.filterAttrs (_: ap: ap.passphraseSecret != null) cfg.network.wifi
    )
    ++ lib.mapAttrsToList (_: sub: sub.urlSecret) (
      lib.filterAttrs (_: sub: sub.urlSecret != null) cfg.proxy.subscriptions
    );
  pppoe = lib.mapAttrsToList (_: wan: wan.pppoe.passwordSecret) (
    lib.filterAttrs (_: wan: wan.pppoe.passwordSecret != null) cfg.network.wans
  );
in {
  config = lib.mkIf (options ? sops) {
    sops.age.keyFile = lib.mkDefault "/var/lib/janus/secrets/age.key";
    # The age key is the identity. SSH host keys are not age keys (ADR-0022).
    sops.age.sshKeyPaths = lib.mkDefault [];
    sops.gnupg.sshKeyPaths = lib.mkDefault [];
    sops.secrets = lib.mkMerge [
      (lib.genAttrs oneLine (_: {key = lib.mkDefault "value";}))
      (lib.genAttrs pppoe (_: {key = lib.mkDefault "";}))
    ];
    systemd.services.sops-install-secrets = lib.mkIf (config.sops.secrets != {}) {
      after = ["var.mount"];
      wants = ["var.mount"];
    };
  };
}
