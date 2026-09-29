# SPDX-License-Identifier: Apache-2.0
# Fleet repo. janus-build init copies this tree and adds no router.
# Each directory under hosts/ is one nixosConfigurations attribute.
# lib.mkRouter throws until the image path exists.
# `nix develop` here is the operator shell: janus-build only.
{
  inputs.janus.url = "github:oemaix/janus-os";
  inputs.nixpkgs.follows = "janus/nixpkgs";

  outputs =
    { janus, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      hostDir = ./hosts;
      hostNames = builtins.filter (
        name:
        builtins.substring 0 1 name != "."
        && (builtins.readDir hostDir).${name} == "directory"
      ) (builtins.attrNames (builtins.readDir hostDir));
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = janus.lib.mkRouter {
            modules = [
              ./common/default.nix
              (hostDir + "/${name}/configuration.nix")
              (hostDir + "/${name}/overrides.nix")
            ];
          };
        }) hostNames
      );

      packages = each (system: {
        janus-build = janus.packages.${system}.janus-build;
        default = janus.packages.${system}.janus-build;
      });

      devShells = each (system: {
        default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
          packages = [ janus.packages.${system}.janus-build ];
        };
      });
    };
}
