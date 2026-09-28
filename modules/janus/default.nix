# SPDX-License-Identifier: Apache-2.0
# Option layer. Each import is a placeholder. See docs/13-roadmap.md.
{ ... }:
{
  imports = [
    ./hardware
    ./storage
    ./network
    ./firewall
    ./proxy
    ./dns
    ./monitoring
    ./remote-access
    ./access
    ./system
  ];
}
