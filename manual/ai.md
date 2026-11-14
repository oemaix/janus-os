# Assistant guide

Read this file before answering a question about using Janus OS.

- The user-facing manual is [en/README.md](en/README.md). Russian and
  Persian copies follow it.
- Definitions, requirements, and option names live in `docs/`. English
  there is canonical. Do not invent `janus.*` options.
- After `host add`, `janus-build secret keygen` prints the age private
  key once. The operator stores it in a password manager. The image
  contains ciphertext and not that key. After boot, `janus-build deploy
  --age-key` or `janus secrets install-age-key` installs it.
  On a terminal, `install-age-key` prints `Paste the age private key, then press Enter and Ctrl-D.` on stderr. A pipe stays quiet. Input with no `AGE-SECRET-KEY-1` line is refused, and the previous key stays.
  `deploy --age-key` probes SSH with stdin closed, then prints that line on a terminal. A failed probe prints nothing and does not read stdin. The key is not an argument and is not stored. The second SSH does not allocate a terminal, so the router command stays quiet on that path.
  `janus.access.deploy.address` is the SSH destination for `deploy`, `fleet apply`, `fleet pull`, `status`, and `backup`. `mkRouter` sets it to the attribute name. A later `hostName` does not move it.
  `janus-build` reads it from the fleet repo when the command runs. `deploy`, `fleet pull`, `status`, and `backup` read an uncommitted edit. `fleet apply` still refuses a dirty tree. A LAN address can be replaced with a MagicDNS name, the Tailscale IPv4, or an IPv6 literal without a new image. A bare IPv6 literal is sent as `root@[address]` (Q-0043).
  `install-age-key` restarts `sops-install-secrets` when that unit
  exists, then a failed PPPoE unit, then a failed `janus-wireguard-secret-<name>`
  and reconfigures `wg-<name>` when that restart succeeds. If that device
  is not there yet, it reloads networkd. Then `janus-wifi-secret-<name>` when
  that unit exists and `janus-hostapd-<name>` failed, then failed Wi-Fi
  units, then `janus-tailscale-auth` and `tailscaled` when either failed,
  then `janus-web-secret` when that unit exists and a page unit failed,
  then `janus-web` and `janus-web-tls`. `janus web start` runs
  `janus-web-secret` or `sops-install-secrets` before it treats a sops
  passphrase as missing. If that install fails, it says the passphrase
  secret could not be installed. A `urlSecret` subscription refresh waits
  for `sops-install-secrets` and still runs when that unit fails, so a hot
  override or a saved URL still applies. A `urlSecret` subscription stays an empty snapshot until
  `janus proxy refresh`. `subscriptions.<name>.enable` defaults to true.
  False on one host drops that subscription's nodes, snapshot, and timer,
  and keeps `url` or `urlSecret` so the host still names the secret file
  (D-0044). `refresh` and `geodata.refresh` accept a five-field cron whose
  day-of-week is `*` or a list such as `2,4,6`. `0` and `7` are Sunday.
  The day-of-month and the month stay `*`. A destination that refuses an
  exit from Iran, China, or Russia is future work (*13*).
- Router commands are `docs/14-cli.md`. Build-host commands are
  `docs/16-build-host-cli.md`. `janus --help` and `janus --usage` print
  the router command list and exit 0. `janus-build --help` and
  `janus-build --usage` print the build-host command list and exit 0.
  An unknown command prints the synopsis on stderr and exits 2.
  `janus-build build` prints the store path
  and links the output directory at `result/<host>`. The image file in
  that directory is `janus-<hostName>.img`. `janus.system.hostName`
  defaults to the fleet host name. `janus.*` options are
  `docs/08-configuration-reference.md`. Phase 1 commands exist, and so
  do proxy, DNS, fleet, status, backup, deploy, and `janus audit`.
  On the board, `janus deploy` exits 2 and names `janus-build`. Hot
  overrides cover an existing subscription URL, a static lease on an
  existing LAN, and an existing Wi-Fi passphrase.
- `janus.system.kernelProfile` is `standard` (default), `compact`, or
  `matched` (D-0051, D-0052). How they are built is
  `docs/23-kernel-profiles.md`. `standard` is the NixOS kernel. `compact`
  drops sound, desktop and 3D GPUs, cameras, industrial I/O, InfiniBand,
  and SAN, and keeps NIC drivers, Wi-Fi, USB, WWAN, MMC, NVMe, AHCI, the
  serial console, and virtio. Raspberry Pi HDMI depends on ALSA and is
  not in `compact`. `matched` includes that cut, then keeps a driver only
  when this board or a declared peripheral uses it. Foreign SoC
  platforms are left out. One vendor stays, and that vendor's other
  chips stay with it. `DRM` stays only on the test VM. An MMC host the initrd
  does not list stays built in. Huawei `12d1:1506` in `ncm` keeps
  `huawei_cdc_ncm`. Sound stays off unless `janus.audio.enable` selects
  an embedded or USB device on `matched` (D-0061). `compact` still drops
  sound. Compute accelerators stay off (D-0057).
- `janus.debug` defaults to off (D-0067, D-0068, D-0069).
  `serialAutologin` logs in as root, with no password, on each serial
  device named by `console=`. A drop-in inserts `--autologin root` into
  that instance's NixOS getty line. The template is not replaced.
  `tty0` and any other UART keep a login prompt. SSH stays key-only.
  `initrdShell` opens `/bin/sh` on the console only when
  `/run/janus/state-check-failed` exists. The state scripts create that
  file immediately before `fsck.f2fs` and remove it when the device is
  missing. `emergencyAccess` stays off. A drop-in clears vendor
  `OnFailure=emergency.target` on `initrd.target` while the switch is
  on (T-0028). `fsck.f2fs` is on that shell's path. A failed grow still
  reaches recover. `kernelLogLevel` is unset or an integer 0–7. Unset
  leaves loglevel 4. A level above 4 warns. `tools` adds tcpdump,
  ethtool, iw, conntrack, and strace. The base image has none of them.
  `engineLog` sets the engine log to debug. sing-box uses `log.level`.
  xray uses `log.loglevel`. The runtime render reads `logLevel` from
  the model. `closedFailLog` logs the sing-box blackhole in table 2022
  and, while xray is down, mark `0x4a02` after the mangle hook. It
  skips port 53. It does not replace that route or that tproxy
  (Q-0071, T-0029). Evaluation warns when a switch is on. Turn
  the set off before an image leaves the bench.
  `janus.system.journal.persistent` stays where it is (ADR-0013). Do
  not invent `janus.debug.firewallTrace`, `janus.engineLog`, or
  `janus.debug.journal`.
- `janus.system.region` is `cn` (default), `ru`, or `ir`. It selects domestic DNS
  and the `blockQuic` default. That reject follows direct rules; it is
  not a drop of every UDP/443. `janus.proxy.rules` stays empty until
  written. The example has the `cn`, `ru`, and `ir` lists. `ir` requires
  `janus.dns.domestic.resolvers`. The region is not a hot override.
- Each LAN inherits `janus.proxy.mode`, `rules`, `defaultTarget`,
  `exceptions`, and `janus.dns` (D-0042). A set `proxy.rules` replaces
  the inherited list. Nodes, labels, subscriptions, and `failMode` stay
  on the router. One engine matches the LAN by source. A rule constrains
  labels (`docs/07-proxy-and-dns.md` §11, ADR-0027, ADR-0028). The
  renderer emits one outbound set per selector. The configuration, the
  maintenance page, the panel, and the CLI do not present a group.
  `janus.proxy.groups` and `janus.proxy.groupsAuto` are not options.
  `bypass` is not
  intercepted; unset DNS then sends every recursive name to the domestic
  encrypted resolvers. `rule-based` is split. `proxy-all` fake-IPs names
  it will proxy. `dns.recursive = false` is hosts and leases only. A
  bypass LAN that sets fake-IP on, or sets `remote.resolvers`, fails
  evaluation. Fake-IP is for a name that LAN will proxy, including the
  default target when that target is a group (D-0037). `ipv6Answers`
  defaults to `strip-for-proxied` (D-0038). `janus.dns.bootstrap` is an
  optional list of IP literals; unset, the region preset supplies it and
  nothing is resolved at build time (D-0040). `janus dns check` probes
  one domestic name and one foreign name per LAN, on the router. It does
  not impersonate a LAN client (D-0041). sing-box renders this per LAN.
  xray 26 routes each LAN by source and applies one shared DNS policy.
  Evaluation fails when the LANs do not share that policy. `listen.lans`
  defaults to `all`: those LANs are told to use the router. `encryption`
  defaults to `prefer`. `domestic.ecs` defaults to `allow` and
  `remote.ecs` to `strip`. The cache holds 4096 answers and sing-box
  writes a 60-second TTL. xray 26 has no cache size or minimum TTL.
  Neither engine attaches a client subnet: sing-box 1.13 disables the
  DNS cache when a query carries one, and xray 26 has no such field.
  Each resolver list queries its first address. sing-box has no DNS
  failover group. xray 26 does not stably match one name on two servers.
  `carrierResolvers = "fallback-only"` is that limit. `domestic-only`
  uses the first learned WAN address. A blocked name is a DNS reject on
  sing-box. xray sends the lookup to a closed port on the router, and
  the client receives the failure. Tell the user to keep `sing-box`
  unless they need xray. Different DNS policies per LAN, including a
  `bypass` LAN beside a `rule-based` LAN, Hysteria2, TUIC,
  `tls.insecure`, a Shadowsocks plugin, or a cache other than 4096 and
  60 all stay on sing-box. xray is for `load-balance` or for xray nodes
  when every LAN shares one DNS policy. `fallback` fails on both engines.
  The choice is `docs/07-proxy-and-dns.md` §2.1.
- `janus.monitoring.audit.enable` defaults to false. With it set,
  `janus audit stop` pauses recording without a rebuild. The log is
  JSON Lines of connection metadata on the state partition.
- `janus.access.web.enable` defaults to false. With it set, and with
  `janus.access.web.passphraseSecret` (one line in
  `secrets/web/<host>.yaml`, encrypted to that host) or
  `janus.access.web.passphraseFile`, the maintenance page listens on
  port 8443 (TLS only) for the zones in `web.zones` (default `lan` and
  `mgmt`). `janus.remoteAccess.tailscale.authKeySecret` is one line in
  `secrets/tailscale/<host>.yaml`. With Tailscale enabled, exactly one of
  `authKeySecret` and `authKeyFile` is set. `janus-build secret set` writes
  a sops document. The fleet sets `sops.secrets.<name>.sopsFile` and the
  janus option. The router decrypts it. `janus web stop` pauses the page without a rebuild. The passphrase
  is not the root password. Compare `janus web fingerprint` with the
  page before typing it. The page is status, maintenance actions, and
  the hot-override allowlist.
- `janus.storage.slots.enable` defaults to false. With it set, deploy
  writes the inactive ROOT and NIX slot and then changes the boot entry.
  The state partition is shared. Confirm with `janus-build deploy --confirm`.
  Each Nix partition is the closure plus 15%, one 4 KiB block per file,
  and 128 MiB, and at least `janus.storage.nix.minimumSize` (default
  `2.5G`). `JANUS_NIX.size` may be smaller than that floor. Without A/B
  slots, 4 GiB holds the image while each Nix partition stays at that
  floor (about 3.3 GiB with no firmware gap). 8 GiB or more is
  recommended. With A/B slots that floor makes an image of about 5.9 GiB,
  so 8 GiB is the minimum and 16 GiB or more is recommended. A larger
  closure needs a larger card by the same amount. A Nix
  image that does not fit the flashed Nix partition makes deploy name
  that partition and stop.
  The flashed state partition is 512 MiB. The first boot grows it to
  `janus.storage.state.maximumSize` (default `4G`) or the end of the
  card. A smaller cap does not shrink. Every boot runs `fsck.f2fs -a`
  and does not scan the volume. `janus.system.reboot.schedule` is off
  unless set to `monthly`, `yearly`, or a five-field cron whose
  day-of-week is `*`. `janus.system.reboot.fsck = true` runs a full
  check on that reboot only. It stops after 30 minutes. Hitting that
  cap fails the boot and does not reformat. The request is removed
  before the check, so a check that does not finish is not repeated
  (D-0049).
- A Waveshare 1.3" OLED HAT on a Raspberry Pi Zero 2 W, a Raspberry Pi 3,
  or a Raspberry Pi 4 is a status panel. It runs `janus proxy refresh`, `janus proxy select`,
  `janus reboot`, and `janus reset --state --yes`. It does not edit
  configuration, hot overrides, or secrets.
- `janus.monitoring.flows.export.collector` exports IPFIX (default, port
  4739) or NetFlow v9. Null leaves export off. The ring is 8192 flows
  in memory.
- `janus.monitoring.flows.export` resolves `janus.monitoring.interfaces`
  (WAN, LAN, port, VLAN, or Wi-Fi names) to kernel interfaces.
- `janus.monitoring.prometheus.enable` defaults to false. When set, port
  9100 serves node exporter and engine metrics on IPv4 and IPv6.
  `prometheus.zones` defaults to `mgmt` and is the only place that port
  is accepted.
- Raspberry Pi 2, Pi 3, Zero 2 W, and Pi 4 images write a hybrid MBR
  over GPT so the boot ROM finds the FAT partition.
- Le Potato (D-0055, docs/10 §3.6) installs `u-boot.gxl.sd.bin` at
  sector 1. Sector 1 stays the firmware. Sector 0 is a DOS table (FAT
  primary, logical filesystems). The backup GPT keeps the PARTUUIDs.
  The kernel command line includes `gpt`. The first boot moves the
  backup to the last sector and leaves sector 1 unchanged.
- StarFive VisionFive 2 (D-0047) uses one GPT image for SD, eMMC, and
  NVMe. The prerequisite is U-Boot 2026.04 already in QSPI, both boot
  pins low. Older firmware is not a boot path. Janus does not write the
  QSPI. The operator follows the U-Boot 2026.04 JH7110 board document:
  <https://docs.u-boot.org/en/v2026.04/board/starfive/jh7110_common.html>.
  The FAT partition holds `u-boot-spl.bin.normal.out` and `u-boot.itb`
  for that procedure. This U-Boot tries eMMC, then the SD card, then NVMe.
- Raspberry Pi 2 v1.1 (`rpi2`) and StarFive VisionFive 2 are Tier 3.
  `janus.build.strategy` defaults to `cross` for them. `lib.mkRouter`
  takes `buildSystem`. Pure evaluation defaults it to `x86_64-linux`.
  `janus-build` on another machine uses that machine's system and refuses
  a mismatch. A Raspberry Pi 2 v1.2 uses the `rpi3` profile. The Pi 3 and
  Pi 3+ SD card is built-in `sdhost`. The boot files are
  `bcm2837-rpi-3-b.dtb` and `bcm2837-rpi-3-b-plus.dtb`. `rpi4` is
  the Raspberry Pi 4 and the Compute Module 4. The Pi 400 is not a board.
- ROCK Pi 4C (`rockpi-4c`) is the v1.2 board (D-0053, docs/10 §3.5,
  §4.10). GPT, mainline U-Boot at sector 64, console `ttyS2` at
  1500000, one `eth0`, no WAN chosen. The boot ROM tries SPI NOR before
  eMMC and SD. The image does not program SPI. Clear SPI, or hold the
  maskrom button, so that U-Boot runs. The serial menu waits two
  seconds: eMMC then SD, or the SD card alone. `match.onboard = true`
  is the AP6256 access point, WPA2, 2.4 GHz or 5 GHz, HT20.
  `janus.network.wifiCountry` defaults from `janus.system.region`
  (`cn` is `CN`, `ru` is `RU`, `ir` is `IR`, D-0054).
  `brcmfmac` stays blacklisted until then. `hci_uart` stays
  blacklisted until `janus.audio.enable` is true and
  `janus.audio.playback.output` is `bluetooth`
  (D-0061, T-0012). ROCK 4C+ is not this profile.
- A mcuzone UPS at I²C `0x40` shows the cell in `janus status` and powers
  the router off while that cell is discharging, at the thresholds in
  docs/10 §4.5. Address `0x43` stays unarmed.
- The Raspberry Pi Zero 2 W onboard radio is a 2.4 GHz WPA2 access point
  (D-0043, docs/10 §4.7). Declare `match.onboard = true` and name that
  access point in the LAN members. 5 GHz and WPA3 fail evaluation.
  The 43436s CLM names are copies of the 43436 blob.
- The Raspberry Pi 3 and Pi 4 onboard radios are the same access point
  (D-0064, docs/10 §4.12, Q-0058). Pi 3 is 2.4 GHz WPA2. Pi 4 and a
  Compute Module 4 with the chip are 2.4 GHz or 5 GHz, WPA2, HT20.
  `match.onboard` is this unit. A Pi 2 v1.2 uses the `rpi3` profile and
  leaves it unset. A Compute Module 4 without the chip does the same
  on `rpi4`. 5 GHz is not the `rpi3` profile.
- The router never evaluates Nix and never runs `nixos-rebuild`.
- The build machine needs Nix with flakes
  (`experimental-features = nix-command flakes`). It does not have to
  be NixOS. The first command is
  `nix run github:oemaix/janus-os#janus-build -- init <dir>`, or
  `nix run <clone>#janus-build -- init <dir>` for a local clone.
  `init` takes the new directory. The flake address is the `nix run`
  target. The fleet records a train branch in `inputs.janus.url` and
  the commit in `flake.lock`. `janus-build update` follows that branch.
  `janus-build update --train <train>` switches train (`main` or
  `MAJOR.MINOR`). Tags are `vMAJOR.MINOR.PATCH`. A bugfix or backport
  is a short-lived `X.Y-<topic>` branch, not a train and not `X.Y-dev`.
- `docs/13-roadmap.md` says what the repository can already
  do. A placeholder module is not a finished feature.
  The NXP Ara240 runtime and the Hailo-10H runtime are future work in
  that file (D-0056). Spotify Soloist and its Bluetooth output are
  implemented as below.
  `janus.audio.enable` defaults to false. Playback and recording are read
  only when it is true. Setting them while it is false fails evaluation.
  `playback.output` and `recording.input` stay unset until chosen:
  `embedded`, `usb`, or `bluetooth`. `embedded` and `usb` need a non-blank
  node. The sink and the source are different strings. `alsa_input.` and
  `bluez_input.` are sources, and so is a `.monitor` name. Other
  `alsa_output.` and `bluez_output.` names are sinks. A number or a custom
  name is not classified. `recording.input = bluetooth` fails while HFP
  and HSP stay off.
  `embedded` is not a device on the NanoPi R4S. `compact` rejects
  `embedded` and `usb`. `matched` includes that device's driver only when
  `enable` is true, and leaves `SOUND` off otherwise. Bluetooth playback
  does not turn kernel sound on. `janus.soloist.playback` is removed.
  `janus.soloist.enable` exists and defaults to false. False adds no unit,
  secret, or package, and its assertions are not evaluated. True needs
  `janus.audio.enable`, a playback device, `apiKeySecret`, `sopsFile`, and
  a board architecture of `x86_64`, `aarch64`, or `armv7l`. True installs
  the locked build and starts Soloist and system-wide PipeWire when
  playback needs a local device. D-0061 starts PipeWire and BlueZ when
  playback or recording is `bluetooth`, without Soloist. The image still
  starts BlueZ only when Soloist is enabled and playback is `bluetooth`.
  `name` is the Connect name and defaults to the host name. `bluetooth`
  is an A2DP source with AVRCP. HFP and HSP stay off. It needs a
  `bluetooth` peripheral or onboard Bluetooth on the Zero 2 W, the Pi 3,
  the Pi 4, or the ROCK Pi 4C. `compact` and `matched` may use it. The
  last connected speaker connects
  again after boot. `janus bluetooth discover` lists nearby devices.
  `list`, `pair`, `connect`, `disconnect`, and `remove` take an address
  or a unique name. A pairing code is optional. The maintenance page
  discovers, then pairs, and has the same section when the
  page is in the image (D-0059, D-0061). UDP 5353 is opened on `zones`
  (default `lan`). The WebSocket stays off. Any other architecture fails
  evaluation.
  The archives are flake inputs `soloist-x86_64`, `soloist-aarch64`, and
  `soloist-armv7l`. Bump them with `nix flake update`. Do not vendor the
  archive and do not add an unpinned fetch (D-0058, T-0010). The API key
  stays out of the unit file in the store. The accelerator service is not
  an option. The planned accelerator model is an LLM of 0.5B to 3B
  parameters. Vision models are not in that plan. The Hailo device is the
  Hailo-10H, not a Hailo-8 (D-0060). `compact` still drops
  kernel sound. Compute accelerators stay off. `matched` sound is only
  the `janus.audio` device (D-0061). Do not invent an accelerator class.
  CPU speech is in the image when its switches are on, and both default
  off (D-0062, UC-25,
  FR-SVC-004). `janus.edge.api.enable` defaults to false. `janus.edge.speech.asr.enable`
  and `janus.edge.speech.tts.enable` are separate and fail evaluation while
  the listener is off. They share its port `8473` and its sops token.
  The token file is `secrets/edge-api/<host>.yaml`, one `value` line,
  encrypted to that host (FR-SEC-013). The sops name is `edge-api-<host>`.
  The listener is not the maintenance page. A call sends `Content-Length`.
  Chunked transfer encoding is refused. The token is checked before the
  body is read. Four calls may be in flight. Network audio is WAV, or
  signed 16-bit PCM with `X-Janus-Rate` and `X-Janus-Channels`. A
  microphone call sends `seconds` from 1 to 30. Recognition is a released
  `whisper.cpp` and the multilingual `base` weights. Synthesis is a
  released Piper from https://github.com/OHF-Voice/piper1-gpl.
  `tts.voice` is a locked id `ll_CC-name-quality`. `asr.language` is
  unset or a language id of that `base` model. Recognition fails on
  `rpi-zero-2w`, `rpi2`, `rpi3`, `le-potato`, and `visionfive2`.
  Synthesis fails on `rpi-zero-2w` and `visionfive2`. The accelerator
  does not run speech. `janus.edge` is a namespace and has no switch.
  `janus.edge.llm` is not an option yet. Do not invent an option outside
  *08* §1c, §1d, and §1e.
