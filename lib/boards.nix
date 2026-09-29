# SPDX-License-Identifier: Apache-2.0
# Board name → Nix system. The table is docs/09-build-and-deployment.md §4
# and docs/10-hardware-support.md §3. The mapping is fixed. lib.mkRouter
# still throws for a name whose boot path is not implemented.
{
  rpi-zero-2w = "aarch64-linux";
  rpi2 = "armv7l-linux";
  rpi3 = "aarch64-linux";
  rpi4 = "aarch64-linux";
  nanopi-r4s = "aarch64-linux";
  le-potato = "aarch64-linux";
  visionfive2 = "riscv64-linux";
  yanyu-stx-r19f = "x86_64-linux";
  x86_64-test = "x86_64-linux";
}
