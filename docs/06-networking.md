# 06 — Networking Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-26 |

## 1. Substrate

Janus lowers its router vocabulary into **systemd-networkd** (links, netdevs,
networks), **pppd** (PPPoE), **nftables** (firewall/NAT/interception) and a
DHCP/RA server. NetworkManager is not used: it targets interactive hosts,
carries D-Bus/policy machinery a headless router does not need, and its
NixOS options are host-oriented rather than router-oriented (ADR-0004).

Users who need something Janus does not express can set raw
`systemd.network.*` or `networking.nftables.*` options; Janus merges rather
than replaces, and asserts on known conflicts (FR-CFG-007).

## 2. Ports and interface naming

Board profiles declare physical Ethernet ports with stable kernel names
(via `.link` files matching by path/MAC) and human labels:

```
janus.network.ports = {
  wan  = { device = "eth0"; };        # board default; user can remap
  lan1 = { device = "eth1"; };
  usb0 = { device = "enp1s0u1"; match.usbVendorProduct = "0bda:8153"; };
};
```

All other objects refer to ports by name (`wan`, `lan1`). Swapping WAN and
LAN is editing two strings (FR-CFG-005). Peripherals of class `nic` and
`wwan` register additional ports.

## 3. VLANs

`janus.network.vlans.<name> = { port = "lan1"; id = 100; }` creates a
`vlan` netdev `lan1.100`. VLANs are referenced like ports anywhere a link is
expected (WAN uplink, LAN member). The model is general: Janus does not
special-case an IPTV VLAN.

1.0 implements this on LAN ports. Attaching a VLAN to a WAN, the `iptv`
role, and IGMP proxy stay in this document and are not part of the 1.0
implementation (FR-NET-005, FR-NET-020).

## 4. WAN

```
janus.network.wans.<name> = {
  uplink   = "wan" | "wan.35" | "wwan0";        # port, vlan or wwan peripheral
  mode     = "dhcp" | "static" | "pppoe" | "wwan";
  role     = "default" | "iptv" | "backup" | "custom";
  metric   = 100;
  dhcp     = { vendorClass, clientId, requestOptions, hostname, sendRelease };
  static   = { address, prefixLength, gateway, dns };
  pppoe    = { username, passwordFile|password, serviceName, mtu, mru,
               lcpEchoInterval, lcpEchoFailure, ipv6 };
  wwan     = { peripheral, apn, pin, auth };
  ipv6     = { mode = "disabled"|"slaac"|"dhcpv6-pd"|"static"|"passthrough";
               prefixDelegationHint; };
  healthCheck = { enable; targets; interval; failures; };
  macAddress = null;                              # clone for carrier lock
};
```

Semantics:

* **`default`** WAN installs the default route (metric ordering when several
  `default`s exist). **`backup`** installs a higher-metric default route and
  becomes active when health checks of all lower-metric defaults fail.
  **`iptv`** installs *no* default route; it exists to receive multicast and
  the carrier's IPTV subnet; `janus.network.igmpProxy` binds it to LANs.
  **`custom`** installs only what `routes` says (policy routing table per
  WAN for advanced users).
* Every WAN gets its own routing table (`table = 100 + n`) with a rule
  `from <wan-address> lookup <table>` so replies leave the way they came.
* PPPoE runs as `pppd` in a hardened systemd unit; interface name is
  `ppp-<name>`. IPv6CP + DHCPv6-PD on the ppp interface is the `passthrough`
  IPv6 mode.
* WAN DNS servers learned via DHCP/PPPoE are recorded to
  `/run/janus/wan/<name>/dns` for the DNS policy layer but are **not**
  installed into `resolv.conf` (FR-DNS-002).

## 5. LAN

```
janus.network.lans.<name> = {
  members  = [ "lan1" "lan2" "lan1.20" "wifi0" ];  # ports, vlans, wifi APs
  address  = "192.168.10.1"; prefixLength = 24;
  domain   = "lan";
  dhcp     = { enable = true; rangeStart; rangeEnd; leaseTime;
               options = { dns = "router"|[..]; gateway = "router"; ntp; };
               staticLeases = { "<hostname>" = { mac; ip; }; }; };
  ipv6     = { mode = "disabled"|"ula-only"|"delegated";
               ula = "fd00:..."|"auto"; ra = { managed; other; rdnss = "router"; };
               dhcpv6 = { enable; }; subnetId = 1; };
  zone     = "lan";              # firewall zone (default = lan name)
  proxied  = true;               # subject to traffic mode (default true)
  nat      = { enable = true; hairpin = true; };
  isolation = false;             # bridge port isolation for guest LANs
};
```

Each LAN is a Linux bridge `br-<name>`. Bridging a Wi-Fi AP means the
`hostapd` interface is a bridge member. Static leases feed both DHCP and
local DNS (FR-NET-012).

## 6. DHCP server and RA

dnsmasq serves DHCP only (ADR-0009). It is not a DNS policy engine.
Per-LAN scopes, static leases, custom options, and a lease file on `/var`
are its job. Lease hostnames are exported for DNS. RA is provided by
networkd (`IPv6SendRA=`) with the prefix from PD or ULA.

## 7. NAT and port forwarding

* Masquerade: for every `(lan, wan)` pair where `lan.nat.enable` and wan is
  `default|backup|custom`, `oifname <wan> ip saddr <lan-subnet> masquerade`.
  IPTV WANs masquerade only if `iptv.nat = true`.
* Port forwards:

```
janus.firewall.portForwards.<name> = {
  wan = "main"|null(all default WANs); protocol = "tcp"|"udp"|"tcp+udp";
  externalPort = 443 | "60000-61000"; to = { host = "192.168.10.20"; port = 8443; };
  sourceAllow = [ "203.0.113.0/24" ]; hairpin = true;
};
```

generates DNAT in `prerouting`, the accept rule in `forward`, and, if
`hairpin`, the SNAT for LAN-origin hits.

## 8. Firewall (zone model)

```
janus.firewall = {
  zones = { wan = { interfaces = auto(all WANs); input = "drop"; forward = "drop"; };
            lan = { interfaces = auto(LANs with zone=lan); input = "accept"; forward = "accept"; };
            guest = { ... input = "drop" (except dhcp/dns); forward = "drop"; };
            mgmt = { interfaces = [ "tailscale0" ]; input = "ssh"; }; };
  policies = [ { from = "lan";   to = "wan"; action = "accept"; }
               { from = "guest"; to = "wan"; action = "accept"; }
               { from = "guest"; to = "lan"; action = "drop"; } ];
  rules = [ { name = "allow-iot-mqtt"; from = "iot"; to = "lan";
              protocol = "tcp"; dport = 1883; dest = "192.168.10.5"; action = "accept"; } ];
  services = { ssh = { zones = [ "lan" "mgmt" ]; port = 22; };
               dns = { zones = [ "lan" "guest" ]; }; dhcp = {...}; icmp = { zones = ["*"]; }; };
  hooks = { preroutingRaw = ""; forwardExtra = ""; inputExtra = ""; };
  rateLimits = { sshNew = "10/minute"; };
};
```

Rendering produces a single `inet` table with chains `input`, `forward`,
`prerouting` (DNAT, DNS redirect, TPROXY), `postrouting` (SNAT), plus sets
for zones' interfaces and address lists. Stateful defaults: `ct state
established,related accept`, `ct state invalid drop`. IPv6 follows identical
zone semantics; ICMPv6 essentials (RA/NS/NA/PMTU) are always allowed.

## 9. IPv6 policy

The carrier and its regulator can observe far more from IPv6 than from
NAT'd IPv4: every LAN host gets a globally routable address that may encode
its MAC (EUI-64), and hosts will happily bypass an IPv4-only tunnel via
IPv6. Janus therefore treats IPv6 as a *policy*, not a checkbox:

| Mode (per LAN) | Behavior |
|----------------|----------|
| `disabled` | No RA, no DHCPv6, RA-guard on the bridge, IPv6 forward drop. Hosts have link-local only. Safest default when a tunnel is used and the user does not need IPv6. |
| `ula-only` | RA with ULA prefix, no default route advertised. Hosts talk IPv6 internally; Internet is IPv4-only (through tunnel). |
| `delegated` | Global prefix from WAN PD is advertised. Requires **tunnel-aware** handling: (a) IPv6 flows from proxied LANs are intercepted and subject to the same rules as IPv4 (FR-NET-033); (b) AAAA handling follows DNS policy (fake-IP or remote resolution); (c) RA advertises stable-privacy + temporary addresses (`IPv6PrivacyExtensions=kernel` on the router; RA flags do not control hosts, so the docs state the host-side expectation) ; (d) optional `npt66` (network prefix translation) to hide the delegated prefix's stability. |

Default LAN IPv6 mode: `delegated` when the traffic mode is `bypass`;
`disabled` when the traffic mode is `rule-based` or `proxy-all`. An
assertion warns when `delegated` is combined with `rule-based` or
`proxy-all` and IPv6 interception is not enabled. `direct` is a rule
target, not a traffic mode.

Router-side addresses always use RFC 7217 stable-privacy
(`IPv6StableSecretAddress`), never EUI-64 (FR-NET-032). Inbound IPv6 is
zone-filtered like IPv4 (FR-NET-034).

## 10. Multicast / IPTV

`janus.network.igmpProxy = { enable; upstream = "iptv"; downstream = [ "lan" ]; }`
runs `igmpproxy` (or `smcroute` for static groups) and opens the relevant
forward rules. IPTV set-top boxes typically also need DHCP options relayed;
the IPTV WAN's `dhcp.requestOptions` and a LAN-level `dhcp.relayOptions`
cover this.

## 11. Wi-Fi

Peripherals of class `wifi` with AP capability produce `hostapd` instances:

```
janus.network.wifi.<name> = { peripheral = "wifi0"; ssid; passphraseFile|passphrase;
                              band = "2g"|"5g"; channel = "auto"; security = "wpa2"|"wpa3"|"wpa2+3";
                              lan = "lan"; hidden = false; };
```

Client (STA) mode as a WAN uplink is out of scope for 1.0.

## 12. Interaction with the proxy layer

The network layer provides two hooks used by *07 — Proxy and DNS*:

* an nftables set `janus_proxied_src` of LAN subnets with `proxied = true`;
* a fwmark (`0x4a`) and routing table reserved for engine egress so that
  tunnel packets bypass the interception path and honor the WAN routing
  tables above.
