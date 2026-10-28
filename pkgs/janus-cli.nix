# SPDX-License-Identifier: Apache-2.0
# The janus CLI package. One definition, shared by the flake package
# and by the image. The lists used to be copied and they drifted.
{pkgs}:
pkgs.writeShellApplication {
  name = "janus";
  # Every external command pkgs/janus.sh calls must be here. The CLI
  # runs with this PATH only. A missing command is a runtime 127, and
  # `|| true` would hide it. gawk parses `ip` for `wan show`. findutils
  # wipes /var on `janus reset --state`. gnused and gnugrep are sed and grep.
  runtimeInputs = with pkgs; [
    jq
    iproute2
    nftables
    vnstat
    coreutils
    gnused
    gnugrep
    gawk
    findutils
    systemd
    util-linux
    gnutar
  ];
  text = builtins.readFile ./janus.sh;
}
