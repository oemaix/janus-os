# Contributing

Janus OS is a public repository. A household configuration stays in a
private config repo that pins this flake (ADR-0018). A change to the
operating system belongs here.

## Issues

| Form | Use it for |
|------|------------|
| Bug | A supported command, option, or image does something the manual or `docs/` does not describe. |
| Hardware | A board or peripheral in [docs/10-hardware-support.md](docs/10-hardware-support.md) fails, or a measurement of hardware that page does not list. |
| Documentation | [README.md](README.md), [manual/](manual/en/README.md), or a definition document is wrong or incomplete. |
| Definition change | What Janus does should change: an option, a command, a board profile, or an open row in [docs/18-decisions.md](docs/18-decisions.md). |
| Question | How to build, flash, or operate a router. The [manual](manual/en/README.md) answers most of these. |

Title an issue as the failure or the change. A prefix such as `[Bug]` adds nothing.

A vulnerability is reported as [SECURITY.md](SECURITY.md) describes.

Issues and pull requests stay free of credentials, subscription URLs, age keys, and node lists that name a relay. The repository stays free of those ([docs/00-vision-and-scope.md](docs/00-vision-and-scope.md) §9).

## Definitions

`docs/` is the definition suite. It stays English. When code and an Approved definition disagree, change the code or add an ADR in `docs/adr/`. A draft document still wins over an unstated guess. The ADR template is [docs/adr/0000-template.md](docs/adr/0000-template.md).

Choices that are not ADRs are `D-nnnn` in [docs/18-decisions.md](docs/18-decisions.md). Explanations are `Q-nnnn` in [docs/19-questions.md](docs/19-questions.md). The number stays when a row moves from undecided to decided. A deleted number is not reused. An accepted ADR is not copied into the decision list.

Implementation progress is [docs/13-roadmap.md](docs/13-roadmap.md). A stub is not a finished feature.

A new `janus.*` option is named in [docs/08-configuration-reference.md](docs/08-configuration-reference.md) before the module grows it. An open row in *18* stays open until a decision records the answer.

## User-facing text

`README.md` and `manual/` are English, then Russian, then Persian. English changes first. Russian and Persian follow that text. `manual/llms.txt` points at `manual/ai.md`. Update that file when a manual fact changes.

Maintenance-page strings add Simplified Chinese. That set is [docs/20-maintenance-ui.md](docs/20-maintenance-ui.md).

## Working on the source

`nix develop` opens the development shell. Inside it, run programs directly:

```text
janet -v
janus-build
```

CI runs the evaluation checks in [.github/workflows/eval.yml](.github/workflows/eval.yml). The VM checks build an image. What each check covers is [tests/README.md](tests/README.md). One check is:

```text
nix build .#checks.x86_64-linux.eval-router
```

`nix fmt` runs Alejandra on the Nix files.

## Pull requests

Say which document, requirement, ADR, or `D-nnnn` the change follows. A behavior change updates that document in the same pull request.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE). Contributions are under that license.
