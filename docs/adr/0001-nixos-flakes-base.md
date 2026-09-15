# ADR-0001 — NixOS stable with flakes as the base system

| Field | Value |
|-------|-------|
| Status | Accepted |
| Date | 2026-09-15 |
| Affects | 00 §7, 04 §8, 09 §2 |

## Context

The project wants a router whose entire state is derived from one
declarative description, that can be rebuilt bit-for-bit, and whose build
happens away from the device. It also wants to reuse a large, maintained
package set (kernels, sing-box, Xray, hostapd, pppd) without maintaining a
custom build system like OpenWrt's buildroot.

## Decision

Janus OS is a NixOS configuration profile. The base is a pinned NixOS
*stable* release branch (not unstable) consumed through a Nix flake. Janus
is distributed as a flake providing `nixosModules`, a `mkRouter` library
function and a user template. Each Janus release pins exactly one nixpkgs
commit.

## Consequences

* Reproducible images and easy diffing of system closures.
* Access to nixpkgs' packages and the NixOS module system for types,
  defaults and assertions.
* Stable branch limits feature velocity of engines; Janus carries an overlay
  to pin newer sing-box/Xray when needed.
* NixOS assumptions (writable `/etc`, `nix` daemon, `switch-to-
  configuration`) must be neutralised explicitly (ADR-0002, ADR-0003).
* Users must run Nix on a build host; this is accepted as the price of
  reproducibility.

## Alternatives considered

* **OpenWrt** — mature, but mutable overlay design and imperative package
  management contradict the immutability goal.
* **Buildroot / Yocto** — full control, but a custom module system and
  package maintenance burden; no declarative user configuration story.
* **NixOS unstable** — newer packages, but breaking changes would land in a
  device the user cannot fix in place.
