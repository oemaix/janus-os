# SPDX-License-Identifier: Apache-2.0
{
  description = "Janus OS, an image-deployed NixOS router";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.sops-nix.url = "github:Mic92/sops-nix/44931708c62937c2b1bf7953902989fa5bb9ee1b";
  inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = {
    self,
    nixpkgs,
    sops-nix,
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
