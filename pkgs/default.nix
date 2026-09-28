# SPDX-License-Identifier: Apache-2.0
{ pkgs }:
let
  unimplemented = name: doc:
    pkgs.writeShellScriptBin name ''
      echo "${name} is not implemented. See ${doc} and docs/13-roadmap.md." >&2
      exit 2
    '';
  janus-build = unimplemented "janus-build" "docs/16-build-host-cli.md";
  janus-cli = unimplemented "janus" "docs/14-cli.md";
in
{
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
