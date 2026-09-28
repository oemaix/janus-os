# 00 — Vision and Scope

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-23 |

## 1. Problem statement

Consumer and hobbyist routers fall into two camps:

* **Vendor firmware** is opaque, rarely updated, and offers no meaningful
  way to run circumvention tunnels or policy routing.
* **OpenWrt and similar** are flexible but are mutable systems: packages are
  installed on the device, configuration lives in many small files, the
  overlay file system shares a partition with the read-only image, and an
  unlucky power cut during a write can corrupt the overlay. Reproducing a
  device from scratch requires a manual procedure rather than a build.

Users in censored networks (mainland China is the primary reference
environment) additionally need a router that:

* tunnels selected traffic through relay nodes using modern protocols
  (VLESS + XTLS-Vision + REALITY, Trojan, Shadowsocks with pluggable
  obfuscation),
* keeps relay-node subscriptions current without exposing the router itself
  to an unreliable or blocked download path,
* resolves names without relying on polluted or logging carrier DNS,
* keeps IPv6 from silently leaking traffic around the tunnel.

## 2. Vision

> A router you *build*, not *install*: one declarative configuration file
> produces a complete, read-only, reproducible image for a small board. The
> device runs it; it never compiles, downloads packages, or evaluates Nix.
> Changing the shape of the system means changing the file and rebuilding.
> A short allowlist of day-to-day values can be changed on the router, and
> each such change is stored as an explicit override record.

Janus OS treats the router like a compiled artifact. The build environment
(with all its network reachability, compilers and caches) stays on the
developer's or user's workstation. The device only carries the results.

## 3. Goals

| ID | Goal | Measure |
|----|------|---------|
| G1 | **Declarative, router-style configuration.** A single `configuration.nix` written in router vocabulary (WAN, LAN, VLAN, firewall zones, nodes, routing rules) — not in Linux-workstation vocabulary. | A user unfamiliar with Nix can produce a working configuration by editing the shipped example only. |
| G2 | **Power-loss resilience.** Root and store file systems are read-only; every file system has its own partition; mutable state is confined to a small, journaled, rw partition. | Repeated hard power cuts under load never leave the device unbootable. |
| G3 | **Immutable, reproducible system.** The device carries no compiler or build tooling; a rebuild that would download or compile fails loudly. | `nix build` of the same flake revision yields an identical system closure. |
| G4 | **First-class circumvention.** Subscriptions, manual nodes, grouping (regex, glob, PEG), policy routing and hardened split DNS are native configuration objects, backed by sing-box or Xray. | All listed protocols are configurable without leaving `configuration.nix`. |
| G5 | **Slim and fast.** Only what a router needs. | Image size and boot time budgets defined in the SRS (NFR). |
| G6 | **Multi-board.** Support for common ARM and RISC-V single-board computers and their USB peripherals (Wi-Fi, NIC, 4G/WWAN, Bluetooth, small HMI), including boards that need redistributable closed firmware. | Each board listed in *10 — Hardware Support* boots and routes from a stock image. |
| G7 | **Maintainable by a person, not only by a rebuild.** Frequent failures and small edits (a dead node, a failed refresh, a new static lease, a rotated subscription URL) are handled on the router. Structural edits still require a rebuild. | Every on-router change is either a maintenance action or a hot override that `janus status` can show. |

## 4. Non-goals (current scope)

* A general web GUI for editing the configuration. 1.0 management is SSH
  and the `janus` CLI. A later page may expose status and the hot-override
  allowlist only; it is not a second configuration system.
* On-device package installation, Nix evaluation, or `nixos-rebuild` on the
  board. Janus OS is not a package-manager host.
* A hosted service that accepts a user's configuration and subscription
  URLs and builds an image for them. A local wizard that writes
  `configuration.nix` on the user's own machine is in scope later.
* Per-user forks of this repository. Users keep a private config repo that
  consumes Janus OS as a flake input.
* Running arbitrary services (NAS, media, containers). Users may add plain
  NixOS options, but Janus does not define or test them.
* Being a general NixOS distribution. Janus is a *profile* of NixOS with a
  strong opinion; it does not attempt to remain compatible with every NixOS
  module.
* Replacing the upstream carrier's modem/ONT. Janus expects an Ethernet (or
  WWAN) uplink.

## 5. Target users

1. **The technical home user in a censored network** who wants a set-and-
   forget router with reliable circumvention, and who will rebuild the image
   from a workstation that has unrestricted access.
2. **The NixOS enthusiast** who wants a router expressed as a flake, with the
   ability to drop to raw NixOS options when Janus vocabulary is not enough.
3. **The small-office operator** behind a carrier NAT who needs remote
   access to the device without control over the upstream router.

## 6. Success criteria for 1.0

* A user copies `docs/examples/configuration.example.nix`, edits WAN mode,
  LAN subnet, SSH key and one subscription URL, runs one `nix build`
  command on an x86_64 workstation and flashes a bootable image for a
  NanoPi R4S or another Tier 1 board.
* The device routes IPv4 and IPv6, applies the firewall, resolves DNS through
  the configured policy, and tunnels traffic according to routing rules.
* Pulling the power 100 times at random moments does not require re-flash.
* The full `janus.*` option tree is documented in *08 — Configuration
  Reference* and rendered from the module definitions.

## 7. Constraints and assumptions

* **C-001** The device MUST NOT contain compilers, build tooling or a
  writable Nix store at runtime.
* **C-002** The build host MAY be in an unrestricted network; the device MAY
  be in a restricted one. All fetching that requires unrestricted access
  happens at build time or through the tunnel at runtime.
* **C-003** Root file system and Nix store are read-only at runtime.
* **C-004** NixOS stable release branch is the base; a specific release is
  pinned per Janus release.
* **C-005** Management access is SSH with public key only, unless the user
  explicitly enables password login in the configuration.

## 8. Naming

* **Janus OS** — the product. The two-faced Roman god of doorways and
  transitions, looking both inward (LAN) and outward (WAN).
* **Board** — a supported single-board computer (see Glossary).
* **Peripheral** — a supported add-on device such as a USB dongle or HAT.

## 9. Project positioning

Janus OS is a public project. The reference environments are censored
networks, with mainland China first and Iran and Russia explicitly welcome.
The repository itself stays free of credentials, subscription URLs, and
vendor tokens.

English is the canonical language of this definition suite. User-facing
text (`README.md` and `manual/`) is English, then Russian, then Persian.
The English text is the one definitions and reviews follow.

Publication hygiene is mirrors of the git repository (so one hosting
account is not a single point of failure). A second GitHub account is not
treated as protection: it does not separate a person from a project once
browser, recovery mail, or commit metadata line up. This suite does not
give legal advice about publishing the project.
