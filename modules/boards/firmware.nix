# SPDX-License-Identifier: Apache-2.0
# Redistributable closed firmware. docs/10 §3, §4.4, and §4.8.
# A license that is not redistributable stays blocked.
# Every implemented board can declare a USB peripheral that needs a blob.
{
  config,
  lib,
  ...
}: {
  config =
    lib.mkIf (
      builtins.elem config.janus.hardware.board (builtins.attrNames (import ../../lib/boards.nix))
    ) {
      nixpkgs.config.allowUnfreePredicate = pkg: let
        licenses = lib.toList (pkg.meta.license or []);
      in
        builtins.any (
          license: (license.redistributable or false) && !(license.free or true)
        )
        licenses;
    };
}
