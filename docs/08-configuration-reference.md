# 08 — Configuration Reference

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-14 |

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
| `reboot.fsck` | bool | `false` | On that reboot, run a full state check. It stops after 30 minutes. Hitting that cap fails the boot and does not reformat. The request is removed before the check, so a check that does not finish is not repeated. A normal boot does not. Requires `reboot.schedule`. |
| `region` | `cn\|ru\|ir` | `cn` | Reference region. Selects domestic DNS and the `blockQuic` default in *21*. Routing rules stay empty until written. Not a hot override. |
| `kernelProfile` | `standard\|compact\|matched` | `standard` | `standard` is the NixOS kernel. `compact` is one config for every board and drops sound, desktop and 3D GPUs, compute accelerators, cameras and TV, HDMI-CEC and infrared remotes, industrial I/O and Comedi, InfiniBand, and SAN. NIC drivers, Wi-Fi, USB, WWAN, Bluetooth, MMC, the NVMe host, AHCI, simpledrm, SoC scanout that does not depend on ALSA, f2fs, vfat, and virtio stay. Raspberry Pi HDMI depends on ALSA and is not in `compact`. The board consoles are serial (D-0051). `matched` includes that cut, then keeps a driver only when this board or a declared peripheral uses it (D-0052). How the profiles are built is *23*. It also turns foreign SoC platforms off and keeps one vendor per board. A kept vendor still builds that vendor's other SoCs. `DRM` stays only on `x86_64-test` (T-0041). An MMC host the initrd does not list stays built in. Huawei NCM (`12d1:1506`) keeps `huawei_cdc_ncm`. Sound stays off unless `janus.audio.enable` selects an embedded or USB device on `matched` (D-0061). `compact` still drops sound. Compute accelerators stay off (D-0057). |

## 1a. `janus.soloist`

Off unless `enable` is set. A false setting adds no unit, secret, or
package, and the assertions below are not evaluated. True installs the
locked Linux build for `x86_64`, `aarch64`, or `armv7l` and starts it.
Any other architecture fails evaluation. The three archives are flake
inputs. `flake.lock` holds the narHash, and `nix flake update` moves it
(D-0058, T-0010). The repository does not store the archive. Pairing
is `janus bluetooth` and the maintenance page (D-0059).

| Option | Type | Default | Contract |
|---|---|---|---|
| `enable` | bool | `false` | Connect playback device (FR-SVC-001, D-0056). `true` needs `janus.audio.enable`, `janus.audio.playback.output`, and a board architecture of `x86_64`, `aarch64`, or `armv7l`. It starts Soloist and, when playback needs a local device, system-wide PipeWire. BlueZ follows `janus.audio`, not this switch (D-0061). |
| `apiKeySecret` | null or string | unset | sops name. One line, `value:`, in `sopsFile`. Plaintext only in `/run/secrets`. Required when `enable` is true (FR-SEC-012). |
| `sopsFile` | null or path | unset | sops document for `apiKeySecret`. The secret is installed only when `enable` is true. |
| `name` | null or string | the host name | Spotify Connect name. |
| `zones` | list of strings | `lan` | Where a Spotify Connect client may find this router. UDP 5353 is accepted there and dropped elsewhere. `wan` fails evaluation. `guest` and `iot` only when the firewall defines them. |

## 1b. `janus.audio`

Off unless `enable` is set. Playback and recording are read only when
`enable` is true. Setting `output`, `input`, or `node` while `enable`
is false fails evaluation. Both devices stay unset until chosen.
Declaring a device does not start PipeWire or BlueZ. Soloist is the
only consumer until speech is enabled (D-0061, D-0062).

| Option | Type | Default | Contract |
|---|---|---|---|
| `enable` | bool | `false` | Shared audio devices. `false` adds no kernel sound. |
| `playback.output` | null or `embedded` \| `usb` \| `bluetooth` | unset | Where shared playback goes. `embedded` is the board's own device. `usb` is a USB audio interface. `bluetooth` is an A2DP speaker, with AVRCP. HFP and HSP stay off. Bluetooth needs a `bluetooth` peripheral or onboard Bluetooth on the Zero 2 W, the Pi 3, the Pi 4, or the ROCK Pi 4C. |
| `playback.node` | null or string | unset | PipeWire sink for `embedded` and `usb`. A blank value fails evaluation. `bluetooth` does not use it. Soloist passes it as `--pipewire-device`. |
| `recording.input` | null or `embedded` \| `usb` \| `bluetooth` | unset | Where shared recording comes from. `bluetooth` fails evaluation while HFP and HSP stay off. |
| `recording.node` | null or string | unset | PipeWire source for `embedded` and `usb`. |

The two node strings must differ. PipeWire's usual names carry the
direction: `alsa_input.` and `bluez_input.` are sources, and so is an
`alsa_output.` or `bluez_output.` name that ends in `.monitor`. The
other `alsa_output.` and `bluez_output.` names are sinks. A playback
node that names a source fails evaluation, and a recording node that
names a sink fails evaluation. A number or a custom name has no
direction in the string, so that check accepts it.

`embedded` and `usb` need `kernelProfile` `standard` or `matched`.
`compact` still drops kernel sound (D-0057). `matched` includes that
device's driver when `enable` is true, and leaves `SOUND` off otherwise.
Bluetooth playback does not turn kernel sound on. `embedded` is not a
device on the NanoPi R4S. `janus.soloist.enable` needs `enable` and a
playback device. Without playback, speech synthesis may still return
audio on the network. Without recording, speech recognition may still
accept network audio (D-0062).

PipeWire starts when Soloist, recognition, or synthesis needs a local
device, and when playback or recording is `bluetooth`. BlueZ starts
when playback or recording is `bluetooth`, without Soloist.
`recording.input = bluetooth` still fails while HFP and HSP stay off,
so that arm does not start them (D-0061).

## 1c. `janus.edge.api`

`janus.edge` is a namespace and has no `enable` switch. Audio, Soloist,
and Bluetooth stay outside it. `janus.edge.llm` is the future
language-model service and is not an option in this tree (§1e).

Off unless `enable` is set. This is the listener other devices call.
Speech uses it now. The Ara240 and Hailo-10H language-model faces use
it when those options exist (D-0062, FR-SVC-002, FR-SVC-003). It is
not the maintenance page (*20*).

| Option | Type | Default | Contract |
|---|---|---|---|
| `enable` | bool | `false` | Shared HTTP listener. `false` adds no unit, certificate, or token. |
| `port` | int | `8473` | TLS port. Not `janus.access.web.port`. |
| `zones` | list of strings | `lan`, `mgmt` | Where a client may open the port. `wan` fails evaluation. `guest` and `iot` only when the firewall defines them. An empty list fails evaluation. |
| `tokenSecret` | null or string | unset | sops name, such as `edge-api-<host>`. One line, `value:`, in `secrets/edge-api/<host>.yaml`. Plaintext only in `/run/secrets`. |
| `tokenFile` | null or path | unset | File from `janus secrets put`. |
| `sopsFile` | null or path | unset | `secrets/edge-api/<host>.yaml`. Installed only when `enable` is true. |

When `enable` is true, exactly one of `tokenSecret` and `tokenFile`
is set. Evaluation fails when neither is set, when both are set, and
when `tokenSecret` has no `sopsFile`. The token is not the maintenance
page passphrase (FR-SEC-013).

stunnel terminates TLS on `port` and forwards cleartext HTTP to a
Janet program on a root-only socket. Nothing accepts plaintext HTTP.
The certificate is created on first start under
`/var/lib/janus/http/`, self-signed, the same shape as *20* §2.
`janus edge api stop` pauses the listener without a rebuild. `janus edge api
start` exits 2 when the image was built with `enable = false`, and
exits 1 when the token file is missing or empty.

A call sends `Content-Length`. `Transfer-Encoding: chunked` is refused.
The bearer token is checked from the headers before the body is read.
Four calls may be in flight. A fifth is refused with `503` and `busy`.

## 1d. `janus.edge.speech`

Two switches, one listener. Either may be on alone. Both stay off in
a 1.0 image. The programs run on the CPU (D-0062).

| Option | Type | Default | Contract |
|---|---|---|---|
| `asr.enable` | bool | `false` | `whisper.cpp` with the locked multilingual `base` weights. `true` needs `janus.edge.api.enable`. A board that cannot run it fails evaluation. |
| `asr.language` | null or string | unset | Decode language of that `base` model. Unset detects it. Any other string fails evaluation. |
| `tts.enable` | bool | `false` | Released Piper. `true` needs `janus.edge.api.enable` and `tts.voice`. A board that cannot run it fails evaluation. |
| `tts.voice` | null or string | unset | Piper voice id `ll_CC-name-quality`. Required when `tts.enable` is true. The id is a locked voice input, and it is the language. |

`false` adds no package. The sources are flake inputs: a released
`whisper.cpp`, the released `base` weights, a released Piper from
<https://github.com/OHF-Voice/piper1-gpl>, and each locked voice.
`nix flake update` moves the lock. A pin that is not a release fails
the update (T-0020).

Recognition fails evaluation on the Zero 2 W, the Pi 2, the Pi 3, Le
Potato, and the VisionFive 2. Synthesis fails evaluation on the Zero
2 W and the VisionFive 2. The Pi 2, the Pi 3, and Le Potato may enable
synthesis only. The ROCK Pi 4C, the Pi 4, the NanoPi R4S, the Yanyu,
and `x86_64-test` may enable either. The Pi 4 and the NanoPi R4S
profiles do not name a RAM SKU. The fit is the 4 GiB board. The Yanyu
does not hold conversation pace. `x86_64-test` is the CI image.

A call names a channel. A channel that is not configured is an error
and the call does not run.

| Channel | Direction | Exists when |
|---|---|---|
| `network` | input or output | The call arrived on a zone `janus.edge.api.zones` serves. |
| `microphone` | input only | `janus.audio.recording` is set. `bluetooth` is not that device while HFP and HSP stay off. |
| `playback` | output only | `janus.audio.playback` is set. |

| Call | Request | Result |
|---|---|---|
| `POST /speech/recognize` | `input` is `network` or `microphone`. `network` carries WAV, or signed 16-bit little-endian PCM. PCM requires `X-Janus-Rate` (8000–48000) and `X-Janus-Channels` (`1` or `2`). The server resamples to 16 kHz mono and refuses more than 30 seconds. `microphone` requires `seconds`, an integer from 1 to 30, and records that many seconds. | `{"text":"…"}` |
| `POST /speech/synthesize` | `output` is `network` or `playback`. The text is the body field `text`. The voice is `tts.voice`. | WAV, or sound on `playback`. |

Every call sends `Authorization: Bearer` and the `janus.edge.api` token.
A missing or wrong token is `401` and `rejected`. The token is not a
query parameter and is not logged. A second call that takes
`microphone` or `playback` while the first holds it fails. `network`
may run beside it. Audio and text are not stored.

`microphone` and `playback` on `embedded` or `usb` need
`kernelProfile` `standard` or `matched` (D-0061). `compact` still
rejects those devices (D-0057). A call that uses only `network` does
not need kernel sound.

## 1e. `janus.edge.llm`

Not an option. The name is reserved for a later language-model service
on `janus.edge.api`. Ara240 and Hailo-10H are two runtimes for that
role (FR-SVC-002, FR-SVC-003, D-0060). The vendor choice stays under
`llm`. Vision models stay out. CPU speech stays `janus.edge.speech`.

## 2. `janus.hardware`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `board` | enum | — (required) | `rpi-zero-2w` `rpi2` `rpi3` `rpi4` `nanopi-r4s` `rockpi-4c` `le-potato` `visionfive2` `yanyu-stx-r19f` `x86_64-test` |
| `peripherals.<name>.class` | enum | — | `wifi` `nic` `wwan` `bluetooth` `hmi` `power`. A `bluetooth` row selects the dongle driver. BlueZ starts when `janus.audio.playback.output` or `janus.audio.recording.input` is `bluetooth` (D-0061). `recording.input = bluetooth` still fails while HFP and HSP stay off. An Ara240 or Hailo-10H class is later work (*13*, D-0056) and is not an option in this tree. |
| `peripherals.<name>.match` | attrs | — | `usbVendorProduct = "0bda:8153"`, `usbPath` (kernel USB port, such as `1-1.2`), `mac`, or `pciSlot`. Two Wi-Fi sticks of one USB id need a distinct `usbPath` or a distinct `mac` (*10* §4.4, D-0071). `onboard = true` is the radio soldered to the board (*10* §4.7, §4.10, §4.12). |
| `peripherals.<name>.wwan.mode` | enum | `auto` | `auto` uses the mode the allowlist records for that USB ID (*10* §4.2). Explicit values: `ecm` `ncm` `rndis` `qmi` `mbim`. |
| `peripherals.<name>.wwan.modeSwitch` | attrs | `{}` | usb_modeswitch parameters. Empty does not run usb_modeswitch. |
| `peripherals.<name>.wwan.atPort` | str/null | auto | Serial device for AT commands (status only) |
| `peripherals.<name>.hmi.profile` | enum | — | `waveshare-1.3-oled-hat` sets the SH1106 panel, SPI pins, and the key map in *10* §4.6. Behaviour is *15*. |
| `peripherals.<name>.hmi.driver` | enum | from profile | `sh1106` `ssd1306` `st7789` `waveshare-epd-2in13` |
| `peripherals.<name>.hmi.keys.<name>` | enum | profile default | Replace one key's action: `refresh`, `reboot-hold`, `factory-reset`, `unbound`. The joystick stays navigation. |
| `peripherals.<name>.wifi.capabilities` | list | from db | `ap` `sta` `concurrent`. Empty uses the allowlist. A capability outside that list fails evaluation. `concurrent` is an access point and a station on one radio (D-0063, D-0066). |
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
`mode = "wifi"` is a WPA2 station on a peripheral whose profile lists
`sta` (D-0063, FR-NET-018). `wpa_supplicant` associates, then networkd
takes DHCP the same way as `dhcp`. The interface is `wifi-<uplink>`,
in the `wan` zone, and it keeps the dongle MAC. `wifi.networks` lists
`ssid`, one of `passphrase`, `passphraseFile`, or `passphraseSecret`,
and `priority` (default 0, higher first). Open networks, WPA-Enterprise,
a network added without a rebuild, and captive-portal completion are
after 1.0. The other modes are `dhcp`, `static`, `pppoe`, and `wwan`.
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

See *06* §10–11. An access point and a `mode = "wifi"` WAN are the two
roles. One peripheral takes one of them. `wifiCountry` is one ISO alpha-2
code for every access point. Unset, `cn` is `CN`, `ru` is `RU`, and `ir`
is `IR` (D-0054).

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
| `defaultTarget` | selector, `direct`, or `block` | `{}` | `{}` matches every node. *07* §11 |
| `subscriptions.<name>` | submodule | | *07* §3.2 |
| `nodes.<name>` | submodule | | Manual nodes; protocol-specific submodules `vless`, `trojan`, `shadowsocks`, `hysteria2`, `tuic`. `labels.<key>` sets a manual value. |
| `labels.<key>` | submodule | | One declaration per key: `type`, labeling `rules`, and for `enum` a `values` list. *07* §11 |
| `rules` | list | `[]` | Inherited by a LAN that does not set `proxy.rules`. A set LAN list replaces this one. *07* §5, *21*. Empty until written. The example has the `cn`, `ru`, and `ir` lists. |
| `exceptions` | list | private, iptv | `proxy-all` exceptions. A LAN inherits this list. |
| `egressWan` | str/null | `null` | Pin engine egress to a WAN |
| `blockQuic` | bool | `false`; `true` when `janus.system.region` is `ru` | *21* |
| `geodata.refresh` | duration | `"weekly"` | `Nh`, `Nm`, `weekly`, `daily`, `hourly`, or a five-field cron. Day-of-week may be a list such as `2,4,6` (D-0044). |
| `geodata.sources` | attrs | community defaults | Base URLs, plus `tags.<file>` for one rule-set file (*21* §4.3). |
| `geodata.hashes` | attrs of sha256 | `{}` | Overrides the built-in pins. A referenced tag with no pin is left for the router |
| `engineSettings` | attrs | `{}` | Raw engine config merged last (escape hatch; unsupported) |

`vendor`, `protocol`, and `latency` are present on every node. The
operator does not declare `vendor` or `protocol`. `latency` accepts only
`timeout` and `interval`. An unset `defaultTarget` is `{}`, so every node
is eligible. sing-box renders one `urltest` per distinct selector. xray
renders one `leastPing` balancer. The tag stays inside the renderer.
Until that roadmap item, `groups` and `groupsAuto` remain. When it
lands, both are removed. Setting either fails evaluation. There is no
compatibility and no migration. The configuration does not present a
group.

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
secrets/wifi/potato/cafeteria.yaml
secrets/pppoe/potato/main.yaml
secrets/tailscale/potato.yaml
secrets/wireguard/potato/uplink.yaml
secrets/subscription/vendor-a.yaml   # proxy subscription URL
secrets/nodes/manual-a.yaml          # manual proxy-node credential
secrets/web/potato.yaml              # maintenance page passphrase
secrets/soloist/potato.yaml          # Soloist API key, only when janus.soloist.enable
secrets/edge-api/potato.yaml         # janus.edge.api token, only when janus.edge.api.enable
```

`wifi`, `pppoe`, `tailscale`, `wireguard`, `web`, `soloist`, and `edge-api` are encrypted to
that host only. A Soloist file is installed only when `janus.soloist.enable`
is true. The module sets `sops.secrets.<apiKeySecret>.sopsFile` from
`janus.soloist.sopsFile` in that case. A false setting does not. The edge API
token is installed only when `janus.edge.api.enable` is true, from
`janus.edge.api.sopsFile`. A proxy subscription file and a manual proxy-node file
are encrypted to every host that references the file. A PPPoE file and a
manual node file hold the YAML document. The other files hold one value.

`janus-build secret set` writes a sops document encrypted to the
recipients of that path. sops-nix decrypts it into `/run/secrets`. A
one-line credential is the `value` key. A PPPoE file and a manual node
file are the YAML document. The module sets the key for an option that
names the secret: `value` for a Wi-Fi passphrase, a page passphrase, a
Tailscale auth key, a subscription URL, a Soloist API key, and the
`janus.edge.api` token, and the whole document for
PPPoE. The Soloist key is set only when `janus.soloist.enable` is true, from `janus.soloist.sopsFile`. The edge API token is set only when `janus.edge.api.enable` is true, from `janus.edge.api.sopsFile`. A page `passphraseFile`, a PPPoE `passwordFile`, or a WireGuard
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
sops.secrets.wifi-potato-cafeteria.sopsFile = ./secrets/wifi/potato/cafeteria.yaml;
janus.network.wans.cafe.wifi.networks = [{
  ssid = "Cafeteria";
  passphraseSecret = "wifi-potato-cafeteria";
}];
sops.secrets.pppoe-potato-main.sopsFile = ./secrets/pppoe/potato/main.yaml;
janus.network.wans.main.pppoe.passwordSecret = "pppoe-potato-main";
sops.secrets.subscription-vendor-a.sopsFile = ./secrets/subscription/vendor-a.yaml;
janus.proxy.subscriptions.providerA.urlSecret = "subscription-vendor-a";
sops.secrets.tailscale-potato.sopsFile = ./secrets/tailscale/potato.yaml;
janus.remoteAccess.tailscale.authKeySecret = "tailscale-potato";
sops.secrets.web-potato.sopsFile = ./secrets/web/potato.yaml;
janus.access.web.passphraseSecret = "web-potato";
janus.soloist.apiKeySecret = "soloist-potato";
janus.soloist.sopsFile = ./secrets/soloist/potato.yaml;
janus.soloist.enable = true;
janus.edge.api.enable = true;
janus.edge.api.tokenSecret = "edge-api-potato";
janus.edge.api.sopsFile = ./secrets/edge-api/potato.yaml;
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
* Every `target = "group:X"` refers to a defined group or `Auto`.
* Every group has a non-empty membership at build time *or* an
  `emptyFallback`.
* Engine capability check for every node protocol and feature.
* `janus.access.ssh.authorizedKeys != []`.
* `janus.storage`: `/` and `/nix` read-only; exactly one rw partition at `/var`.
* IPv6 `delegated` with traffic mode `rule-based` or `proxy-all` → warning
  unless IPv6 interception is enabled. `bypass` does not warn.
* `janus.hardware.board` is set and supports every declared peripheral class.
* A `wwan` peripheral whose USB ID is not on the allowlist fails evaluation.
* `janus.audio.enable` defaults to false. Playback and recording are read only then. `embedded` and `usb` need a non-blank node and `kernelProfile` `standard` or `matched`. `compact` rejects them. `recording.input = bluetooth` fails while HFP and HSP stay off. `matched` includes the selected embedded or USB driver only when `enable` is true.
* `janus.soloist.enable` needs `janus.audio.enable`, a playback device, the API-key secret and its sops file, at least one zone other than `wan`, and a board architecture of `x86_64`, `aarch64`, or `armv7l`. A false setting skips these checks and does not install the secret. BlueZ starts from `janus.audio` bluetooth, without Soloist (D-0061).
* `janus.edge.api.enable` defaults to false. True needs exactly one of `tokenSecret` and `tokenFile`, a non-empty zone list, and no `wan`. `janus.edge.speech.asr.enable` and `janus.edge.speech.tts.enable` fail while it is false. Recognition fails on the Zero 2 W, the Pi 2, the Pi 3, Le Potato, and the VisionFive 2. Synthesis fails on the Zero 2 W and the VisionFive 2. `tts.voice` is a locked Piper id. `asr.language` is unset or a language id of the locked `base` model (D-0062).
* A Wi-Fi role outside the peripheral profile fails evaluation (D-0063). Without `concurrent`, one peripheral is an access point or a station WAN. With `concurrent`, it may be both (D-0066). A `mode = "wifi"` WAN names a profile that lists `sta`, and each network has one WPA2 passphrase. `0bda:8176` and `0bda:8179` are stations on `rtl8xxxu`. `0bda:818b` and `0bda:f179` are an access point or a station, 2.4 GHz WPA2 HT20. `channel = "auto"` is 6. The image loads `rtl8xxxu`. `0bda:8176` blacklists `rtl8192cu` (D-0070).
* `janus.debug` warns when a switch is on. A `kernelLogLevel` outside 0–7 fails the type. None of them fails evaluation for being on.

## 13. `janus.debug`

Bench switches. Each defaults to off. Turning one on is a rebuild.
A production image leaves the set off. `janus.system.journal.persistent`
stays under `janus.system` (ADR-0013, Q-0070). A capped journal on
`/var` is for a router that has left the bench.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `serialAutologin` | bool | `false` | Log in as root, with no password, on each serial device named by `console=` (`ttyS0`, `ttyS2`, `ttyAMA0`, `ttyAML0`, and the same families). A drop-in inserts `--autologin root` into that instance's NixOS getty line. The template is not replaced. `--keep-baud` stays where NixOS puts it. `tty0` and any other UART keep a login prompt. An image with no serial `console=` warns and does not log in. SSH stays key-only. Anyone who can open that UART gets a root shell. Evaluation warns (D-0067). |
| `initrdShell` | bool | `false` | Root shell on the console when the state check fails. `janus-state-recover` and `janus-state-fsck-full` start `janus-debug-shell.service`, which runs `/bin/sh` only if `/run/janus/state-check-failed` exists. The scripts create that file before the mount probe and before `fsck.f2fs`, and remove it when the device is missing and after `resize.f2fs` returns, so a missing device does not open the shell. A failed resize does. `emergencyAccess` stays off. While this switch is on, a drop-in clears vendor `OnFailure=emergency.target` on `initrd.target` (T-0028). `fsck.f2fs` is on the shell's path. A failed `janus-grow-state` still continues into recover, because recover only wants grow (D-0049, D-0068). |
| `kernelLogLevel` | null or int 0–7 | unset | Kernel console `loglevel`. Unset leaves 4. `7` prints debug. A level above 4 warns (D-0068). |
| `tools` | bool | `false` | Install `tcpdump`, `ethtool`, `iw`, `conntrack`, and `strace`. The base image has none of them (D-0068). |
| `engineLog` | bool | `false` | Write `logLevel` `debug` into the proxy model. sing-box renders `log.level`. xray renders `log.loglevel`. A runtime render reads the same field. Off leaves sing-box at `info` and xray at `warning` (D-0068). |
| `closedFailLog` | bool | `false` | Log packets the closed-fail path drops, at most four lines a second, with the prefix `janus closed-fail `. sing-box keeps the blackhole default in table 2022 and logs `fib daddr . mark type blackhole`. xray logs mark `0x4a02` after the mangle hook, skipping port 53, only while the process is down. Installing the log deletes the table first. The route and the tproxy stay the drop (D-0069, Q-0071). |
