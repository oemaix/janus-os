# Janus OS

The VM image boots. The phase 1 router core is in the tree, and so are
the proxy, DNS policy, fleet commands, closure deploy, the connection
audit log, the maintenance page, A/B image slots, the Waveshare 1.3"
status panel, battery
shutdown for the mcuzone UPS, IPFIX export, a Prometheus endpoint, and
Tier 3 profiles for the Raspberry Pi 2 and the VisionFive 2, and a
Tier 2 profile for the Raspberry Pi 4 and Compute Module 4. What is
specified, and what is done, is
[docs/13-roadmap.md](docs/13-roadmap.md).

Janus OS does not ship a router system. You build your own. A
declarative configuration becomes a read-only NixOS image for a small
board, with censorship circumvention as a first-class feature. The
board does not evaluate Nix. The image is built on another machine.
That machine needs [Nix](https://nixos.org/download/) with flakes
enabled. It does not have to run NixOS. How to build a router is in
the manual below.

This repository is licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE).

## Work on the source

`nix develop` opens the default development shell. Inside it, run programs
directly (`janet`, `janus-build`).

What already exists, and what is still a placeholder, is
[docs/13-roadmap.md](docs/13-roadmap.md). The definition suite in
[docs/](docs/README.md) stays English.

## For users

The manual is [English](manual/en/README.md),
[Russian](manual/ru/README.md), and
[Persian](manual/fa/README.md). It starts with installing Nix, enabling
flakes, and `nix run github:oemaix/janus-os#janus-build -- init <dir>`.
Keep sing-box when LANs need different DNS policies. The full choice is
[docs/07-proxy-and-dns.md](docs/07-proxy-and-dns.md) §2.1.
Router commands are specified in [docs/14-cli.md](docs/14-cli.md).
Build-host commands are specified in
[docs/16-build-host-cli.md](docs/16-build-host-cli.md).
The `janus.*` options are specified in
[docs/08-configuration-reference.md](docs/08-configuration-reference.md).
`janus-build` implements `init`, `host add`, `secret keygen`, `secret set`,
`check`, `build`, `update`, `fleet`, `status`, `backup`, and `deploy`.
`janus` implements the router status, WAN, lease, firewall, age-key,
proxy, DNS, backup, and hot-override commands, `janus audit` when the
audit is in the image, and `janus web` when the maintenance page is in
the image. On the board, `janus deploy` exits 2 and names `janus-build`.
