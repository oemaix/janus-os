# SPDX-License-Identifier: Apache-2.0
# CPU speech recognition and synthesis on janus.edge.api. D-0062.
{
  config,
  lib,
  pkgs,
  janusSpeech ? {},
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.janus.edge.speech;
  board = config.janus.hardware.board;
  audio = config.janus.audio;
  voices = janusSpeech.voices or {};
  voiceNames = lib.attrNames voices;
  # g_lang in whisper.cpp v1.9.5. A later tag updates this list with the pin.
  languages = [
    "en" "zh" "de" "es" "ru" "ko" "fr" "ja" "pt" "tr" "pl" "ca" "nl" "ar" "sv" "it" "id" "hi" "fi" "vi"
    "he" "uk" "el" "ms" "cs" "ro" "da" "hu" "ta" "no" "th" "ur" "hr" "bg" "lt" "la" "mi" "ml" "cy" "sk"
    "te" "fa" "lv" "bn" "sr" "az" "sl" "kn" "et" "mk" "br" "eu" "is" "hy" "ne" "mn" "bs" "kk" "sq" "sw"
    "gl" "mr" "pa" "si" "km" "sn" "yo" "so" "af" "oc" "ka" "be" "tg" "sd" "gu" "am" "yi" "lo" "uz" "fo"
    "ht" "ps" "tk" "nn" "mt" "sa" "lb" "my" "bo" "tl" "mg" "as" "tt" "haw" "ln" "ha" "ba" "jw" "su" "yue"
  ];
  asrBoards = ["rockpi-4c" "rpi4" "nanopi-r4s" "yanyu-stx-r19f" "x86_64-test"];
  ttsBoards = asrBoards ++ ["rpi2" "rpi3" "le-potato"];
  voiceForm = id: builtins.match "[a-z][a-z]_[A-Z][A-Z]-[A-Za-z0-9_]+-(x_low|low|medium|high)" id != null;
  on = cfg.asr.enable || cfg.tts.enable;
  local = (cfg.asr.enable && audio.recording.input != null) || (cfg.tts.enable && audio.playback.output != null);
  whisperPkg =
    if janusSpeech ? whisperSrc
    then pkgs.callPackage ../../pkgs/whisper-cpp.nix {src = janusSpeech.whisperSrc;}
    else null;
  piperPkg =
    if janusSpeech ? piperSrc
    then pkgs.callPackage ../../pkgs/piper-tts.nix {src = janusSpeech.piperSrc;}
    else null;
  voiceDir =
    if voiceNames == []
    then null
    else
      pkgs.runCommand "janus-piper-voices" {} (
        ''
          mkdir -p "$out"
        ''
        + lib.concatMapStrings (id: ''
          ln -s ${voices.${id}.model} "$out/${id}.onnx"
          ln -s ${voices.${id}.config} "$out/${id}.onnx.json"
        '')
        voiceNames
      );
  runCmd = pkgs.writeShellApplication {
    name = "janus-speech-run";
    runtimeInputs = with pkgs; [jq sox coreutils util-linux gnused gawk];
    text = builtins.readFile ../../pkgs/janus-speech-run.sh;
  };
  speechCmd = pkgs.writeShellApplication {
    name = "janus-speech";
    runtimeInputs = [pkgs.jq pkgs.coreutils runCmd];
    text = ''
      JANUS_SPEECH_RUN=${runCmd}/bin/janus-speech-run
    '' + builtins.readFile ../../pkgs/janus-speech.sh;
  };
  doc = {
    asr = cfg.asr.enable;
    tts = cfg.tts.enable;
    language = cfg.asr.language;
    voice = cfg.tts.voice;
    whisper =
      if cfg.asr.enable && whisperPkg != null
      then "${whisperPkg}/bin/whisper-cli"
      else null;
    model =
      if cfg.asr.enable
      then janusSpeech.whisperModel or null
      else null;
    piper =
      if cfg.tts.enable && piperPkg != null
      then "${piperPkg}/bin/piper"
      else null;
    voices =
      if cfg.tts.enable
      then voiceDir
      else null;
    recordBin =
      if audio.recording.input != null
      then "${pkgs.pipewire}/bin/pw-record"
      else null;
    playBin =
      if audio.playback.output != null
      then "${pkgs.pipewire}/bin/pw-play"
      else null;
    playback = {
      output = audio.playback.output;
      node = audio.playback.node;
    };
    recording = {
      input = audio.recording.input;
      node = audio.recording.node;
    };
  };
in {
  options.janus.edge.speech = {
    asr.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        whisper.cpp with the locked multilingual base weights.
        True needs janus.edge.api.enable. A board that cannot run it fails evaluation.
      '';
    };
    asr.language = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "zh";
      description = ''
        Decode language of the locked base model.
        Unset detects it. Any other string fails evaluation.
      '';
    };
    tts.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Released Piper. True needs janus.edge.api.enable and tts.voice.
        A board that cannot run it fails evaluation.
      '';
    };
    tts.voice = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "zh_CN-huayan-medium";
      description = ''
        Piper voice id ll_CC-name-quality.
        Required when tts.enable is true. The id is a locked voice, and it is the language.
      '';
    };
  };

  config = mkIf on {
    assertions = [
      {
        assertion = config.janus.edge.api.enable;
        message = ''
          janus.edge.speech.asr.enable and janus.edge.speech.tts.enable need janus.edge.api.enable.
          The listener is off, so evaluation stops. D-0062.
        '';
      }
      {
        assertion = !cfg.asr.enable || lib.elem board asrBoards;
        message = ''
          janus.edge.speech.asr.enable cannot run on ${board}.
          Recognition fails on the Zero 2 W, the Pi 2, the Pi 3, Le Potato, and the VisionFive 2.
        '';
      }
      {
        assertion = !cfg.tts.enable || lib.elem board ttsBoards;
        message = ''
          janus.edge.speech.tts.enable cannot run on ${board}.
          Synthesis fails on the Zero 2 W and the VisionFive 2.
        '';
      }
      {
        assertion = cfg.asr.language == null || lib.elem cfg.asr.language languages;
        message = ''
          janus.edge.speech.asr.language is not a language id of the locked base model.
          Leave it unset to detect the language.
        '';
      }
      {
        assertion = !cfg.tts.enable || (cfg.tts.voice != null && voiceForm cfg.tts.voice && lib.elem cfg.tts.voice voiceNames);
        message = ''
          janus.edge.speech.tts.voice must be a locked Piper id ll_CC-name-quality.
          Locked voices: ${lib.concatStringsSep ", " voiceNames}.
        '';
      }
      {
        assertion = cfg.tts.voice == null || (voiceForm cfg.tts.voice && lib.elem cfg.tts.voice voiceNames);
        message = ''
          janus.edge.speech.tts.voice is not a locked Piper id.
          Locked voices: ${lib.concatStringsSep ", " voiceNames}.
        '';
      }
      {
        assertion = !cfg.asr.enable || (whisperPkg != null && janusSpeech ? whisperModel);
        message = "janus.edge.speech.asr.enable needs the locked whisper.cpp source and the base weights.";
      }
      {
        assertion = !cfg.tts.enable || (piperPkg != null && voiceDir != null);
        message = "janus.edge.speech.tts.enable needs the locked Piper source and the locked voices.";
      }
    ];

    environment.etc."janus/speech.json".text = builtins.toJSON doc;
    environment.etc."janus/bin/janus-speech-run".source = "${runCmd}/bin/janus-speech-run";
    environment.etc."janus/bin/janus-speech".source = "${speechCmd}/bin/janus-speech";

    systemd.services.janus-http.environment = {
      JANUS_SPEECH_JSON = "/etc/janus/speech.json";
      JANUS_SPEECH_RUN = "/etc/janus/bin/janus-speech-run";
    } // lib.optionalAttrs local {
      PIPEWIRE_RUNTIME_DIR = "/run";
    };
    users.users.janus-http.extraGroups = mkIf local ["pipewire"];
    systemd.services.janus-http.after = mkIf local ["pipewire.service" "wireplumber.service"];

    services.pipewire = mkIf local {
      enable = true;
      systemWide = true;
      audio.enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };
  };
}
