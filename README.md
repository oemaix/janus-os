# Janus OS

**This project is in its infancy. It will not work.** There is no bootable
router image, and the commands do not do their jobs yet. What is here is
the specification and a skeleton of the repository.

Janus OS is an image-deployed NixOS router for small boards, with
censorship-circumvention as a first-class feature. The router does not
evaluate Nix. Images are built on another machine.

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
Neither program is implemented yet. `janus-build` and `janus`, when run
from the development shell, exit 2 and say so.
