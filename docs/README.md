# Janus OS — Software Definition Documents

Janus OS is a NixOS-based, image-deployed router operating system for small
single-board computers. It is configured through a single, router-style
`configuration.nix`, runs from read-only file systems to survive power loss,
and ships first-class support for censorship-circumvention tunnels with
policy-based routing and hardened DNS.

This directory is the authoritative definition of *what* Janus OS is and *how*
it is built. Source code must follow these documents; when code and documents
disagree, either the code is wrong or a document must be revised through an
ADR.

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
| 13 | [Roadmap and Open Questions](13-roadmap-and-open-questions.md) | Phased delivery plan and unresolved decisions | Everyone |
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
  ADR in `adr/` that references the affected sections.

## Source of truth

The requirement note that seeded this suite is kept for provenance at
`tmp/requirement notes/`. It is *not* normative; the documents in this
directory are.
