# Released whisper.cpp. The tag is the flake input. D-0062, T-0020.
{
  stdenv,
  cmake,
  ninja,
  src,
}:
stdenv.mkDerivation {
  pname = "whisper-cpp";
  version = "1.9.5";
  inherit src;

  nativeBuildInputs = [
    cmake
    ninja
  ];

  cmakeFlags = [
    "-DWHISPER_BUILD_TESTS=OFF"
    "-DWHISPER_BUILD_EXAMPLES=ON"
    "-DWHISPER_BUILD_SERVER=OFF"
    "-DWHISPER_SDL2=OFF"
    "-DWHISPER_CURL=OFF"
    "-DGGML_NATIVE=OFF"
    "-DBUILD_SHARED_LIBS=ON"
  ];

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/whisper-cli" --help >/dev/null
  '';

  meta = {
    description = "CPU speech recognition, whisper.cpp 1.9.5";
    mainProgram = "whisper-cli";
  };
}
