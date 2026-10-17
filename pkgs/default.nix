# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  template,
  janusUrl,
  janusRev,
  janusNar,
  janusModified,
  upstreamLock,
}: let
  janus-cli = pkgs.writeShellApplication {
    name = "janus";
    runtimeInputs = with pkgs; [jq iproute2 nftables vnstat coreutils systemd util-linux gnutar];
    text = builtins.readFile ./janus.sh;
  };
  bootInstall = pkgs.writeText "janus-boot-install.sh" (builtins.readFile ./janus-boot-install.sh);
  janus-build = pkgs.writeShellApplication {
    name = "janus-build";
    runtimeInputs = with pkgs; [git age nix coreutils gnugrep gnused findutils gawk jq openssh];
    text =
      ''
        TEMPLATE=${template}
        JANUS_URL=${pkgs.lib.escapeShellArg janusUrl}
        JANUS_REV=${pkgs.lib.escapeShellArg janusRev}
        JANUS_NAR=${pkgs.lib.escapeShellArg janusNar}
        JANUS_MODIFIED=${pkgs.lib.escapeShellArg (toString janusModified)}
        JANUS_UPSTREAM_LOCK=${upstreamLock}
        JANUS_BOOT_INSTALL=${bootInstall}
      ''
      + builtins.readFile ./janus-build.sh;
  };
in {
  inherit janus-build janus-cli bootInstall;
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
