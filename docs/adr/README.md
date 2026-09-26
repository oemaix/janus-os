# Architecture Decision Records

One file per decision, numbered, never edited after acceptance except to
change status (`Superseded by ADR-xxxx`). Template: `0000-template.md`.

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-nixos-flakes-base.md) | NixOS stable with flakes as the base system | Accepted |
| [0002](0002-image-based-immutable-deployment.md) | Image-based, immutable deployment; no on-device builds | Accepted |
| [0003](0003-one-partition-per-filesystem-f2fs.md) | One partition per file system, f2fs, read-only root and store | Accepted |
| [0004](0004-networkd-nftables-not-networkmanager.md) | systemd-networkd + nftables instead of NetworkManager | Accepted |
| [0005](0005-janus-option-namespace.md) | Router-style `janus.*` option layer lowering to NixOS | Accepted |
| [0006](0006-engine-abstraction-sing-box-default.md) | Engine-neutral proxy model; sing-box default, Xray optional | Accepted |
| [0007](0007-ssh-key-only-management.md) | SSH public-key-only management, `janus` CLI, no GUI in 1.0 | Accepted |
| [0008](0008-janet-for-matchers-and-tooling.md) | Janet for PEG matchers, node normalization and runtime rendering | Accepted |
| [0014](0014-sops-nix-age.md) | sops-nix with age for credentials | Accepted |
| [0017](0017-hot-overrides-no-onsite-rebuild.md) | Hot overrides; no Nix evaluation on the board | Accepted; refines 0002 |
| [0018](0018-private-config-repo.md) | Private config repo, not a fork per user | Accepted |
| [0019](0019-dns-inside-the-engine.md) | DNS policy inside the proxy engine | Accepted |
| 0009–0013, 0015–0016 | See *13 — Roadmap §3* | Proposed |
