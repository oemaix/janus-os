# Janus OS

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

Chinese is not in that set yet. The definition suite in [docs/](docs/README.md)
stays English.

## Work on the source

`nix develop` opens the default development shell. In Cursor or VS Code the
integrated terminal is that shell, running zsh. Inside it, run programs
directly (`janet`, `janus-build`). The shell is not entered by wrapping
each command.

What already exists, and what is still a placeholder, is
[docs/17-implementation-status.md](docs/17-implementation-status.md).

## For operators

The user manual is [manual/](manual/README.md). Commands the router will
have are specified in [docs/14-cli.md](docs/14-cli.md). Commands the build
machine will have are specified in [docs/16-build-host-cli.md](docs/16-build-host-cli.md).
Neither program is implemented yet. `janus-build` and `janus`, when run
from the development shell, exit 2 and say so.
