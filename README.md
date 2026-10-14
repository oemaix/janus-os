# Janus OS

**This project is in its infancy.** The VM image boots. The phase 1
router core is in the tree, and so are the proxy, DNS policy, fleet
commands, closure deploy, the connection audit log, and A/B image slots.
What is specified, and what is done, is
[docs/13-roadmap.md](docs/13-roadmap.md).

Janus OS does not ship a router system. You build your own. A
declarative configuration becomes a read-only NixOS image for a small
board, with censorship circumvention as a first-class feature. The
board does not evaluate Nix. The image is built on another machine.

This repository is licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE).

## Languages

User-facing text is written in this order:

1. [English](manual/en/README.md)
2. [Russian](manual/ru/README.md)
3. [Persian](manual/fa/README.md)

The definition suite in [docs/](docs/README.md) stays English.

## Work on the source

`nix develop` opens the default development shell. Inside it, run programs
directly (`janet`, `janus-build`).

What already exists, and what is still a placeholder, is
[docs/13-roadmap.md](docs/13-roadmap.md).

## For operators

The user manual is [manual/](manual/README.md). Commands the router will
have are specified in [docs/14-cli.md](docs/14-cli.md). Commands the build
machine will have are specified in [docs/16-build-host-cli.md](docs/16-build-host-cli.md).
The `janus.*` options are specified in
[docs/08-configuration-reference.md](docs/08-configuration-reference.md).
`janus-build` implements `init`, `host add`, `secret`, `check`, `build`,
`update`, `fleet`, `status`, `backup`, and `deploy`. `janus` implements
the router status, WAN, lease, firewall, age-key, proxy, DNS, backup,
and hot-override commands. On the board, `janus deploy` exits 2 and
names `janus-build`.
