# 08 — Configuration Reference

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-26 |

This document defines the **shape and semantics** of the `janus.*` option
tree. The final, exhaustive reference (every option with type, default,
example) is generated from the module definitions at build time
(`nix build .#docs.options`) and published alongside releases; this hand-
written document is the design contract the modules must implement.

It deliberately does **not** teach the Nix language. The example
configuration (`examples/configuration.example.nix`) is the intended
learning path: copy, edit values, build.

## 0. Conventions

* Every option path starts with `janus.`.
* Named collections are attribute sets keyed by a user-chosen name
  (`janus.network.lans.guest`), never lists, so that other options can
  refer to them by name.
* References to other objects use typed prefixes where ambiguity is
  possible: `port:`, `vlan:`, `node:`, `group:`, `sub:`. Where the type is
  fixed by context (e.g. `lans.<n>.members`), plain names are accepted.
* Secrets: prefer sops-nix (`urlSecret`, `passwordSecret`, …) naming a
  key in the user's `secrets.yaml`. A `…File` sibling remains for a file
  created on the board with `janus secrets put`. Inline strings require
  `janus.security.allowInlineSecrets`. Wi-Fi SSID is a normal string.
  See *11 — Security*.
* Durations: `"30m"`, `"6h"`, `"1d"`, or a 5-field cron expression.

## 1. `janus.system`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `hostName` | str | `"janus"` | Router host name. |
| `timeZone` | str | `"UTC"` | |
| `ntp.servers` | list str | pool | NTP servers; resolved through DNS policy. |
| `ntp.via` | `direct\|tunnel` | `direct` | Path for NTP when a tunnel exists. |
| `journal.persistent` | bool | `false` | Persist journal to state partition (capped). |
| `journal.maxUse` | str | `"64M"` | |
| `embedSource` | bool | `true` | Embed the whole flake source tree (`flake.nix`, `flake.lock`, all `.nix` modules) read-only at `/etc/janus/source` (FR-CFG-008). Disable only if the tree contains inline secrets you do not want readable on the device. |

## 2. `janus.hardware`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `board` | enum | — (required) | `rpi-zero-2w` `rpi2` `rpi3` `rpi4` `nanopi-r4s` `le-potato` `visionfive2` `yanyu-stx-r19f` `x86_64-test` |
| `peripherals.<name>.class` | enum | — | `wifi` `nic` `wwan` `bluetooth` `hmi` `power` |
| `peripherals.<name>.match` | attrs | — | `usbVendorProduct = "0bda:8153"` or `usbPath`, `pciSlot`, `mac` |
| `peripherals.<name>.wwan.mode` | enum | `auto` | `ecm` `ncm` `rndis` `qmi` `mbim` |
| `peripherals.<name>.wwan.modeSwitch` | attrs | board/ID default | usb_modeswitch parameters |
| `peripherals.<name>.wwan.atPort` | str/null | auto | Serial device for AT commands (status only) |
| `peripherals.<name>.hmi.driver` | enum | — | `ssd1306` `st7789` `waveshare-epd-2in13` … |
| `peripherals.<name>.hmi.buttons` | attrs | `{}` | GPIO → action (`cycle-group`, `refresh`, `reboot`, `factory-reset`) |
| `peripherals.<name>.wifi.capabilities` | list | from db | `ap` `sta`; assertion if AP requested on non-AP chip |

## 3. `janus.storage`

See *05 — Storage* §8. Key options: `layout.partitions.<label>.{size,
fsType, mountPoint, readOnly, options}`, `readOnlyFs`, `state.minimumSize`,
`state.onCorruption`, `firmwareOffsetMiB` (board default).

## 4. `janus.network`

### 4.1 `ports.<name>`

| Option | Type | Description |
|--------|------|-------------|
| `device` | str | Kernel interface name from the board profile (`eth0`) or peripheral. |
| `match` | attrs | Alternative stable matching (MAC, path, USB ID). |
| `mtu` | int | |
| `macAddress` | str/null | Override/clone. |

### 4.2 `vlans.<name>`

`port` (str), `id` (1–4094).

### 4.3 `wans.<name>`

See *06 — Networking* §4 for the full shape. Mandatory: `uplink`, `mode`.
Defaults: `role = "default"`, `metric = 100 + index`, `ipv6.mode =
"disabled"`, `healthCheck.enable = (role == "backup" || >1 default WANs)`.

### 4.4 `lans.<name>`

See *06* §5. Mandatory: `members`, `address`, `prefixLength`. Defaults:
`dhcp.enable = true`, range = `.100`–`.199`, `zone = <name>`,
`proxied = true`, `ipv6.mode` per traffic mode, `nat.enable = true`.

### 4.5 `wifi.<name>`, `igmpProxy`

See *06* §10–11.

## 5. `janus.firewall`

See *06* §7–8: `zones`, `policies`, `rules`, `services`, `portForwards`,
`hooks`, `rateLimits`. Defaults implement FR-FW-002.

## 6. `janus.proxy`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | |
| `engine` | `sing-box\|xray` | `sing-box` | |
| `mode` | `direct\|rule-based\|proxy-all` | `rule-based` | Traffic mode |
| `defaultTarget` | target | `"group:Auto"` | |
| `subscriptions.<name>` | submodule | | *07* §3.2 |
| `nodes.<name>` | submodule | | Manual nodes; protocol-specific submodules `vless`, `trojan`, `shadowsocks`, `hysteria2`, `tuic` |
| `groups.<name>` | submodule | | *07* §4 |
| `rules` | list | region-agnostic defaults | *07* §5 |
| `exceptions` | list | private, iptv | `proxy-all` exceptions |
| `egressWan` | str/null | `null` | Pin engine egress to a WAN |
| `blockQuic` | bool | `false` | |
| `geodata.refresh` | duration | `"weekly"` | |
| `geodata.sources` | attrs | community defaults | |
| `engineSettings` | attrs | `{}` | Raw engine config merged last (escape hatch; unsupported) |

Built-in group `Auto`: `url-test` over all subscription nodes unless the
user defines `groups.Auto`.

### 6.1 Node submodule (manual) — common fields

`protocol`, `server`, `port`, `tls.{enable, serverName, alpn, utls,
insecure, reality.{publicKey, shortId}}`, `transport.{type, path, host,
serviceName}`, `tags` (list of strings, matchable). Protocol-specific:

* `vmess.{uuid, security, alterId}` — `alterId` defaults to 0; new nodes should prefer VLESS
* `vless.{uuid, flow}` — `flow = "xtls-rprx-vision"|null`
* `trojan.{password|passwordFile}`
* `shadowsocks.{method, password|passwordFile, plugin.{name, options}}`
* `hysteria2.{password, up, down, obfs}` (sing-box only)
* `tuic.{uuid, password, congestion}` (sing-box only)

## 7. `janus.dns`

See *07* §7.2. Default set is safe for the reference environment: carrier
resolvers `never`, encryption `prefer`, fake-IP `auto`, `ipv6Answers =
"strip-for-proxied"`, `interceptPlaintext = true`.

## 8. `janus.monitoring`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `true` | Per-interface counters |
| `interfaces` | list/`"all"` | all WANs + LANs | |
| `scope` | enum | `counters` | `counters` `per-host` `flows` |
| `history.retentionDays` | int | 90 | vnstat retention |
| `flows.export.{collector, port, protocol}` | attrs | off | IPFIX/NetFlow v9 |
| `prometheus.{enable, zones}` | attrs | off | node-exporter + engine metrics on `mgmt` |
| `audit.enable` | bool | `false` | Include the connection audit log (FR-MON-007). Runtime start/stop does not change this. |
| `audit.retention` | duration | `"7d"` | Cap on the state partition. |
| `audit.interfaces` | list | proxied LANs | |

## 9. `janus.remoteAccess`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `wireguard.<name>.{privateKeyFile, address, peer.{publicKey, endpoint, allowedIPs, persistentKeepalive}}` | | | Outbound-initiated WG tunnel; interface joins `mgmt` zone |
| `wireguard.<name>.via` | `direct\|tunnel` | `direct` | |
| `tailscale.{enable, authKeyFile, loginServer}` | | off | Optional mesh backend (P3) |
| `sshReverse.{enable, host, port, remotePort, keyFile}` | | off | Reverse SSH fallback (P3) |

## 10. `janus.access`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ssh.authorizedKeys` | list str | — (≥1 required) | FR-ACC-001 |
| `ssh.port` | int | 22 | |
| `ssh.zones` | list | `["lan" "mgmt"]` | |
| `ssh.passwordAuthentication` | bool | `false` | Requires ≥1 key regardless |
| `ssh.rootPasswordFile` | path/null | `null` | Only meaningful with the above |
| `cli.enable` | bool | `true` | `janus` CLI |

## 11. Secrets and hot overrides

Secrets in the user's private repo:

```
sops.defaultSopsFile = ./secrets.yaml;
sops.age.keyFile = "/var/lib/janus/secrets/age.key";   # not in git; on the state partition
janus.proxy.subscriptions.providerA.urlSecret = "sub-providerA";
janus.network.wans.main.pppoe.passwordSecret = "pppoe";
janus.network.wifi.home.passphraseSecret = "wifi-home";
```

The age key is created once, backed up by the user, and never committed.
Decryption runs at boot into `/run/secrets` (tmpfs). The Nix store holds
ciphertext only.

Hot overrides are not Nix options. They are keys in
`/var/lib/janus/overrides.json`, written by `janus override set` and read
by the runtime renderers:

| Key | Example |
|-----|---------|
| `proxy.subscriptions.<name>.url` | rotate a vendor URL without rebuilding |
| `network.lans.<name>.dhcp.staticLeases.<host>` | add a lease |
| `network.wifi.<name>.passphrase` | rotate a PSK; stored in the secrets directory, not in the JSON |

Anything else is rejected. `janus override diff` shows drift. `janus
override export` prints Nix (and, for secret keys, a reminder to update
`secrets.yaml`) for the private config repo.

## 12. Validation rules (assertions) — non-exhaustive

* Every `uplink`/`members` entry resolves to a port, VLAN or peripheral.
* No two LANs overlap in IPv4 subnet; no LAN overlaps a WAN static subnet.
* Exactly one `role = "default"` WAN with the lowest metric, or explicit
  metrics for all defaults.
* Every `target = "group:X"` refers to a defined group or `Auto`.
* Every group has a non-empty membership at build time *or* an
  `emptyFallback`.
* Engine capability check for every node protocol and feature.
* `janus.access.ssh.authorizedKeys != []`.
* `janus.storage`: `/` and `/nix` read-only; exactly one rw partition at `/var`.
* IPv6 `delegated` + traffic mode ≠ `direct` → warning unless IPv6
  interception is enabled.
* `janus.hardware.board` is set and supports every declared peripheral class.
* A `wwan` peripheral whose USB ID is not on the allowlist fails evaluation.
