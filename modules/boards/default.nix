# SPDX-License-Identifier: Apache-2.0
# One profile per board. Phase 0 implements x86_64-test.
# Other names are in the option enum; mkRouter refuses them.
{...}: {
  imports = [./x86_64-test.nix];
}
