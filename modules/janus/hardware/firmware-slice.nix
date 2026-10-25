# SPDX-License-Identifier: Apache-2.0
# Copy named files out of the pinned linux-firmware package.
# The image does not install the rest of that collection. docs/10 §3.3, §4.4, §4.8.
{
  lib,
  pkgs,
  # Runs the copy. mkRouter passes the build host. The files still come
  # from the board's linux-firmware.
  builderPkgs ? pkgs,
}: {
  pname,
  description,
  paths,
}:
builderPkgs.stdenvNoCC.mkDerivation {
  inherit pname;
  inherit (pkgs.linux-firmware) version;
  dontUnpack = true;
  dontBuild = true;
  dontFixup = true;
  installPhase = ''
    fw=${pkgs.linux-firmware}/lib/firmware
    ${lib.concatMapStrings (rel: let
        quoted = lib.escapeShellArg rel;
      in ''
        if [ ! -e "$fw/"${quoted} ]; then
          echo "linux-firmware has no "${quoted} >&2
          exit 1
        fi
        mkdir -p "$out/lib/firmware/$(dirname ${quoted})"
        cp -L "$fw/"${quoted} "$out/lib/firmware/"${quoted}
      '')
      paths}
  '';
  meta = {
    inherit description;
    license = lib.licenses.unfreeRedistributableFirmware;
    sourceProvenance = with lib.sourceTypes; [binaryFirmware];
  };
}
