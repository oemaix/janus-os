# SPDX-License-Identifier: Apache-2.0
# Redistributable closed firmware the phase 1 boards actually boot with.
# docs/10 §3. A license that is not redistributable stays blocked.
{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (
    builtins.elem config.janus.hardware.board [
      "nanopi-r4s"
      "le-potato"
      "rpi-zero-2w"
    ]
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
