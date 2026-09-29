# SPDX-License-Identifier: Apache-2.0
{
  description = "Janus OS, an image-deployed NixOS router";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    nixosModules.janus = ./modules/janus;
    nixosModules.boards = ./modules/boards;
    lib.mkRouter = import ./lib/mk-router.nix {
      inherit nixpkgs;
      janus = self;
    };

    templates.default = {
      path = ./templates/default;
      description = "Janus router";
    };

    packages = forAllSystems (pkgs:
      import ./pkgs {inherit pkgs;}
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
