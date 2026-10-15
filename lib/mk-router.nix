# SPDX-License-Identifier: Apache-2.0
# docs/09-build-and-deployment.md §3. Reads janus.hardware.board from the
# modules, picks the system, and returns a NixOS configuration. The image
# is config.system.build.janusImage. An empty configuration is not returned.
{
  nixpkgs,
  janus,
  sops-nix,
}: {
  modules ? [],
  board ? null,
  source ? null,
  configRevision ? null,
  name ? null,
  # Where the image is built. Pure flake evaluation has no currentSystem,
  # so the default is the x86_64 build host in docs/09 §4. janus-build on
  # another machine evaluates impurely, which supplies currentSystem.
  buildSystem ? builtins.currentSystem or "x86_64-linux",
}: let
  lib = nixpkgs.lib;
  boards = import ./boards.nix;
  # docs/13. A name stays out of this list until its boot path exists.
  implemented = [
    "x86_64-test"
    "yanyu-stx-r19f"
    "nanopi-r4s"
    "le-potato"
    "rpi-zero-2w"
    "rpi3"
    "rpi4"
    "rpi2"
    "visionfive2"
  ];

  peek = lib.evalModules {
    modules =
      [
        janus.nixosModules.janus
        janus.nixosModules.boards
        {
          _module.check = false;
          _module.args.pkgs = {};
        }
      ]
      ++ modules
      ++ lib.optional (board != null) {
        janus.hardware.board = board;
      };
  };

  boardName = peek.config.janus.hardware.board;
  system =
    boards.${boardName} or (throw "janus.hardware.board '${boardName}' is not a known board.");

  nixos = let
    # docs/09 §4. aarch64 and x86_64 stay on the target's own pkgs
    # (emulated or native). armv7l and riscv64 default to cross.
    strategy = peek.config.janus.build.strategy;
    cross = strategy == "cross" && buildSystem != system;
  in
    nixpkgs.lib.nixosSystem (
      {
        specialArgs = {
          janusSource = source;
          janusConfigRevision = configRevision;
          janusRevision = janus.rev or "unknown";
          nixpkgsRevision = nixpkgs.rev or "unknown";
        };
        modules =
          [
            janus.nixosModules.janus
            janus.nixosModules.boards
            sops-nix.nixosModules.sops
          ]
          ++ modules
          ++ lib.optional (board != null) {
            janus.hardware.board = lib.mkForce board;
          }
          ++ lib.optional (name != null) {
            janus.system.hostName = lib.mkDefault name;
            janus.access.deploy.address = lib.mkDefault name;
          }
          ++ lib.optional cross {
            nixpkgs.hostPlatform = system;
            nixpkgs.buildPlatform = buildSystem;
          };
      }
      // lib.optionalAttrs (!cross) {inherit system;}
    );
in
  if !lib.elem boardName implemented
  then
    throw ''
      The board profile '${boardName}' is not implemented.
      Implemented boards are x86_64-test, yanyu-stx-r19f, nanopi-r4s, le-potato, rpi-zero-2w, rpi3, rpi4, rpi2, and visionfive2
      (docs/13-roadmap.md, docs/10-hardware-support.md).
    ''
  else nixos
