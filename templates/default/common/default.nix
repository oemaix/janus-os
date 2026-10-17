# Shared by every host in this repo. A proxy subscription used by two
# routers is declared here. Per-router values stay in
# hosts/<name>/configuration.nix. subscriptions.<name>.enable = false
# on one host drops that subscription there and keeps the secret name.
{ ... }:
{
}
