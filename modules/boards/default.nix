# SPDX-License-Identifier: Apache-2.0
# One profile per board. Phase 1 implements the Tier 1 boards in docs/10 §3
# plus the x86_64-test VM profile. Other names stay in the option enum;
# lib.mkRouter refuses them.
{...}: {
  imports = [
    ./firmware.nix
    ./x86_64-test.nix
    ./yanyu-stx-r19f.nix
    ./nanopi-r4s.nix
    ./le-potato.nix
    ./rpi-zero-2w.nix
  ];
}
