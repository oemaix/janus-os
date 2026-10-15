# SPDX-License-Identifier: Apache-2.0
# janus.access option types and the key assertion. OpenSSH lowering is phase 1.
# docs/08 §10, docs/14.
{
  config,
  lib,
  pkgs,
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
      description = "Install the janus command (docs/14).";
    };
    web.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Include the maintenance page (docs/20). Runtime start and stop do not change this.";
    };
    web.port = mkOption {
      type = types.port;
      default = 8443;
      description = "TLS port for the maintenance page.";
    };
    web.zones = mkOption {
      type = types.listOf types.str;
      default = ["lan" "mgmt"];
      description = "Zones that may open the maintenance page. wan is refused.";
    };
    web.passphraseFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Passphrase file for the maintenance page. A string path, not a Nix path, so the secret is not copied into the store. Required when web.enable is true. Not the SSH root password.";
    };
    deploy.address = mkOption {
      type = types.str;
      default = config.janus.system.hostName;
      defaultText = "janus.system.hostName, or the nixosConfigurations attribute when mkRouter is given name";
      description = "SSH destination for janus-build deploy and janus-build fleet apply.";
    };
  };

  imports = [./web.nix];

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

    users.users.root.openssh.authorizedKeys.keys = cfg.ssh.authorizedKeys;

    services.openssh = {
      enable = true;
      ports = [cfg.ssh.port];
      settings = {
        PasswordAuthentication = cfg.ssh.passwordAuthentication;
        KbdInteractiveAuthentication = false;
        PermitRootLogin =
          if cfg.ssh.passwordAuthentication
          then "yes"
          else "prohibit-password";
      };
      hostKeys = [
        {
          type = "ed25519";
          path = "/var/lib/janus/etc/ssh/ssh_host_ed25519_key";
        }
      ];
    };
    systemd.services.sshd.after = ["janus-seed.service"];

    environment.systemPackages = lib.optional cfg.cli.enable (pkgs.writeShellApplication {
      name = "janus";
      runtimeInputs = with pkgs; [jq iproute2 nftables vnstat coreutils systemd util-linux gnutar];
      text = builtins.readFile ../../../pkgs/janus.sh;
    });
  };
}
