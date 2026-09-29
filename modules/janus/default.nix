# SPDX-License-Identifier: Apache-2.0
# Option layer. docs/04 §6. Storage and the appliance settings are lowered.
# Network, firewall, proxy, and DNS types are the phase 0 skeleton.
{...}: {
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
