# 01 — Glossary

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-23 |

Terms are listed alphabetically. Where an informal word is easy to confuse
with the canonical one, the informal word is marked *avoid*.

In this suite the words **node** and **subscription** mean a proxy node
and a proxy subscription. A different kind keeps its qualifier: a
Tailscale exit node, Prometheus `node-exporter`.

---

**Activation** — The NixOS step that switches a booted system to a system
closure (creating `/etc`, starting units). In Janus, activation happens once
at boot from the read-only store; it never fetches or builds.

**Board** — A supported single-board computer that runs Janus OS (e.g.
Raspberry Pi 4, NanoPi R4S, VisionFive 2). *Avoid:* "device", "the
hardware". Selected via `janus.hardware.board`.

**Board profile** — The Nix module that encodes kernel, firmware, boot
layout, default interface names and quirks for one Board.

**Build host** — The machine on which the flake is evaluated and the image is
built. Usually an x86_64 workstation with unrestricted network access. Never
the Board itself.

**Circumvention** — Collective term for techniques that route traffic through
relay nodes to defeat network censorship. Used in prose; the configuration
namespace is `janus.proxy`.

**Data refresh** — A runtime action that updates mutable data (proxy
subscription node lists, Geo data) without changing the system closure.
Contrast with *Rebuild*.

**Drift** — A hot override whose value differs from the configuration
embedded in the running image. Drift is expected and must be visible.

**Engine** — The proxy core executing tunnels on the Board: `sing-box`
(default) or `xray`. Exactly one engine is active per system.

**Geo data** — Databases mapping IPs to countries (GeoIP) and domains to
categories (GeoSite), used by routing rules and DNS policy. Mutable data,
refreshed at runtime.

**Group** — A named set of proxy nodes used as a routing target. Groups are
formed by a proxy subscription (implicit), by a *matcher* (regex, glob, PEG
over node names) or by a *manual list*. A group has a *selection strategy*
(e.g. manual, url-test, fallback, load-balance).

**Hot override** — A value from a fixed allowlist (proxy subscription URL,
static DHCP lease, Wi-Fi passphrase) changed on the board, stored as
declarative data on the state partition, and applied by a runtime renderer.
It does not change the system closure. *Avoid:* calling this `nixos-rebuild`.

**Image** — The complete, flashable disk image produced by the build: all
partitions, boot firmware, populated file systems. The unit of deployment.

**Janet** — A small Lisp-family scripting language with built-in PEG support.
Janus uses Janet for the PEG matcher and for build-time helper scripts where
a full language is warranted.

**LAN** — A downstream network segment served by the router (DHCP server,
NAT source, firewall zone). Janus supports multiple LANs, each with its own
bridge, subnet and policy.

**Maintenance action** — A runtime operation that does not change
configuration or hot overrides: refresh proxy subscriptions, refresh Geo
data, select a proxy node temporarily, restart a WAN, run a DNS self-test.

**Matcher** — A predicate over a proxy node's name (and optionally other
attributes) that assigns it to a Group. Kinds: `regex`, `glob`, `peg`.

**Mode (traffic mode)** — The master switch for how LAN traffic is handled by
the proxy layer: `bypass` (nothing tunneled), `rule-based` (routing rules
decide), `proxy-all` (everything except explicit exceptions is tunneled).
*Avoid:* "global".

**Peripheral** — A supported add-on device attached to a Board: Wi-Fi
dongle, USB NIC, WWAN (4G/5G) dongle, Bluetooth dongle, HMI (LCD/e-ink with
optional buttons), or a `power` sensor such as an INA219 UPS. *Avoid:*
"add-on", "dangle". Declared under `janus.hardware.peripherals`.

**Policy change** — A change to the router's behavior expressed by editing
`configuration.nix` (e.g. swapping WAN/LAN ports, adding a proxy
subscription). Requires a *Rebuild*.

**Proxy node** — One relay endpoint: protocol, address, credentials, and
transport. Proxy nodes come from a proxy subscription (immutable at
runtime, not user-editable) or from a manual definition in
`configuration.nix`. The option is `janus.proxy.nodes`. *Avoid:* using
"node" for an exit node or for `node-exporter`.

**Proxy subscription** — A URL that yields a list of proxy nodes in a known
format (Clash YAML, a base64 share-link list, sing-box JSON). It has a
name, an update schedule, and yields an implicit Group. The option is
`janus.proxy.subscriptions`. *Avoid:* "relay subscription". The relay is
the proxy node. The subscription is the list.

**Rebuild** — Producing a new system closure or Image from the flake and
deploying it to the Board. Rebuilds happen on the Build host. A rebuild that
would need to compile or download on the Board is an error.

**Routing rule** — An ordered predicate → target mapping (domain set, IP set,
GeoSite/GeoIP category, port, source LAN, protocol → Group, `direct`,
`block`) evaluated by the Engine in `rule-based` mode.

**State partition** — The single read-write f2fs partition, mounted at
`/var`, that holds all persistent mutable data (proxy subscription cache,
Geo data, DHCP leases, persisted journal, flow statistics).

**System closure** — The set of Nix store paths that make up one bootable
system generation. Immutable; identified by hash.

**Uplink** — A physical or logical link that carries traffic to the
Internet: an Ethernet port, a PPPoE session, a WWAN dongle. One WAN
definition binds to one uplink.

**WAN** — An upstream connection definition: uplink, addressing mode
(`static`, `dhcp`, `pppoe`, `wwan`), routing role (`default`, `iptv`,
`backup`). Janus supports multiple WANs simultaneously.

**WWAN** — Wireless wide area network uplink via a 4G/5G Peripheral. A WWAN
peripheral may present itself as an Ethernet NIC (ECM/RNDIS/NCM mode) or as a
QMI/MBIM modem; in both cases it is modeled as a Peripheral of class `wwan`
with an optional AT control channel.

**Zone** — A firewall zone grouping interfaces with identical trust level
(`wan`, `lan`, `guest`, `iot`, `mgmt`). Rules are written between zones.
