# Janus OS

Janus OS does not ship a router system. You build your own, on NixOS:
an image on one computer, flashed to a small board. The board does not
build software and does not evaluate Nix.

The project is public and licensed under the Apache License, Version 2.0.

## What you can do today

The manual and the definition documents are in this repository. The router
image, `janus`, and `janus-build` are not implemented yet. A development
shell exists for people working on the source: from the repository root,
run `nix develop`.

## What the router is specified to do

- Route between WAN and LAN, with a firewall.
- Keep the root filesystem read-only, and keep mutable data on one state
  partition.
- Run a censorship-circumvention tunnel, with sing-box as the default
  engine.
- Be operated over SSH. Day-to-day changes that the specification allows
  are maintenance actions and a short list of hot overrides. Structural
  changes are a new image from the build machine.

The command lists are [docs/14-cli.md](../../docs/14-cli.md) on the router
and [docs/16-build-host-cli.md](../../docs/16-build-host-cli.md) on the
build machine. The `janus.*` options are
[docs/08-configuration-reference.md](../../docs/08-configuration-reference.md).
Hardware and the phased plan are in [docs/](../../docs/README.md).

## Languages

1. English, this file.
2. [Russian](../ru/README.md).
3. [Persian](../fa/README.md).
