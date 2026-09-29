# SPDX-License-Identifier: Apache-2.0
# janus.access option types and the key assertion. OpenSSH lowering is phase 1.
# docs/08 §10, docs/14.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.janus.access;
in {
  options.janus.access = {
    ssh.authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "SSH public keys. At least one is required (FR-ACC-001).";
    };
    ssh.port = mkOption {
      type = types.port;
      default = 22;
      description = "SSH listen port.";
    };
    ssh.zones = mkOption {
      type = types.listOf types.str;
      default = ["lan" "mgmt"];
      description = "Zones where SSH listens.";
    };
    ssh.passwordAuthentication = mkOption {
      type = types.bool;
      default = false;
      description = "Password authentication. A key is still required.";
    };
    ssh.rootPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path of a root password file. Only meaningful with password authentication.";
    };
    cli.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install the janus command. The program is specified in docs/14 and implemented in a later phase.";
    };
    deploy.address = mkOption {
      type = types.str;
      default = config.janus.system.hostName;
      defaultText = "janus.system.hostName, or the nixosConfigurations attribute when mkRouter is given name";
      description = "SSH destination for janus-build deploy and janus-build fleet apply.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.ssh.authorizedKeys != [];
        message = "janus.access.ssh.authorizedKeys must contain at least one public key (FR-ACC-001).";
      }
      {
        assertion = cfg.ssh.passwordAuthentication -> cfg.ssh.authorizedKeys != [];
        message = "janus.access.ssh.passwordAuthentication still requires at least one authorized key.";
      }
    ];

    # The key is what the image boots with. sshd itself is phase 1: host keys
    # have to live on the state partition, and the listen zones are not enforced yet.
    users.users.root.openssh.authorizedKeys.keys = cfg.ssh.authorizedKeys;
  };
}
