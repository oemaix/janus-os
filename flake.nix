# SPDX-License-Identifier: Apache-2.0
{
  description = "Janus OS, an image-deployed NixOS router";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.janus = ./modules/janus;
      nixosModules.boards = ./modules/boards;
      lib.mkRouter = import ./lib/mk-router.nix;

      templates.default = {
        path = ./templates/default;
        description = "Janus router";
      };

      packages = forAllSystems (pkgs: import ./pkgs { inherit pkgs; });

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
