# SPDX-License-Identifier: Apache-2.0
# Closure-deploy rollback. docs/09 §8.2.
# The first boot after a pending deploy only records that it booted.
# A later boot without deploy-confirmed rolls the system profile back.
# There is no bootloader menu for this.
{pkgs, ...}: let
  bootScript = pkgs.writeText "janus-boot-install.sh" (builtins.readFile ../../pkgs/janus-boot-install.sh);
in {
  config = {
    systemd.services.janus-deploy-rollback = {
      description = "Confirm or roll back a closure deploy";
      wantedBy = ["multi-user.target"];
      enable = true;
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        pending=/var/lib/janus/deploy-pending
        confirmed=/var/lib/janus/deploy-confirmed
        booted=/var/lib/janus/deploy-booted
        if [ ! -e "$pending" ]; then
          exit 0
        fi
        if [ -e "$confirmed" ]; then
          rm -f "$pending" "$confirmed" "$booted"
          exit 0
        fi
        if [ -e "$booted" ]; then
          mount -o remount,rw /nix || true
          ${pkgs.bash}/bin/bash ${bootScript} restore
          ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --rollback
          rm -f "$pending" "$booted"
          ${pkgs.systemd}/bin/systemctl reboot
          exit 0
        fi
        touch "$booted"
      '';
    };
  };
}
