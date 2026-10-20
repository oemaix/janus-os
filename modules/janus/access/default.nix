# SPDX-License-Identifier: Apache-2.0
# janus.access option types and the key assertion. OpenSSH lowering is phase 1.
# docs/08 §10, docs/14.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types mkForce;
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
      description = "Zones that accept SSH. Sets janus.firewall.services.ssh.zones unless that service is set directly.";
    };
    ssh.passwordAuthentication = mkOption {
      type = types.bool;
      default = false;
      description = "Password authentication. A key is still required.";
    };
    ssh.rootPasswordFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path of a root password hash on the state partition. Applied at boot when password authentication is on. Not a plaintext password.";
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
    web.passphraseSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        sops secret name for the maintenance page. The file is one line at
        `secrets/web/<host>.yaml`, encrypted to that host (ADR-0023).
        Not the SSH root password.
      '';
    };
    web.passphraseFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Passphrase file on the state partition, from `janus secrets put`. A string path, not a Nix path, so the secret is not copied into the store. Not the SSH root password.";
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
      {
        assertion = cfg.ssh.passwordAuthentication -> cfg.ssh.rootPasswordFile != null;
        message = "janus.access.ssh.passwordAuthentication requires janus.access.ssh.rootPasswordFile, a hash file on the state partition.";
      }
    ];

    janus.firewall.services.ssh = {
      zones = lib.mkDefault cfg.ssh.zones;
      port = lib.mkDefault cfg.ssh.port;
    };

    users.users.root.openssh.authorizedKeys.keys = cfg.ssh.authorizedKeys;

    # Force the key file to land as a symlink. The stock etc lowering can
    # materialise it as a regular file inside the basedir, which the
    # immutable erofs-metadata overlay then hides (metacopy has no metadata
    # for it), locking every key out on fresh state.
    environment.etc."ssh/authorized_keys.d/root" = {
      mode = "0444";
      source = mkForce (pkgs.writeText "root-authorized_keys" (lib.concatStringsSep "\n" cfg.ssh.authorizedKeys + "\n"));
    };

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
        MaxAuthTries = 3;
        X11Forwarding = false;
        AllowAgentForwarding = false;
        Ciphers = [
          "chacha20-poly1305@openssh.com"
          "aes256-gcm@openssh.com"
          "aes128-gcm@openssh.com"
          "aes256-ctr"
        ];
        KexAlgorithms = [
          "sntrup761x25519-sha512"
          "curve25519-sha256"
          "curve25519-sha256@libssh.org"
        ];
        Macs = [
          "hmac-sha2-512-etm@openssh.com"
          "hmac-sha2-256-etm@openssh.com"
        ];
      };
      hostKeys = [
        {
          type = "ed25519";
          path = "/var/lib/janus/etc/ssh/ssh_host_ed25519_key";
        }
      ];
    };
    systemd.services.sshd.after = ["janus-seed.service"];

    systemd.services.janus-root-password = lib.mkIf (cfg.ssh.passwordAuthentication && cfg.ssh.rootPasswordFile != null) {
      description = "Apply the root password hash from the state partition";
      wantedBy = ["multi-user.target"];
      before = ["sshd.service"];
      after = ["var.mount" "janus-persist-etc.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [pkgs.coreutils pkgs.gawk pkgs.util-linux];
      script = ''
        set -eu
        install -d -m 0755 /var/lib/janus/etc
        if mountpoint -q /etc/shadow; then
          umount /etc/shadow
        fi
        cp -a /etc/shadow /run/janus-shadow
        mount --bind /run/janus-shadow /etc/shadow
        hash=$(tr -d '\n' < ${lib.escapeShellArg cfg.ssh.rootPasswordFile})
        if [ -z "$hash" ]; then
          echo "janus: root password hash file is empty" >&2
          exit 1
        fi
        tmp=$(mktemp)
        awk -F: -v hash="$hash" 'BEGIN{OFS=":"} $1=="root" {$2=hash} {print}' /etc/shadow > "$tmp"
        cat "$tmp" > /etc/shadow
        rm -f "$tmp"
        chmod 0000 /etc/shadow
      '';
    };

    environment.systemPackages = lib.optional cfg.cli.enable (import ../../../pkgs/janus-cli.nix { inherit pkgs; });
  };
}
