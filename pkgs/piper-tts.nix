# Released Piper from piper1-gpl. The tag is the flake input. D-0062.
{
  lib,
  piper-tts,
  src,
}:
(piper-tts.override {
  withTrain = false;
  withHTTP = false;
  withAlignment = false;
}).overrideAttrs (old: {
  version = "1.8.0";
  inherit src;
  patches = [];
  postPatch = ''
    mkdir -p src/piper/espeak-ng-data
    cp ${./piper-CMakeLists.txt} CMakeLists.txt
  '';
  # scikit-build installs espeakbridge at the package root. DESTINATION .
  # is that root. The CLI is the Python entry point, not a CMake target.
  doInstallCheck = true;
  installCheckPhase = ''
    test -x "$out/bin/piper"
    "$out/bin/piper" --help >/dev/null
    find "$out" -name 'espeakbridge*.so' | grep -q .
  '';
  meta = old.meta // {
    changelog = "https://github.com/OHF-Voice/piper1-gpl/releases/tag/v1.8.0";
  };
})
