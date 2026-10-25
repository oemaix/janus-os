# 08 — Configuration Reference

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-25 |

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
  file under `secrets/` (§11). A `…File` sibling remains for a file
  created on the board with `janus secrets put`. Inline strings require
  `janus.security.allowInlineSecrets`. Wi-Fi SSID is a normal string.
  See *11 — Security*.
* Durations: `"30m"`, `"6h"`, `"1d"`, or a 5-field cron expression.
  For `janus.proxy.subscriptions.<name>.refresh` and
  `janus.proxy.geodata.refresh`, the day-of-month and the month are `*`.
  The day-of-week may be `*` or a list such as `2,4,6`. `0` and `7` are
  Sunday, and `1` is Monday (D-0044).

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
| `reboot.schedule` | null or str | off | Maintenance reboot. `monthly` is 04:00 on the 1st, `yearly` is 04:00 on 1 January, or a five-field cron whose day-of-week is `*`. Further actions on this reboot are sibling options (D-0049). |
| `reboot.fsck` | bool | `false` | On that reboot, run a full state check and let it finish. The request is removed before the check, so a check that does not finish is not repeated. A normal boot does not. Requires `reboot.schedule`. |
| `region` | `cn\|ru\|ir` | `cn` | Reference region. Selects domestic DNS and the `blockQuic` default in *21*. Routing rules stay empty until written. Not a hot override. |
| `kernelProfile` | `standard\|compact` | `standard` | `standard` is the NixOS kernel. `compact` is one config for every board and drops sound, desktop and 3D GPUs, compute accelerators, cameras and TV, HDMI-CEC and infrared remotes, industrial I/O and Comedi, InfiniBand, and SAN. NIC drivers, Wi-Fi, USB, WWAN, Bluetooth, MMC, the NVMe host, AHCI, simpledrm, SoC scanout that does not depend on ALSA, f2fs, vfat, and virtio stay. Raspberry Pi HDMI depends on ALSA and is not in `compact`. The board consoles are serial (D-0051). A per-board driver cut is not a value (D-0052). |

## 2. `janus.hardware`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `board` | enum | — (required) | `rpi-zero-2w` `rpi2` `rpi3` `rpi4` `nanopi-r4s` `rockpi-4c` `le-potato` `visionfive2` `yanyu-stx-r19f` `x86_64-test` |
| `peripherals.<name>.class` | enum | — | `wifi` `nic` `wwan` `bluetooth` `hmi` `power` |
| `peripherals.<name>.match` | attrs | — | `usbVendorProduct = "0bda:8153"`, or `usbPath`, `pciSlot`, `mac`. `onboard = true` is the radio soldered to the board (*10* §4.7, §4.10). |
| `peripherals.<name>.wwan.mode` | enum | `auto` | `auto` uses the mode the allowlist records for that USB ID (*10* §4.2). Explicit values: `ecm` `ncm` `rndis` `qmi` `mbim`. |
| `peripherals.<name>.wwan.modeSwitch` | attrs | `{}` | usb_modeswitch parameters. Empty does not run usb_modeswitch. |
| `peripherals.<name>.wwan.atPort` | str/null | auto | Serial device for AT commands (status only) |
| `peripherals.<name>.hmi.profile` | enum | — | `waveshare-1.3-oled-hat` sets the SH1106 panel, SPI pins, and the key map in *10* §4.6. Behaviour is *15*. |
| `peripherals.<name>.hmi.driver` | enum | from profile | `sh1106` `ssd1306` `st7789` `waveshare-epd-2in13` |
| `peripherals.<name>.hmi.keys.<name>` | enum | profile default | Replace one key's action: `refresh`, `reboot-hold`, `factory-reset`, `unbound`. The joystick stays navigation. |
| `peripherals.<name>.wifi.capabilities` | list | from db | `ap` `sta`; assertion if AP requested on non-AP chip |
| `peripherals.<name>.power.shutdown.enable` | bool | `true` if the profile knows the discharge sign | Early cutoff while the cell is discharging (*10* §4.5). |
| `peripherals.<name>.power.shutdown.warnVolts` | float | `3.60` | Must be ≥ the shutdown voltage. |
| `peripherals.<name>.power.shutdown.volts` | float | `3.50` | Sustained 60 s. MUST NOT be set below 3.50. |
| `peripherals.<name>.power.shutdown.criticalVolts` | float | `3.30` | Sustained 10 s. MUST NOT be set below 3.30. |

## 3. `janus.storage`

See *05 — Storage* §8. Key options: `layout.partitions.<label>.{size,
fsType, mountPoint, readOnly, options}`, `readOnlyFs`, `nix.minimumSize`, `state.minimumSize`,
`state.maximumSize` (default `4G`; growth stops there or at the end of the
media, and a smaller cap does not shrink), `state.onCorruption`,
`firmwareOffsetMiB` (board default),
`slots.enable` (default false; duplicate `ROOT` and `NIX`, *09* §8.4).
A normal boot runs `fsck.f2fs -a --no-kernel-check` and does not scan the
volume. A missing block device is not corruption. Status 4 or 255 is
checked again before reformat (D-0049).

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
Defaults: `role = "default"`, `metric = 100 + index` (`1100 + index` when
`role` is `backup`), `ipv6.mode = "disabled"`, `healthCheck.enable =
(role == "backup" || >1 default WANs)`.

### 4.4 `lans.<name>`

See *06* §5. Mandatory: `members`, `address`, `prefixLength`. Defaults:
`dhcp.enable = true`, range = `.100`–`.199`, `zone = <name>`,
`ipv6.mode` follows that LAN's traffic mode (*06* §9), `nat.enable = true`.
`proxy.mode`, `proxy.rules`, `proxy.defaultTarget`, and `proxy.exceptions`
inherit `janus.proxy` when unset (*07* §5, D-0042). `dns` inherits
`janus.dns`. `dns.recursive` defaults to `true`.

### 4.5 `wifi.<name>`, `wifiCountry`, `igmpProxy`

See *06* §10–11. `wifiCountry` is one ISO alpha-2 code for every access
point. Unset, `cn` is `CN`, `ru` is `RU`, and `ir` is `IR` (D-0054).

## 5. `janus.firewall`

See *06* §7–8: `zones`, `policies`, `rules`, `services`, `portForwards`,
`hooks`, `rateLimits`. Defaults implement FR-FW-002.

## 6. `janus.proxy`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | |
| `failMode` | `closed\|open` | `closed` | When the engine is down, `closed` drops proxied LAN traffic and `open` sends it out the WAN (ADR-0016). |
| `engine` | `sing-box\|xray` | `sing-box` | Keep sing-box when LANs need different DNS. The other reasons to switch are *07* §2.1. |
| `mode` | `bypass\|rule-based\|proxy-all` | `rule-based` | Default traffic mode. A LAN inherits it (*07* §5, D-0042). |
| `defaultTarget` | target | `"group:Auto"` | |
| `subscriptions.<name>` | submodule | | *07* §3.2 |
| `nodes.<name>` | submodule | | Manual nodes; protocol-specific submodules `vless`, `trojan`, `shadowsocks`, `hysteria2`, `tuic` |
| `groups.<name>` | submodule | | *07* §4 |
| `groupsAuto` | bool | `true` | Render the implicit `Auto` and `sub:<name>` groups. `false` requires every target to name a defined group (ADR-0026); sing-box only |
| `rules` | list | `[]` | Inherited by a LAN that does not set `proxy.rules`. A set LAN list replaces this one. *07* §5, *21*. Empty until written. The example has the `cn`, `ru`, and `ir` lists. |
| `exceptions` | list | private, iptv | `proxy-all` exceptions. A LAN inherits this list. |
| `egressWan` | str/null | `null` | Pin engine egress to a WAN |
| `blockQuic` | bool | `false`; `true` when `janus.system.region` is `ru` | *21* |
| `geodata.refresh` | duration | `"weekly"` | `Nh`, `Nm`, `weekly`, `daily`, `hourly`, or a five-field cron. Day-of-week may be a list such as `2,4,6` (D-0044). |
| `geodata.sources` | attrs | community defaults | Base URLs, plus `tags.<file>` for one rule-set file (*21* §4.3). |
| `geodata.hashes` | attrs of sha256 | `{}` | Overrides the built-in pins. A referenced tag with no pin is left for the router |
| `engineSettings` | attrs | `{}` | Raw engine config merged last (escape hatch; unsupported) |

Built-in group `Auto`: `url-test` over all subscription nodes unless the
user defines `groups.Auto` or sets `groupsAuto = false` (ADR-0026).

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

See *07* §7.2. Default set is the `cn` preset: carrier resolvers `never`,
encryption `prefer`, fake-IP `auto`, `ipv6Answers = "strip-for-proxied"`,
`interceptPlaintext = true`, `blockDoT = true`. `ru` and `ir` replace the
domestic fields (*21*). `ir` has no built-in domestic resolver. With the
proxy enabled, an empty list fails evaluation.

`bootstrap` is a list of IP addresses for DoH and DoT hostnames (D-0040).
Unset, it follows the region: `cn` is `223.5.5.5` and `223.6.6.6`, `ru` is
`77.88.8.8` and `77.88.8.1`, `ir` is empty. An explicit list replaces that.
The build does not look the hostnames up. A name with an empty list fails
evaluation. `recursive` defaults to `true`. A LAN's `dns` inherits the fields that
exist on that submodule (*07* §7.2, D-0042). `listen.lans`, `encryption`,
`domestic.ecs`, `remote.ecs`, and `cache` stay on the router.

`listen.lans` defaults to `all`: those LANs are told, by DHCP option 6 and
by RA, to use the router. A delegated RA names the IPv6 link-local. `encryption`
defaults to `prefer`. `require` accepts only DoH, DoT, and DoQ for a
resolver that answers a client. The engine queries the first address in
each resolver list. sing-box 1.13 has one server per DNS rule and no
failover group. xray 26 does not stably share one name across two servers.
`domestic.ecs` defaults to `allow` and `remote.ecs` to `strip`. Neither
value attaches a client subnet: sing-box 1.13 would disable the DNS cache,
and xray 26 has no such field. `cache.size` defaults to 4096 and
`cache.minTtl` to 60. sing-box uses them as the cache capacity and as the
TTL it writes on each routed answer. xray 26 has neither knob, so another
value fails evaluation. `carrierResolvers = "fallback-only"` is not
available for the same one-server limit. `domestic-only` uses the first
learned WAN address as the domestic server.

`remote.via` defaults to `tunnel`. A bypass LAN has no tunnel, so the
remote resolvers stay unused and every recursive name is answered by the
domestic resolvers. `remote.via = "direct"` splits a bypass LAN: the
domestic sets keep the domestic resolvers, and every other name goes to
the remote resolvers from the WAN, encrypted (*07* §7.2).

## 8. `janus.monitoring`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `true` | Per-interface counters |
| `interfaces` | list/`"all"` | all WANs + LANs | WAN, LAN, port, VLAN, or Wi-Fi names. Flow export resolves them to kernel interfaces. |
| `scope` | enum | `counters` | `counters` `per-host` `flows` |
| `history.retentionDays` | int | 90 | vnstat retention |
| `flows.export.{collector, port, protocol}` | attrs | off | IPFIX/NetFlow v9 |
| `prometheus.{enable, zones}` | attrs | off | node-exporter + engine metrics. Port 9100 is IPv4 and IPv6, and is confined to `zones` (default `mgmt`). |
| `audit.enable` | bool | `false` | Include the connection audit log (FR-MON-007). One JSON object per line. Runtime start/stop does not change this. |
| `audit.retention` | duration | `"7d"` | Cap on the state partition. |
| `audit.interfaces` | list | proxied LANs | |

## 9. `janus.remoteAccess`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tailscale.enable` | bool | `false` | Router joins a tailnet. `tailscale0` joins the `mgmt` zone. When true, exactly one of `authKeySecret` and `authKeyFile` is set. |
| `tailscale.authKeySecret` | str | — | sops secret name. One line in `secrets/tailscale/<host>.yaml`, encrypted to that host. |
| `tailscale.authKeyFile` | path | — | File from `janus secrets put`. |
| `tailscale.loginServer` | str/null | `null` | Headscale URL. Unset uses Tailscale's coordination. |
| `tailscale.advertiseRoutes` | list | `[]` | LAN prefixes offered to the tailnet. Empty: peers reach the router only. |
| `tailscale.exitNode` | bool | `false` | Router may carry a peer's Internet traffic. |
| `wireguard.<name>.{privateKeyFile, address, peer.{publicKey, endpoint, allowedIPs, persistentKeepalive}}` | | | Optional tunnel to a user endpoint. Interface joins `mgmt`. |
| `wireguard.<name>.via` | `direct\|tunnel` | `direct` | |

## 10. `janus.access`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ssh.authorizedKeys` | list str | — (≥1 required) | FR-ACC-001 |
| `ssh.port` | int | 22 | |
| `ssh.zones` | list | `["lan" "mgmt"]` | Sets `janus.firewall.services.ssh` unless that service is set directly. |
| `ssh.passwordAuthentication` | bool | `false` | Requires ≥1 key and `ssh.rootPasswordFile`. |
| `ssh.rootPasswordFile` | path/null | `null` | Hash file on the state partition. Applied at boot. Not a plaintext password. |
| `cli.enable` | bool | `true` | `janus` CLI |
| `web.enable` | bool | `false` | Include the maintenance page (*20*). Runtime start and stop do not change this. |
| `web.port` | int | `8443` | TLS only. |
| `web.zones` | list | `["lan" "mgmt"]` | `wan` fails evaluation. |
| `web.passphraseSecret` | str | — | sops secret name. One line in `secrets/web/<host>.yaml`, encrypted to that host (ADR-0023). Not the SSH root password. |
| `web.passphraseFile` | path | — | File from `janus secrets put`. When `web.enable` is true, exactly one of this and `passphraseSecret` is set. |
| `deploy.address` | str | the `nixosConfigurations` attribute name | SSH destination for `janus-build deploy`, `fleet apply`, `fleet pull`, `status`, and `backup`. `janus-build` reads it from the fleet repo when the command runs. `fleet apply` still requires a clean git tree. A new image is not required (Q-0043). |

## 11. Secrets and hot overrides

One credential is one sops file (ADR-0022). The age private key for this
router is `/var/lib/janus/secrets/age.key` on the state partition. It is
not in git. Public keys are `secrets/keys/<host>.pub`.

```text
secrets/keys/potato.pub
secrets/wifi/potato/home.yaml
secrets/pppoe/potato/main.yaml
secrets/tailscale/potato.yaml
secrets/wireguard/potato/uplink.yaml
secrets/subscription/vendor-a.yaml   # proxy subscription URL
secrets/nodes/manual-a.yaml          # manual proxy-node credential
secrets/web/potato.yaml              # maintenance page passphrase
```

`wifi`, `pppoe`, `tailscale`, `wireguard`, and `web` are encrypted to
that host only. `secret set` encrypts a proxy subscription file and a
manual proxy-node file to every public key under `secrets/keys/`; a
`fleet pull` rotation re-encrypts them to only the hosts that reference
the file. A PPPoE file and a manual node file hold the YAML document.
The other files hold one value.

`janus-build secret set` writes a sops document encrypted to the
recipients of that path. sops-nix decrypts it into `/run/secrets`. A
one-line credential is the `value` key. A PPPoE file and a manual node
file are the YAML document. The module sets the key for an option that
names the secret: `value` for a Wi-Fi passphrase, a page passphrase, a
Tailscale auth key, and a subscription URL, and the whole document for
PPPoE. A page `passphraseFile`, a PPPoE `passwordFile`, or a WireGuard
`privateKeyFile` that is `/run/secrets/<name>` is one line, so the module
sets that secret's `key` to `value`. A node `passwordFile` on that path
is the YAML document, so the module sets `key` to `""`. Each of those is
`mkDefault`. A key the fleet sets stays. The fleet sets
`sops.secrets.<name>.sopsFile` and the janus option. It does not decrypt
the file in its own unit.

```nix
sops.age.keyFile = "/var/lib/janus/secrets/age.key";
sops.secrets.wifi-potato-home.sopsFile = ./secrets/wifi/potato/home.yaml;
janus.network.wifi.home.passphraseSecret = "wifi-potato-home";
sops.secrets.pppoe-potato-main.sopsFile = ./secrets/pppoe/potato/main.yaml;
janus.network.wans.main.pppoe.passwordSecret = "pppoe-potato-main";
sops.secrets.subscription-vendor-a.sopsFile = ./secrets/subscription/vendor-a.yaml;
janus.proxy.subscriptions.providerA.urlSecret = "subscription-vendor-a";
sops.secrets.tailscale-potato.sopsFile = ./secrets/tailscale/potato.yaml;
janus.remoteAccess.tailscale.authKeySecret = "tailscale-potato";
sops.secrets.web-potato.sopsFile = ./secrets/web/potato.yaml;
janus.access.web.passphraseSecret = "web-potato";
```

`janus-build secret keygen` creates the keypair outside the image build.
The build host keeps the public key. Decryption runs at boot into
`/run/secrets` (tmpfs). The Nix store holds ciphertext only.

Hot overrides are not Nix options. They are keys in
`/var/lib/janus/overrides.json`, written by `janus override set` and read
by the runtime renderers:

| Key | Example |
|-----|---------|
| `proxy.subscriptions.<name>.url` | rotate a vendor URL without rebuilding |
| `network.lans.<name>.dhcp.staticLeases.<host>` | add a lease |
| `network.wifi.<name>.passphrase` | rotate a PSK; stored in the secrets directory, not in the JSON |

Anything else is rejected. `janus override diff` shows drift and redacts
secret values. The board does not emit Nix and has no `janus override
export`. `janus-build fleet pull` writes leases into
`hosts/<host>/overrides.nix`. Secret values are written only with
`--with-secrets` (*16* §5).

## 12. Validation rules (assertions) — non-exhaustive

* Every `uplink`/`members` entry resolves to a port, VLAN or peripheral.
* No two LANs overlap in IPv4 subnet; no LAN overlaps a WAN static subnet.
* Exactly one `role = "default"` WAN with the lowest metric, or explicit
  metrics for all defaults.
* Every `target = "group:X"` refers to a defined group or `Auto`. With
  `groupsAuto = false` only a defined group is accepted.
* Every group has a non-empty membership at build time *or* an
  `emptyFallback`.
* Engine capability check for every node protocol and feature.
* `janus.access.ssh.authorizedKeys != []`.
* `janus.storage`: `/` and `/nix` read-only; exactly one rw partition at `/var`.
* IPv6 `delegated` with traffic mode `rule-based` or `proxy-all` → warning
  unless IPv6 interception is enabled. `bypass` does not warn.
* `janus.hardware.board` is set and supports every declared peripheral class.
* A `wwan` peripheral whose USB ID is not on the allowlist fails evaluation.
