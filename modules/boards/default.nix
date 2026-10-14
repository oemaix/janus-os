# SPDX-License-Identifier: Apache-2.0
# One profile per board. Phase 1 implements the Tier 1 boards in docs/10 §3
# plus the x86_64-test VM profile. Other names stay in the option enum;
# lib.mkRouter refuses them.
{lib, ...}: {
  imports = [
    ./firmware.nix
    ./x86_64-test.nix
    ./yanyu-stx-r19f.nix
    ./nanopi-r4s.nix
    ./le-potato.nix
    ./rpi-zero-2w.nix
    ./rpi3.nix
  ];

  options.janus.board.configTxt = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "Extra lines for the Raspberry Pi config.txt.";
  };

  options.janus.board.bootScript = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "Shell inserted into the Raspberry Pi boot-file script.";
  };
}
