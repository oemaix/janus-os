# SPDX-License-Identifier: Apache-2.0
# User template shape from docs/09-build-and-deployment.md.
# lib.mkRouter throws until the image path exists.
{
  inputs.janus.url = "github:oemaix/janus-os";

  outputs = { janus, ... }: {
    nixosConfigurations.router = janus.lib.mkRouter {
      modules = [ ./configuration.nix ];
    };
  };
}
