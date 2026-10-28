# SPDX-License-Identifier: Apache-2.0
# Age key path for sops-nix. ADR-0014, ADR-0022, docs/08 §11.
# The private key is installed with `janus secrets install-age-key`.
# It is not an output of the image.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.janus;
  # secret set stores one credential under the key `value`.
  # "" asks sops-nix for the whole document. PPPoE passwordSecret is username
  # and password. A node password file is that YAML document too.
  # A file option may name /run/secrets/<name> without the secret-name option.
  # mkDefault loses to a key the fleet set. The name is the last path
  # component, which is the sops-nix default path.
  secretName = path:
    if path != null && lib.hasPrefix "/run/secrets/" path
    then lib.removePrefix "/run/secrets/" path
    else null;
  namesOf = paths:
    lib.unique (lib.filter (name: name != null && !lib.hasInfix "/" name) (map secretName paths));
  fileNames = namesOf (
    [cfg.access.web.passphraseFile]
    ++ lib.mapAttrsToList (_: wg: wg.privateKeyFile) cfg.remoteAccess.wireguard
    ++ lib.mapAttrsToList (_: wan: wan.pppoe.passwordFile) cfg.network.wans
    ++ nodeFiles
  );
  oneLine =
    lib.optional (cfg.access.web.passphraseSecret != null) cfg.access.web.passphraseSecret
    ++ lib.optional (cfg.remoteAccess.tailscale.authKeySecret != null) cfg.remoteAccess.tailscale.authKeySecret
    ++ lib.mapAttrsToList (_: ap: ap.passphraseSecret) (
      lib.filterAttrs (_: ap: ap.passphraseSecret != null) cfg.network.wifi
    )
    ++ lib.mapAttrsToList (_: sub: sub.urlSecret) (
      lib.filterAttrs (_: sub: sub.urlSecret != null) cfg.proxy.subscriptions
    )
    ++ namesOf (
      [cfg.access.web.passphraseFile]
      ++ lib.mapAttrsToList (_: wg: wg.privateKeyFile) cfg.remoteAccess.wireguard
      ++ lib.mapAttrsToList (_: wan: wan.pppoe.passwordFile) cfg.network.wans
    );
  pppoe = lib.mapAttrsToList (_: wan: wan.pppoe.passwordSecret) (
    lib.filterAttrs (_: wan: wan.pppoe.passwordSecret != null) cfg.network.wans
  );
  nodeFiles = lib.concatLists (lib.mapAttrsToList (
      _: node:
        lib.optional (node.protocol == "trojan") node.trojan.passwordFile
        ++ lib.optional (node.protocol == "shadowsocks") node.shadowsocks.passwordFile
    )
    cfg.proxy.nodes);
in {
  config = lib.mkIf (options ? sops) {
    sops.age.keyFile = lib.mkDefault "/var/lib/janus/secrets/age.key";
    # The age key is the identity. SSH host keys are not age keys (ADR-0022).
    sops.age.sshKeyPaths = lib.mkDefault [];
    sops.gnupg.sshKeyPaths = lib.mkDefault [];
    # fleet apply copies a sops document to the inbox. The router runs
    # `sops decrypt` with its age key. The build host does not decrypt.
    environment.systemPackages = lib.optional (config.sops.secrets != {}) pkgs.sops;
    sops.secrets = lib.mkMerge [
      (lib.genAttrs oneLine (_: {key = lib.mkDefault "value";}))
      (lib.genAttrs pppoe (_: {key = lib.mkDefault "";}))
      (lib.genAttrs (namesOf nodeFiles) (_: {key = lib.mkDefault "";}))
    ];
    systemd.services.sops-install-secrets = lib.mkIf (config.sops.secrets != {}) {
      after = ["var.mount"];
      wants = ["var.mount"];
    };
    # A file path under /run/secrets/<name> selects that secret. It does not
    # create one. The assertion is separate from sops.secrets so this module
    # can set the key without reading the option it defines.
    assertions =
      map (name: {
        assertion = (builtins.tryEval config.sops.secrets.${name}.sopsFile).success;
        message = "A file at /run/secrets/${name} needs sops.secrets.${name}.sopsFile.";
      })
      fileNames;
  };
}
