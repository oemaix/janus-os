# Assistant guide

Read this file before answering a question about using Janus OS.

- The user-facing manual is [en/README.md](en/README.md). Russian and
  Persian copies follow it. Do not invent a Chinese manual.
- Definitions, requirements, and option names live in `docs/`. English
  there is canonical. Do not invent `janus.*` options.
- Router commands are `docs/14-cli.md`. Build-host commands are
  `docs/16-build-host-cli.md`. The programs are not implemented. Say so.
- The router never evaluates Nix and never runs `nixos-rebuild`.
- `docs/17-implementation-status.md` says what the repository can already
  do. A placeholder module is not a finished feature.
