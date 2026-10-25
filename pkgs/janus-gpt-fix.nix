# SPDX-License-Identifier: Apache-2.0
# Host and board tool for the Le Potato backup GPT. docs/10 §3.6.
{stdenv}:
stdenv.mkDerivation {
  pname = "janus-gpt-fix";
  version = "0.1.0";
  src = ./janus-gpt-fix.c;
  dontUnpack = true;
  buildPhase = ''
    $CC -O2 -Wall -Wextra -Werror -o janus-gpt-fix $src
  '';
  installPhase = ''
    install -Dm755 janus-gpt-fix $out/bin/janus-gpt-fix
  '';
}
