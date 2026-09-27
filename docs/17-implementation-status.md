# 17 — Implementation status

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

This file is the progress note for the code. The definition suite still
describes the system to build. A file existing here does not mean that
behavior exists.

## Done

* Apache-2.0 license at the repository root.
* Flake with `nixosModules.janus`, `nixosModules.boards`, `lib.mkRouter`,
  `templates.default`, and `devShells.default` (`nix develop`).
* Placeholder NixOS modules for the areas in *04* §6. They import and
  define no options.
* `janus-build` and `janus` binaries in the dev shell. Both exit 2.
* User-facing text: root `README.md` and `manual/` in English, Russian,
  and Persian, in that order, plus `manual/llms.txt` and `manual/ai.md`.
* Human terminal: `.vscode/settings.json` launches `scripts/dev-zsh`,
  which is zsh inside `nix develop`.

## Not done

* Every `janus.*` option in *08*, and every lowering into NixOS.
* `lib.mkRouter`. Calling it throws. It must not grow a silent empty
  configuration.
* Image build, partition layout, and board profiles, including
  `x86_64-test`.
* `janus` and `janus-build` behavior from *14* and *16*. The binaries are
  stubs.
* Subscription snapshot, Geo data, Janet normalizer, matchers, and both
  engine renderers. `janet/` only holds a note. Do not start this in Go.
* Checks, golden files, and VM tests.
* sops-nix wiring, age-key install, hot-override storage, and fleet push.
* HMI, battery shutdown, WWAN, and Wi-Fi AP.
* The local wizard. `janus-build init` is specified and not implemented.
* Cursor hooks and project rules. Left out on purpose for now. `.cursor/`
  stays gitignored.

## Worth keeping in mind

* Open choices in *13* §3 stay open in code. In particular, do not pick a
  DHCP server (ADR-0009), an image tool (ADR-0010), or TUN versus TPROXY
  (ADR-0011) while those rows are undecided.
* Do not assign a WAN port on the Yanyu STX-R19F until U1 is measured.
* Do not arm battery shutdown until U4 records the current sign.
* The board image must not contain a compiler, a Nix evaluator, or
  `janus-build`. The dev shell is only for the build host.
* No MCP server is included. One would only repeat `janus-build` before
  that program exists, and a stub that returned invented data would be
  worse than no server.
* Chinese user-facing text was considered and left out. The order is
  English, Russian, Persian.
