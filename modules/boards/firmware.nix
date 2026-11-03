# SPDX-License-Identifier: Apache-2.0
# Redistributable closed firmware. docs/10 §3, §4.4, and §4.8.
# A license that is not redistributable stays blocked.
# Every implemented board can declare a USB peripheral that needs a blob.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;
in {
  options.janus.firmware.extraUnfree = mkOption {
    type = types.listOf types.str;
    default = [];
    description = ''
      Package names allowed in addition to redistributable closed firmware.
      A name here is not a redistributable blob. Soloist adds itself only
      while janus.soloist.enable is true.
    '';
  };

  config =
    mkIf (
      builtins.elem config.janus.hardware.board (builtins.attrNames (import ../../lib/boards.nix))
    ) {
      nixpkgs.config.allowUnfreePredicate = pkg: let
        licenses = lib.toList (pkg.meta.license or []);
        redistributable =
          builtins.any (
            license: (license.redistributable or false) && !(license.free or true)
          )
          licenses;
      in
        redistributable
        || lib.elem (pkg.pname or "") config.janus.firmware.extraUnfree;
    };
}
