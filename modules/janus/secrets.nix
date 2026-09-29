# SPDX-License-Identifier: Apache-2.0
# Age key path for sops-nix. ADR-0014, ADR-0022, docs/08 §11.
# The private key is installed with `janus secrets install-age-key`.
# It is not an output of the image.
{
  config,
  lib,
  options,
  ...
}: {
  config = lib.mkIf (options ? sops) {
    sops.age.keyFile = lib.mkDefault "/var/lib/janus/secrets/age.key";
    # The age key is the identity. SSH host keys are not age keys (ADR-0022).
    sops.age.sshKeyPaths = lib.mkDefault [];
    sops.gnupg.sshKeyPaths = lib.mkDefault [];
    systemd.services.sops-install-secrets = lib.mkIf (config.sops.secrets != {}) {
      after = ["var.mount"];
      wants = ["var.mount"];
    };
  };
}
