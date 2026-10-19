# SPDX-License-Identifier: Apache-2.0
# The janus CLI package. One definition, shared by the flake package
# (pkgs/default.nix) and by the image (modules/janus/access/default.nix):
# the two used to carry their own runtimeInputs, and they drifted.
{ pkgs }:
pkgs.writeShellApplication {
  name = "janus";
  # Every external command pkgs/janus.sh calls must be here: the CLI
  # runs with this PATH only, so a missing one is a runtime 127 ("awk:
  # command not found"), not a build error. gnused carries sed only.
  # gawk: `wan show` parses `ip` output with awk. findutils: the
  # factory-reset path wipes /var with find, and its `|| true` would
  # hide the missing binary and wipe nothing.
  runtimeInputs = with pkgs; [jq iproute2 nftables vnstat coreutils gnused gawk findutils systemd util-linux gnutar];
  text = builtins.readFile ./janus.sh;
}
