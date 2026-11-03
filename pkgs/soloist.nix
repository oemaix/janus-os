# SPDX-License-Identifier: Apache-2.0
# Spotify Soloist. src is a flake input, one archive per architecture.
# The narHash lives in flake.lock. nix flake update moves it (T-0010).
{
  lib,
  stdenv,
  autoPatchelfHook,
  src,
}: let
  notes = builtins.readFile "${src}/CHANGELOG.md";
  release = lib.findFirst (line: lib.hasPrefix "## Release v" line) null (lib.splitString "\n" notes);
  version =
    if release == null
    then throw "The Soloist archive has no '## Release v' line in CHANGELOG.md."
    else lib.removePrefix "## Release v" release;
in
  stdenv.mkDerivation {
    pname = "soloist";
    inherit version;

    # The flake input is already the unpacked archive: soloist, the
    # changelog, and the license sit next to each other.
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    nativeBuildInputs = [autoPatchelfHook];
    # libatomic, and on aarch64 libgcc_s, come from this output.
    # libm, libpthread, libdl, librt, and libc come with the dynamic linker.
    buildInputs = [stdenv.cc.cc.lib];

    installPhase = ''
      runHook preInstall
      install -Dm755 ${src}/soloist "$out/bin/soloist"
      install -Dm644 ${src}/THIRD_PARTY_LICENSES.txt "$out/share/doc/soloist/THIRD_PARTY_LICENSES.txt"
      install -Dm644 ${src}/CHANGELOG.md "$out/share/doc/soloist/CHANGELOG.md"
      runHook postInstall
    '';

    passthru.system = stdenv.hostPlatform.system;

    meta = {
      description = "Spotify Soloist Connect playback program";
      homepage = "https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates";
      license = lib.licenses.unfree;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["x86_64-linux" "aarch64-linux" "armv7l-linux"];
    };
  }
