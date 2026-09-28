# Janus OS — Software Definition Documents

Janus OS is a NixOS-based, image-deployed router operating system for small
single-board computers. It is configured through a single, router-style
`configuration.nix`, runs from read-only file systems to survive power loss,
and ships first-class support for censorship-circumvention tunnels with
policy-based routing and hardened DNS.

This directory is the definition suite: contributor, design, and
implementation. Source code must follow these documents; when code and
documents disagree, either the code is wrong or a document must be revised
through an ADR.

User-facing text lives in the repository root `README.md` and in
`manual/` (English, Russian, Persian, in that order). `manual/llms.txt`
points at `manual/ai.md`. This directory stays the definition suite.
What the code already contains, and what it does not, is *13*. Router
commands are fixed in *14*. Build-host commands are fixed in *16*.
Choices that are not ADRs are *18*. Explanations are *19*.

## Document map

| # | Document | Purpose | Audience |
|---|----------|---------|----------|
| 00 | [Vision and Scope](00-vision-and-scope.md) | Why the project exists, goals, non-goals, success criteria | Everyone |
| 01 | [Glossary](01-glossary.md) | Canonical terminology used in code, config and docs | Everyone |
| 02 | [Use Cases](02-use-cases.md) | Personas and end-to-end scenarios | Product, developers |
| 03 | [Software Requirements Specification](03-requirements.md) | Numbered functional and non-functional requirements | Developers, testers |
| 04 | [System Architecture](04-architecture.md) | Components, layers, data flow, module structure | Developers |
| 05 | [Storage and File System Design](05-storage-and-filesystems.md) | Partition layout, read-only root, mutable state | Developers |
| 06 | [Networking Design](06-networking.md) | WAN/LAN/VLAN, firewall, NAT, IPv6 | Developers |
| 07 | [Proxy and DNS Design](07-proxy-and-dns.md) | Tunnel engines, nodes, subscriptions, grouping, routing, DNS policy | Developers |
| 08 | [Configuration Reference](08-configuration-reference.md) | The `janus.*` option tree exposed to users | Users, developers |
| 09 | [Build and Deployment](09-build-and-deployment.md) | Flake layout, image build, cross-compilation, deployment workflow | Developers, users |
| 10 | [Hardware Support](10-hardware-support.md) | Supported boards and peripherals, support tiers | Users, developers |
| 11 | [Security Model](11-security.md) | Threat model, access control, privacy controls | Developers, reviewers |
| 12 | [Operations and Maintenance](12-operations.md) | Day-2 tasks: policy changes, data refresh, monitoring, recovery | Users, operators |
| 13 | [Roadmap](13-roadmap.md) | Phased plan, current progress, notes for later work | Everyone |
| 14 | [Router CLI](14-cli.md) | `janus` commands on the board, including the hot-override allowlist | Developers, manual authors |
| 16 | [Build-host CLI](16-build-host-cli.md) | `janus-build`: the router life cycle on the build host | Developers, manual authors |
| 15 | [Panel user interface](15-hmi-ui.md) | One interaction model for small and large panels, and for different keys | Developers |
| 18 | [Decisions](18-decisions.md) | Choices that are not ADRs, decided and undecided | Everyone |
| 19 | [Questions](19-questions.md) | Short answers that point at the binding document | Everyone |
| — | [Architecture Decision Records](adr/README.md) | Individual, dated decisions with rationale | Developers |
| — | [Example configuration](examples/configuration.example.nix) | Complete, commented reference configuration | Users |

## Conventions

* **Requirement language.** The key words MUST, MUST NOT, SHOULD, SHOULD NOT
  and MAY are used as defined in RFC 2119.
* **Requirement identifiers.** Functional requirements are `FR-<area>-<nnn>`,
  non-functional requirements are `NFR-<nnn>`, constraints are `C-<nnn>`.
  Identifiers are never reused after deletion.
* **Status header.** Every document carries a status: `Draft`, `Review`,
  `Approved`, `Superseded`. Only `Approved` documents bind implementation.
* **Option names.** All user-facing NixOS options live under the `janus.`
  namespace and are written in `camelCase`, following NixOS convention.
* **Decisions.** Anything that changes an `Approved` document requires a new
  ADR in `adr/` that references the affected sections. Other choices are
  `D-nnnn` in *18*. The number stays when a row moves from undecided to
  decided, and a deleted number is not reused. An accepted ADR is not
  repeated there. Explanations are `Q-nnnn` in *19*, also never reused.

These documents are the definition of Janus OS. Implementation follows them.
