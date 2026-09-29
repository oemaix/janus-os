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
}: let
  lib = nixpkgs.lib;
  boards = import ./boards.nix;
  # docs/13 phase 1. Later tiers stay a throw until their boot path exists.
  implemented = [
    "x86_64-test"
    "yanyu-stx-r19f"
    "nanopi-r4s"
    "le-potato"
    "rpi-zero-2w"
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

  nixos = nixpkgs.lib.nixosSystem {
    inherit system;
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
      };
  };
in
  if !lib.elem boardName implemented
  then
    throw ''
      The board profile '${boardName}' is not implemented.
      Phase 1 ships x86_64-test, yanyu-stx-r19f, nanopi-r4s, le-potato, and rpi-zero-2w
      (docs/13-roadmap.md, docs/10-hardware-support.md).
    ''
  else nixos
