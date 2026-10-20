# SPDX-License-Identifier: Apache-2.0
# Optional footprint reductions for image-size-constrained boards.
# Each knob is opt-in; boards on large media keep the full closure.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption mkIf mkDefault types;
  cfg = config.janus.system.footprint;

  trim = import ./kernel-trim.nix {inherit lib pkgs;};
in {
  options.janus.system.footprint = {
    dropGnupg = mkOption {
      type = types.bool;
      default = false;
      description = "Replace gnupg with a stub. Only systemd-importd pulls it in; a router never imports containers.";
    };
    trimKernelModules = mkOption {
      type = types.bool;
      default = false;
      description = "Strip unused kernel module trees (sound, GPU, wireless, ...) and rebuild the depmod index. Trims the default pkgs.linuxPackages kernel; a board that needs its own boot.kernelPackages must not enable this.";
    };
    binOnlyNix = mkOption {
      type = types.bool;
      default = false;
      description = "Install only nix's binaries instead of the whole package, dropping the nix-perl output and its perl closure from the system profile.";
    };
  };

  config = {
    assertions = [
      {
        # mkIf merges at option priority; a board that sets
        # boot.kernelPackages at default priority or higher would silently
        # replace the trimmed kernel with its own (this option is mkDefault).
        assertion =
          !cfg.trimKernelModules
          || ((config.boot.kernelPackages.kernel.passthru or {}) ? janusTrimmed);
        message = "janus.system.footprint.trimKernelModules did not take effect: another module set boot.kernelPackages.";
      }
    ];

    nixpkgs.overlays =
      lib.optional cfg.dropGnupg (
        final: prev: {
          gnupg = final.runCommand "gnupg-stub" {
            passthru.version = "0";
          } ''
            mkdir -p $out/bin
            for b in gpg gpg2; do
              printf '#!/bin/sh\nexit 0\n' > "$out/bin/$b"
              chmod +x "$out/bin/$b"
            done
          '';
        }
      );

    # mkDefault, not mkForce: a board that must set its own
    # boot.kernelPackages wins at normal priority, and the assertion above
    # then fails loudly instead of the image booting the wrong kernel.
    boot.kernelPackages =
      mkIf cfg.trimKernelModules
      (mkDefault (pkgs.linuxPackagesFor (trim.trimKernel pkgs.linuxPackages.kernel)));
  };
}
