# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  template,
  janusUrl,
}: let
  janus-cli = pkgs.writeShellApplication {
    name = "janus";
    runtimeInputs = with pkgs; [jq iproute2 nftables vnstat coreutils systemd util-linux];
    text = builtins.readFile ./janus.sh;
  };
  janus-build = pkgs.writeShellApplication {
    name = "janus-build";
    runtimeInputs = with pkgs; [git age nix coreutils gnused findutils];
    text =
      ''
        TEMPLATE=${template}
        JANUS_URL=${pkgs.lib.escapeShellArg janusUrl}
      ''
      + builtins.readFile ./janus-build.sh;
  };
in {
  inherit janus-build janus-cli;
  default = janus-build;
  dev-env = pkgs.buildEnv {
    name = "janus-dev-env";
    paths = with pkgs; [
      zsh
      git
      jq
      janet
      age
      sops
      nil
      alejandra
      janus-build
      janus-cli
    ];
  };
}
