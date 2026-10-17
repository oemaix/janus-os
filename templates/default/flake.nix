# SPDX-License-Identifier: Apache-2.0
# Fleet repo. janus-build init copies this tree and adds no router.
# Each directory under hosts/ is one nixosConfigurations attribute.
# lib.mkRouter reads janus.hardware.board and builds the image.
# `nix develop` here is the operator shell: janus-build only.
{
  # janus-build init sets this to the train branch and writes flake.lock.
  inputs.janus.url = "github:oemaix/janus-os";
  inputs.nixpkgs.follows = "janus/nixpkgs";

  outputs = {
    self,
    janus,
    nixpkgs,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    each = nixpkgs.lib.genAttrs systems;
    hostDir = ./hosts;
    hostNames = builtins.filter (
      name:
        builtins.substring 0 1 name
        != "."
        && (builtins.readDir hostDir).${name} == "directory"
    ) (builtins.attrNames (builtins.readDir hostDir));
  in {
    nixosConfigurations = builtins.listToAttrs (
      map (name: {
        inherit name;
        value = janus.lib.mkRouter {
          source = self;
          configRevision = self.rev or "unknown";
          name = name;
          # Tier 3 boards are cross-compiled. Pure evaluation has no
          # current system, so this is the usual x86_64 build host.
          # janus-build on another machine evaluates impurely, and this
          # expression then becomes that machine.
          buildSystem = builtins.currentSystem or "x86_64-linux";
          modules = [
            ./common/default.nix
            (hostDir + "/${name}/configuration.nix")
            (hostDir + "/${name}/overrides.nix")
          ];
        };
      })
      hostNames
    );

    packages = each (system: {
      janus-build = janus.packages.${system}.janus-build;
      default = janus.packages.${system}.janus-build;
    });

    devShells = each (system: {
      default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
        packages = [janus.packages.${system}.janus-build];
      };
    });
  };
}
