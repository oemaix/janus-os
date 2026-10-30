# Janus OS

Janus OS turns one declarative configuration into a read-only NixOS
image for a small board. Censorship circumvention is a first-class
feature. You build the image on another machine. That machine needs
[Nix](https://nixos.org/download/) with flakes enabled. It does not
have to run NixOS. The board runs the image. It does not evaluate Nix.

## Build a router

The manual is [English](manual/en/README.md),
[Russian](manual/ru/README.md), and
[Persian](manual/fa/README.md). It starts with installing Nix, enabling
flakes, and:

    nix run github:oemaix/janus-os#janus-build -- init <dir>

## Work on the source

How to report a defect or send a change is
[CONTRIBUTING.md](CONTRIBUTING.md). How to report a vulnerability is
[SECURITY.md](SECURITY.md).

`nix develop` opens the development shell. Inside it, run programs
directly (`janet`, `janus-build`).

A Dev Container is optional. On a NixOS host or any other host that
already has Nix, it uses that store and the same shell. On a host with
no Nix, the Other profile installs a private Nix inside the container.
Without Docker, the command above is unchanged. Opening the container
asks for janus-os (NixOS host), janus-os (Nix host), or janus-os (Other host).

What is specified, and what is done, is
[docs/13-roadmap.md](docs/13-roadmap.md). The definition suite in
[docs/](docs/README.md) stays English.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).
