# SPDX-License-Identifier: Apache-2.0
{
  description = "Janus OS, an image-deployed NixOS router";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.sops-nix.url = "github:Mic92/sops-nix/5efb5a6f4f5ab192817d28557dd4d650fa14d866";
  inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  # The rule-set branch is the ref `nix flake update` follows. flake.lock
  # records the commit and the narHash. A per-file hash of that branch
  # goes stale when the branch is regenerated. docs/07 §8, docs/09 §5.
  inputs.sing-geosite.url = "github:SagerNet/sing-geosite/rule-set";
  inputs.sing-geosite.flake = false;
  inputs.sing-geoip.url = "github:SagerNet/sing-geoip/rule-set";
  inputs.sing-geoip.flake = false;
  inputs.iran-sing-box-rules.url = "github:Chocolate4U/Iran-sing-box-rules/rule-set";
  inputs.iran-sing-box-rules.flake = false;
  # Spotify publishes these three Linux builds and replaces each URL in
  # place. flake.lock records the narHash. `nix flake update` moves it.
  # docs/08 §1a, T-0010.
  inputs.soloist-x86_64.url = "https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz";
  inputs.soloist-x86_64.flake = false;
  inputs.soloist-aarch64.url = "https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz";
  inputs.soloist-aarch64.flake = false;
  inputs.soloist-armv7l.url = "https://soloist-builds.spotifycdn.com/soloist_release_arm32.tar.gz";
  inputs.soloist-armv7l.flake = false;
  # Released speech programs and weights. A new program release is a tag
  # change here, then `nix flake update`. ggml-base.bin comes from
  # ggerganov/whisper.cpp. Each voice is the published Piper id on
  # rhasspy/piper-voices. flake.lock holds the narHash. T-0020, D-0062.
  inputs.whisper-cpp.url = "github:ggml-org/whisper.cpp/v1.9.5";
  inputs.whisper-cpp.flake = false;
  inputs.whisper-base.url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
  inputs.whisper-base.flake = false;
  inputs.piper.url = "github:OHF-Voice/piper1-gpl/v1.8.0";
  inputs.piper.flake = false;
  inputs.piper-en-us-lessac-medium.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx";
  inputs.piper-en-us-lessac-medium.flake = false;
  inputs.piper-en-us-lessac-medium-json.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json";
  inputs.piper-en-us-lessac-medium-json.flake = false;
  inputs.piper-ru-ru-irina-medium.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx";
  inputs.piper-ru-ru-irina-medium.flake = false;
  inputs.piper-ru-ru-irina-medium-json.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx.json";
  inputs.piper-ru-ru-irina-medium-json.flake = false;
  inputs.piper-fa-ir-amir-medium.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fa/fa_IR/amir/medium/fa_IR-amir-medium.onnx";
  inputs.piper-fa-ir-amir-medium.flake = false;
  inputs.piper-fa-ir-amir-medium-json.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fa/fa_IR/amir/medium/fa_IR-amir-medium.onnx.json";
  inputs.piper-fa-ir-amir-medium-json.flake = false;
  inputs.piper-zh-cn-huayan-medium.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx";
  inputs.piper-zh-cn-huayan-medium.flake = false;
  inputs.piper-zh-cn-huayan-medium-json.url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/zh_CN-huayan-medium.onnx.json";
  inputs.piper-zh-cn-huayan-medium-json.flake = false;

  outputs = {
    self,
    nixpkgs,
    sops-nix,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    train = let
      # nixpkgs 5e2305d (nixos-26.05) has no lib.stringTrim.
      # trimWith keeps each end unless that side is set.
      raw = nixpkgs.lib.trimWith {
        start = true;
        end = true;
      } (builtins.readFile ./train);
      ok = raw == "main" || builtins.match "(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)" raw != null;
    in
      if ok
      then raw
      else throw "The train file must contain main or MAJOR.MINOR, not '${raw}'.";
    pinned = self ? rev && self.rev != null;
  in {
    nixosModules.janus = ./modules/janus;
    nixosModules.boards = ./modules/boards;
    lib.mkRouter = import ./lib/mk-router.nix {
      inherit nixpkgs sops-nix;
      janus = self;
    };

    templates.default = {
      path = ./templates/default;
      description = "Janus router";
    };

    packages = forAllSystems (pkgs:
      import ./pkgs {
        inherit pkgs;
        template = ./templates/default;
        upstreamLock = ./flake.lock;
        janusUrl =
          if pinned
          then "github:oemaix/janus-os/${train}"
          else "path:${self.outPath}";
        janusRev =
          if pinned
          then self.rev
          else "";
        janusNar = self.sourceInfo.narHash or "";
        janusModified = self.sourceInfo.lastModified or 0;
      }
      // {
        docs-options = let
          nixos = self.lib.mkRouter {
            source = self;
            configRevision = self.rev or "unknown";
            name = "docs";
            modules = [
              {
                janus.hardware.board = "x86_64-test";
                janus.access.ssh.authorizedKeys = [
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForJanusEval janus-docs"
                ];
              }
            ];
          };
          doc = pkgs.nixosOptionsDoc {
            options = nixos.options;
            transformOptions = opt:
              opt
              // {
                visible = opt.visible && nixpkgs.lib.hasPrefix "janus." opt.name;
              };
          };
        in
          pkgs.runCommand "janus-options-doc" {} ''
            mkdir -p "$out"
            cp ${doc.optionsCommonMark} "$out/options.md"
          '';
      });

    checks = forAllSystems (pkgs:
      import ./tests/eval.nix {
        inherit pkgs self;
        inherit (nixpkgs) lib;
      }
      // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        vm-x86_64-test = import ./tests/vm-boot.nix {inherit pkgs self;};
        vm-x86_64-debug = import ./tests/vm-debug.nix {inherit pkgs self;};
        vm-x86_64-slots = import ./tests/vm-slots.nix {inherit pkgs self;};
        vm-x86_64-net = import ./tests/vm-net.nix {inherit pkgs nixpkgs self;};
        limine-bios = import ./tests/limine-bios.nix {inherit pkgs;};
        eval-kernel-config = import ./tests/kernel-config.nix {inherit pkgs self;};
      });

    formatter = forAllSystems (pkgs: pkgs.alejandra);

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          self.packages.${pkgs.stdenv.hostPlatform.system}.dev-env
        ];
        shellHook = ''
          export JANUS_DEV_SHELL=1
        '';
      };
    });
  };
}
