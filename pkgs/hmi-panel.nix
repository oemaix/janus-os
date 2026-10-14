# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
}:
stdenv.mkDerivation {
  pname = "janus-hmi-panel";
  version = "0.1.0";
  src = stdenv.mkDerivation {
    name = "janus-hmi-panel-src";
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out
      cp ${./janus-hmi-panel.c} $out/janus-hmi-panel.c
      cp ${./font6x8.h} $out/font6x8.h
    '';
  };
  dontUnpack = true;
  buildPhase = ''
    $CC -O2 -Wall -Wextra -Werror -I$src -o janus-hmi-panel $src/janus-hmi-panel.c
  '';
  installPhase = ''
    mkdir -p $out/bin
    install -m 0755 janus-hmi-panel $out/bin/janus-hmi-panel
  '';
}
