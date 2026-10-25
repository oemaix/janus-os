# SPDX-License-Identifier: Apache-2.0
# One profile per implemented board. docs/10 §3. lib.mkRouter refuses the rest.
{lib, ...}: {
  imports = [
    ./firmware.nix
    ./x86_64-test.nix
    ./yanyu-stx-r19f.nix
    ./nanopi-r4s.nix
    ./rockpi-4c.nix
    ./le-potato.nix
    ./rpi-zero-2w.nix
    ./rpi3.nix
    ./rpi4.nix
    ./rpi2.nix
    ./visionfive2.nix
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
