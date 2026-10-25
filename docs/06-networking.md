# 06 — Networking Design

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-25 |

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
  uplink   = "wan" | "wan.35" | "wwan0" | "cafe0";  # port, vlan, wwan or wifi peripheral
  mode     = "dhcp" | "static" | "pppoe" | "wwan" | "wifi";
  role     = "default" | "iptv" | "backup" | "custom";
  metric   = 100;
  dhcp     = { vendorClass, clientId, requestOptions, hostname, sendRelease };
  static   = { address, prefixLength, gateway, dns };
  pppoe    = { username, passwordFile|password, serviceName, mtu, mru,
               lcpEchoInterval, lcpEchoFailure, ipv6 };
  wwan     = { peripheral, apn, pin, auth };
  wifi     = { networks = [ { ssid; passphraseFile|passphrase|passphraseSecret;
                              priority; } ]; };
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
  An unset metric is 100 plus the WAN index, or 1100 plus the index for
  a backup, so a backup stays above every default (D-0036).
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
* **`wifi`** associates with `wpa_supplicant` and then takes DHCP, the
  same client path as `dhcp` (D-0055, FR-NET-018). `uplink` is a `wifi`
  peripheral whose profile lists `sta`. That peripheral is not also an
  access point. Each entry in `wifi.networks` is one known WPA2-PSK
  network. The SSID is configuration. The passphrase is a sops file, the
  same shape as an access-point passphrase (§11). `priority` is an
  integer; a higher value is tried first; an unset value is 0. The
  station uses the dongle's permanent MAC. Health targets stay the
  existing option: an upstream that does not route `1.1.1.1` and
  `9.9.9.9` needs targets it does route. On a portable board the
  Ethernet WAN is `default` and this WAN is `backup`, so a cable with a
  lease keeps the default route (D-0036).

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
  proxy    = { mode, rules, defaultTarget, exceptions };  # unset inherits; D-0042
  dns      = { ... };           # same shape as janus.dns; unset inherits
  nat      = { enable = true; hairpin = true; };
  isolation = false;             # bridge port isolation inside this LAN
};
```

Each LAN is a Linux bridge `br-<name>`. Bridging a Wi-Fi AP means the
`hostapd` interface is a bridge member. Static leases feed both DHCP and
local DNS (FR-NET-012).

`proxy.mode` is `bypass`, `rule-based`, or `proxy-all`. Unset, it is
`janus.proxy.mode`. Unset `proxy.rules`, `defaultTarget`, and `exceptions`
inherit the router values. A set rule list replaces them. `dns` inherits
`janus.dns` the same way. `dns.recursive = false` answers hosts and leases
only. `isolation` is bridge port isolation inside one LAN. It is not the
firewall rule between zones (D-0039, D-0042). `bypass` is not intercepted.
`rule-based` and `proxy-all` are.

## 6. DHCP server and RA

dnsmasq serves DHCP only (ADR-0009). It is not a DNS policy engine.
Per-LAN scopes, static leases, custom options, and a lease file on `/var`
are its job. Lease hostnames are exported for DNS. RA is provided by
networkd (`IPv6SendRA=`) with the prefix from PD or ULA. A LAN in
`janus.dns.listen.lans` is told to use the router: DHCPv4 option 6 carries
the LAN's IPv4 address, `ula-only` names the ULA, and `delegated` names
the router's IPv6 link-local (`DNS=_link_local`). The delegated address
itself is assigned at runtime, and an IPv4 literal is not an RDNSS address.

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

The default policy list is `lan → wan` accept (FR-FW-002). The
`guest → wan` row above is an extra policy, so a guest LAN can use the
Internet without reaching `lan`. A zone with no policy to `wan`, such as
`iot`, has no WAN path. There is no implicit forward between LAN zones.
`wan → *` stays drop. Assigning `policies` replaces this default list, so
a written list that should keep the owner's Internet includes the
`lan → wan` row.

A service may set `confine = true`. The port is then accepted on the
named zones and dropped on every other interface, before a zone whose
`input` is `accept` can open it. Prometheus uses this, so
`prometheus.zones` is the only path to port 9100. The DNS service
defaults to the `lan` zone. A guest or IoT zone queries the router only
after that zone is added to `services.dns.zones`.

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

Default LAN IPv6 mode follows that LAN's `proxy.mode`: `delegated` when
it is `bypass`; `disabled` when it is `rule-based` or `proxy-all`. An
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

The Zero 2 W onboard radio is the same kind of access point, declared
with `match.onboard = true`. It is 2.4 GHz WPA2 (D-0043, *10* §4.7).
The ROCK Pi 4C radio is the same declaration. It is the AP6256, WPA2,
2.4 GHz or 5 GHz, HT20 (*10* §4.10, D-0053). The Pi 3 profile is the
same declaration, 2.4 GHz WPA2 (*10* §4.12, D-0056). A Pi 2 v1.2 uses
that profile and leaves `match.onboard` unset. The Pi 4 profile is
2.4 GHz or 5 GHz, WPA2, HT20. A Compute Module 4 without the wireless
chip leaves `match.onboard` unset.

`janus.network.wifiCountry` is one ISO 3166-1 alpha-2 code for every
access point. Unset, it follows `janus.system.region`: `cn` is `CN`,
`ru` is `RU`, and `ir` is `IR`. The region stays the censorship
environment. `hostapd` sets `country_code` and `ieee80211d`. A channel
the country disallows fails when the access point starts (D-0054).

A peripheral whose profile lists `sta` can instead be a WAN uplink
(D-0055, FR-NET-018, *10* §4.11):

```
janus.hardware.peripherals.cafe0 = {
  class = "wifi";
  match.usbVendorProduct = "0bda:8179";
};
janus.hardware.peripherals.ap0 = {
  class = "wifi";
  match.usbVendorProduct = "0bda:8176";
};
janus.network.wifi.room = {
  peripheral = "ap0"; ssid = "janus"; passphraseSecret = "wifi-potato-room"; lan = "lan";
};
janus.network.wans.cable = { uplink = "wan"; mode = "dhcp"; role = "default"; };
janus.network.wans.cafe = {
  uplink = "cafe0"; mode = "wifi"; role = "backup";
  wifi.networks = [
    { ssid = "Cafeteria"; passphraseSecret = "wifi-potato-cafeteria"; priority = 10; }
  ];
};
```

The profile is the list of modes the in-tree driver advertises, `ap`,
`sta`, or both. The operator picks one role per peripheral. A profile
that lists both means either role is legal. It does not mean one radio
is an access point and a station together. Evaluation fails when an
access point names a peripheral whose profile lacks `ap`, when a
`mode = "wifi"` WAN names one whose profile lacks `sta`, or when one
peripheral is used both ways.

`wpa_supplicant` renders `wifi.networks` and networkd runs DHCP on the
station interface. The interface joins the `wan` zone. The passphrase
file is one line under `value`, at `secrets/wifi/<host>/<network>.yaml`,
encrypted to that host.

1.0 joins known WPA2-PSK networks that route when the handshake
finishes. Four cases stay after 1.0. An open network has no passphrase.
WPA-Enterprise asks for an identity. A network typed in at the hotel is
a new block on the state partition, written by a later router command,
and it is not a hot override of an existing passphrase (FR-OPS-007) and
not a fleet file. A captive portal is the page a public network shows
after association, before it routes (airports and many cafés). NAT
presents the station MAC for every LAN client, so the page is completed
on the router (Q-0047). A cafeteria whose WPA2 password still leads to
that page is this later case.

## 12. Interaction with the proxy layer

The network layer provides two hooks used by *07 — Proxy and DNS*:

* an nftables set `janus_proxied_src` of LAN subnets whose `proxy.mode` is
  `rule-based` or `proxy-all`;
* a fwmark (`0x4a`) and routing table reserved for engine egress so that
  tunnel packets bypass the interception path and honor the WAN routing
  tables above.
