# 13 — Roadmap

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-04 |

This file is the implementation plan, the progress of the code, and the
notes for work that is specified but not started. Choices are *18*.
Explanations are *19*. Implementation tarpits are *22*. Accepted ADRs
are `docs/adr/`.

## 1. Phased roadmap

1.0 is every Tier 1, Tier 2, and Tier 3 board in *10* and every
peripheral marked supported there (D-0046). The phases below are the
order the work landed. Tier 1 remains the release-blocking boot and
power-cut. Tier 3 ships the profile. The Future list stays after 1.0.

### Phase 0 — Foundations (repo skeleton)

* Flake, `mkRouter`, `x86_64-test` board, module skeleton with option
  types and assertions, options-doc generation, CI for eval tests.
* CLI specified in *14* and *16* before the commands are implemented.
* Storage: partition model, read-only root via `/etc` overlay, image
  builder with f2fs + FAT, VM boot test.

### Phase 1 — Router core (MVP, no proxy)

* LAN VLANs, WAN `dhcp`/`static`/`pppoe`, multi-WAN roles `default` /
  `backup` / `custom`, LANs with DHCPv4 + static leases, zone firewall,
  NAT, port forwards, IPv6 modes `disabled`/`ula-only`/`delegated`.
* SSH key-only, `janus` CLI as specified in *14*.
* `janus-build init`, `secret`, `check`, `build`, and `update` (*16*).
* sops-nix and age for every credential in FR-SEC-002: PPPoE, Wi-Fi, a subscription URL, a manual node, WireGuard, the Tailscale auth key, and the maintenance-page passphrase.
* Boards (Tier 1): NanoPi R4S, Raspberry Pi Zero 2 W, Le Potato,
  Yanyu STX-R19F. 
* Monitoring: counters + vnstat. The connection audit is FR-MON-007.

### Phase 2 — Circumvention

* Canonical node model, Janet normalizer (share links, Clash, sing-box),
  matchers (regex, glob, PEG), groups, rules, traffic modes.
* sing-box renderer, TUN interception v4+v6, fail-closed.
* DNS policy layer (split, encrypted, fake-IP, carrier-resolver policy,
  plaintext interception).
* Build-time snapshot, runtime refresh with rollback, Geo data pipeline.
* Example configuration templates (regions, usages).
* VMess in the canonical model. Hot override for an existing subscription URL.
* `janus-build fleet`, `status`, and `backup` (*16*, FR-OPS-012).
* `janus dns check`.

### Phase 3 — Breadth

* Xray renderer with capability assertions.
* WWAN peripherals (ECM/NCM/RNDIS, QMI/MBIM), backup WAN failover.
* Wi-Fi AP peripherals.
* Remote access: Tailscale into the `mgmt` zone. Optional WireGuard to a user endpoint. No reverse SSH.
* Boards: RPi 3 (Tier 2).
* Hot overrides for static leases and Wi-Fi passphrase.
* Remote closure deployment (`janus-build deploy`).

### Phase 4 — Polish

* HMI daemon. The interaction model is *15*. The first profile is the Waveshare 1.3" OLED HAT (*10* §4.6). Implemented; see Progress.
* Flow export (IPFIX) and a Prometheus endpoint. Implemented; see Progress.
* VisionFive 2, RPi 2 (Tier 3). Implemented; see Progress.
* A/B image slots. Implemented; see Progress.
* Maintenance page limited to status, maintenance actions, and hot overrides (*20*). Implemented; see Progress.
* Operator manual in English, Russian, and Persian: build, flash, deploy, audit, A/B slots, the status panel, the maintenance page, Tier 3 boards, flow export, and the Prometheus endpoint. Implemented; see Progress.

### Future

* WAN VLAN, the `iptv` role, and IGMP proxy (*06*, FR-NET-003, FR-NET-020).
* Optional local configuration wizard, a front end for the build-host commands in *16*. No hosted build service.
* A check that a destination refuses the exit because the address is in Iran, China, or Russia, for example Gemini. A country guessed from the node name, and a connect check (ping, TCP, or a handshake), do not show that refusal.
* One GPIO LED with the `heartbeat` trigger on `rpi2`, `rpi3`, `rpi4`, `rpi-zero-2w`, `rockpi-4c`, and `le-potato`. A dark LED then means the kernel timer has stopped. The GPIO is not chosen. The ROCK Pi 4C blue status LED already uses that trigger in the device tree (*10* §3.5). The Le Potato blue LED does the same in the mainline tree and is not yet recorded in *10*. The Raspberry Pi profiles do not set one.
* The maintenance page (*20*) is in the image. The retro console in *20* §7 is the design: no radius, no shadow, no gradient. Some functions and elements are still unusable or only partly worked out. Later work keeps that simple console and works out every function and every element so each behaves clearly and fluidly. The shape is in Notes.
* Spotify Soloist as a playback device (*02* UC-23, FR-SVC-001). `janus.soloist.enable` defaults to false. False adds no unit, secret, or package, and the checks are not evaluated. True needs `janus.audio.enable`, a playback device, the API key as a sops secret for that router (FR-SEC-012), and a board architecture of `x86_64`, `aarch64`, or `armv7l`. Playback is `janus.audio` (D-0061). The image installs the locked official build and starts Soloist with system-wide PipeWire when playback needs a local device. UDP 5353 is accepted on `janus.soloist.zones` (default `lan`) and dropped elsewhere. The WebSocket stays off. Pairing is `janus bluetooth` and the maintenance page (D-0059). The archives are flake inputs (D-0058, T-0010). A 1.0 image leaves the switch false.
* Shared audio (`janus.audio`, D-0061). `enable` defaults to false. Playback and recording are read only when it is true. `embedded` and `usb` need a non-blank PipeWire node and `kernelProfile` `standard` or `matched`. `compact` still rejects them (D-0057). `matched` includes that device's driver only when `enable` is true, and leaves `SOUND` off otherwise. `recording.input = bluetooth` fails while HFP and HSP stay off. PipeWire starts for Soloist, for speech on a local device, and for bluetooth playback or recording. BlueZ starts when playback or recording is `bluetooth`, without Soloist.
* Bluetooth audio output of that playback (*02* UC-23, FR-HW-009). The router is the Spotify Connect device. `janus.audio.enable` and `janus.audio.playback.output = bluetooth` start BlueZ as an A2DP source with AVRCP, without Soloist (D-0061). HFP and HSP stay off. The last connected speaker connects again after boot, and again when it returns, unless it was disconnected during this boot. `janus bluetooth` discovers nearby devices, then lists, pairs, connects, disconnects, and removes them by address or by a unique name. A pairing code is optional. The maintenance page discovers, then pairs, and has the same later actions when that page is in the image (FR-ACC-007, D-0059). The CSR dongle `0a12:0001` stays allowlisted. Onboard Bluetooth on the Zero 2 W, the Pi 3, the Pi 4, and the ROCK Pi 4C is included for `compact` and `matched` when this playback is set. `hci_uart` on the ROCK Pi 4C stays blacklisted until then.
* Shared HTTP listener and CPU speech (*02* UC-25, FR-SVC-004, D-0062). `janus.edge.api.enable` defaults to false. False adds no listener, certificate, or token. Recognition and synthesis are separate switches and share that listener, its port `8473`, and its sops token. Either fails evaluation while the listener is off. Recognition is released `whisper.cpp` and the multilingual `base` weights. Synthesis is released Piper from <https://github.com/OHF-Voice/piper1-gpl>, with `tts.voice` a locked id `ll_CC-name-quality`. Pins are release tags in `flake.lock` (T-0020). Recognition fails on the Zero 2 W, the Pi 2, the Pi 3, Le Potato, and the VisionFive 2. Synthesis fails on the Zero 2 W and the VisionFive 2. The switches are in the image and default off, so a 1.0 image does not start them. `janus.edge` is the namespace and has no switch. `janus.edge.llm` is the later name for the language-model service and is not an option yet.
* NXP Ara240 runtime (*02* UC-24, FR-HW-010, FR-SVC-002). Another device calls `janus.edge.api` on the router when it needs an edge LLM of 0.5B to 3B parameters (D-0060, D-0062). The HTTP face is the vendor Chat Completions service (eIQ AAF Connector) in front of AraRT. Zones default to `lan` and `mgmt`. `wan` is refused. AraRT's own socket stays on the board. No board and no USB or PCI ID is accepted yet. The published client library name is `libaraclient_aarch64.so`. Other architectures are not assumed (D-0058). Vision models are out. Speech stays on the CPU.
* Hailo-10H runtime (*02* UC-24, FR-HW-011, FR-SVC-003, D-0060). Same role and the same model size as the Ara240 row. The module is PCIe, M.2, with its own DRAM. HailoRT is the `master` branch. The HTTP face is HailoRT GenAI, compatible with OpenAI and Ollama, on `janus.edge.api` (D-0062). Hailo-8 and Hailo-8L are not this row. No PCI ID is accepted yet. Vision models are out. Speech stays on the CPU. Hailo's published example is about 2B parameters. 3B is the top of this plan and is not that example.
* Open Wi-Fi, WPA-Enterprise, a station network added on the router without a rebuild, and captive-portal completion (*06* §11, FR-NET-018, D-0063).

## 2. Progress

The definition suite still describes the system to build. A file in the
tree does not mean that behavior exists. Stubs are not finished features.

### Done

* `janus.system.kernelProfile` is `standard` (default, the NixOS kernel),
  `compact`, or `matched` (D-0051, D-0052). `compact` is one config for
  every board. `matched` includes that cut, then keeps a driver only
  when this board or a declared peripheral uses it. An MMC host the
  initrd does not list stays built in, including the Pi 3 and Pi 3+
  SD card.
* Apache-2.0 license at the repository root.
* Flake with `nixosModules.janus`, `nixosModules.boards`, `lib.mkRouter`,
  `templates.default`, and `devShells.default` (`nix develop`).
* `lib.mkRouter` reads `janus.hardware.board` and returns a NixOS
  configuration, including `system.build.janusImage`. Implemented boards
  are `x86_64-test`, `yanyu-stx-r19f`, `nanopi-r4s`, `rockpi-4c`, `le-potato`,
  `rpi-zero-2w`, `rpi3`, `rpi4`, `rpi2`, and `visionfive2`. It
  does not return an empty configuration. `armv7l` and `riscv64` default
  to a cross build (`janus.build.strategy`).
* `janus.*` option types, defaults, and the structural assertions in
  *08* §12. Storage is lowered: partition labels, read-only `/` and
  `/nix`, one read-write `/var`, and `system.etc.overlay` with
  `mutable = false`. `JANUS_STATE` grows to at most `state.maximumSize`
  (default 4 GiB). Boot runs `fsck.f2fs -a --no-kernel-check`. A full
  check runs only on the maintenance reboot with `janus.system.reboot.fsck`
  (D-0049).
* `janus.network` lowers ports, LAN VLANs, WAN `dhcp`/`static`/`pppoe`,
  LAN bridges, DHCPv4, and the IPv6 modes into networkd, pppd, and
  dnsmasq. `janus.firewall` lowers zones, NAT, and port forwards into
  nftables. OpenSSH is key-only. vnstat keeps interface counters.
* `janus` and `janus-build` implement the phase 1 commands in *14* and
  *16* (`init`, `host add`, `secret keygen`, `secret set`, `check`,
  `build`, `update`, and the router status commands). `--help` and
  `--usage` print that command list and exit 0. The age private
  key path is `/var/lib/janus/secrets/age.key`. sops-nix decrypts to
  `/run/secrets` at activation. Every credential in FR-SEC-002 is one
  sops file from `janus-build secret set`: one-line credentials under
  the `value` key, and a PPPoE file or a node file as YAML. Wi-Fi,
  the maintenance page, Tailscale, a subscription URL, and PPPoE name
  that secret, and the module sets its key. `janus-wifi-secret-<name>`
  waits for `sops-install-secrets` and passes when that file or the hot
  override `/var/lib/janus/secrets/wifi-<name>` is non-empty. A failed
  sops unit does not hide the override. `janus-hostapd-<name>` waits for
  that check and uses the override when it is present. A subscription
  refresh reads the hot override, then the sops URL, then the saved URL.
  `janus-web-secret` checks the page passphrase and waits for
  `sops-install-secrets`. `janus web start` runs that
  install before it tests the file. A PPPoE password file, a WireGuard
  private-key file, or a manual-node password file that is a sops path
  waits for the same install. The module sets `key` to `value` for that
  PPPoE file, the WireGuard key, and a page passphrase file, and to `""`
  for the node file. A key set in the fleet wins. WireGuard stays a file
  path. A missing WireGuard key does not fail `systemd-networkd`. That
  interface stays down until `install-age-key` reconfigures `wg-<name>`.
  `secret rewrap` is not implemented.
* Board profiles: `x86_64-test` (virtio, no raw firmware), NanoPi R4S
  (U-Boot at sector 64, `eth0`/`eth1`, no WAN chosen, port LEDs follow
  the silkscreen jacks, the SYS LED heartbeats, *10* §3.2), Le Potato (U-Boot
  FIP from `u-boot.gxl.sd.bin` at sector 1, DOS table and backup GPT,
  D-0055, one `eth0`), Raspberry Pi Zero 2 W (FAT `config.txt`, no Ethernet
  port), Raspberry Pi 3 / 3+ (`rpi3`, FAT `config.txt`, hybrid MBR, one `eth0`,
  onboard access point when `match.onboard` is set, 2.4 GHz WPA2,
  D-0064),
  Raspberry Pi 4 and Compute Module 4 (`rpi4`, FAT `config.txt`, hybrid
  MBR, one `eth0`, onboard access point when `match.onboard` is set,
  2.4 GHz or 5 GHz WPA2, D-0064; a CM4 without the chip leaves it unset;
  the Pi 400 is not a board),
  Raspberry Pi 2 v1.1 (`rpi2`, 32-bit, hybrid MBR, one `eth0`; a v1.2
  uses `rpi3`), and StarFive VisionFive 2 (U-Boot from QSPI, one GPT
  image for SD, eMMC, and NVMe, boot order eMMC then SD then NVMe,
  `eth0`/`eth1`, no WAN chosen, D-0047), and ROCK Pi 4C (`rockpi-4c`,
  v1.2, U-Boot at sector 64, one `eth0`, no WAN chosen, serial menu
  for eMMC then SD, onboard AP6256 access point when `match.onboard`
  is set, D-0053). The regulatory country follows the region unless
  `janus.network.wifiCountry` is set (D-0054). The ROCK Pi 4C image has not been booted on the lab unit.
  Yanyu names `lan1`–`lan4` by PCI path and installs Limine
  (D-0029). The image has not been booted on the lab AMI board. Tier 3
  images are not boot-tested here.
* The Raspberry Pi Zero 2 W onboard radio is a 2.4 GHz WPA2 access
  point (D-0043). `match.onboard = true`. `hostapd` uses in-tree
  `brcmfmac` and `raspberrypiWirelessFirmware`. The NixOS arm64 config
  answers `MMC_SDHCI_IPROC=m`. A Zero 2 W or Pi 3 access point keeps
  that module. The Pi 3 profile pins `n` until `match.onboard` declares
  the access point. The Pi 4 profile pins `y`, because the initrd does
  not list `sdhci_iproc`.
  The boot tree is mainline `bcm2837-rpi-zero-2-w.dtb`. The 43436s
  CLM names are copies of the 43436 blob that package already ships.
  The Pi 3 and Pi 4 radios are the same access point (D-0064, *10*
  §4.12). Pi 3 is 2.4 GHz. Pi 4 is 2.4 GHz or 5 GHz. A Pi 2 v1.2 leaves
  `match.onboard` unset. The Pi 3 boot trees are mainline
  `bcm2837-rpi-3-b.dtb` and `bcm2837-rpi-3-b-plus.dtb`.
* Image builder: GPT, FAT boot, f2fs root, f2fs store, f2fs state.
  `nix build .#checks.x86_64-linux.vm-x86_64-test` boots that image.
* Options reference: `nix build .#docs-options`.
* Eval checks under `checks.<system>.eval-*`, and CI for those checks
  plus the options document.
* `janus-build` and `janus` binaries in the dev shell.
* User-facing text: root `README.md` and `manual/` in English, Russian,
  and Persian, in that order, plus `manual/llms.txt` and `manual/ai.md`.
* `janet/janus.janet` normalizes share links, Clash, and sing-box, matches
  with regex, glob, and PEG, and renders sing-box or Xray. The image
  build runs `sing-box check` or `xray run -test`.
* `janus.system.region` is `cn` (default), `ru`, or `ir` (*21*, D-0034). It
  selects domestic DNS and the `blockQuic` default. `janus.proxy.rules`
  stays empty until written. The example has the three lists. With the
  proxy enabled, `ir` requires `janus.dns.domestic.resolvers`.
* `janus.proxy.enable` installs the selected engine and redirects LAN DNS
  to it. sing-box marks proxied LAN traffic into table 2022 (D-0030).
  Xray tproxies that traffic to port 12345 (D-0031).
* Subscription refresh, Geo data download, and hot overrides for an
  existing subscription URL, a static lease on an existing LAN, and an
  existing Wi-Fi passphrase. `janus dns check` reports and does not
  change policy. `janus-build fleet`, `status`, `backup`, and `deploy`
  are the build-host commands in *16*.
* WWAN Ethernet modes are DHCP clients. QMI and MBIM run `qmicli` or
  `mbimcli` before networkd (ADR-0015). A backup WAN can fail over when
  its health targets fail.
* Tailscale and optional WireGuard join the `mgmt` zone. There is no
  reverse SSH.
* Connection audit (FR-MON-007) records metadata as JSON Lines on the
  state partition when `janus.monitoring.audit.enable` is set. `janus audit`
  starts and stops recording without a rebuild.
* `janus.storage.slots.enable` duplicates `ROOT` and `NIX`. `janus-build
  deploy` then writes the inactive slot and toggles the boot entry (*09* §8.4).
* The Waveshare 1.3" OLED HAT on `rpi-zero-2w`, `rpi3`, or `rpi4` is a status
  panel (*15*, *10* §4.6). It runs `janus proxy refresh`, `janus proxy
  select`, `janus reboot`, and `janus reset --state --yes`. It does not
  edit configuration, hot overrides, or secrets.
* `janus.access.web.enable` includes the maintenance page (*20*). It is
  off unless set. `janus web stop` pauses the listener without a rebuild.
  Login is a per-host sops passphrase (`secrets/web/<host>.yaml`), not the root password. The page calls the
  allowlisted `janus` commands and does not edit the rest of the configuration.
  Some functions and elements are still unusable or only partly worked out. Working those out inside the retro console is Future.
* `janus.edge.api.enable` is the shared listener on port 8473. Recognition and
  synthesis are separate switches on that listener (D-0062). Both default
  off. `janus.audio.playback.output = bluetooth` starts BlueZ and PipeWire
  without Soloist (D-0061).
* A mcuzone INA219 at `0x40` reports the cell in `janus status` and powers
  the router off while the cell is discharging, at the thresholds in *10*
  §4.5. The Waveshare address `0x43` stays unarmed.
* `janus.monitoring.flows.export.collector` runs softflowd. `ipfix` is
  NetFlow version 10 and `netflow9` is version 9. The in-memory ring holds
  8192 flows. `janus.monitoring.interfaces` names WANs, LANs, ports, VLANs,
  or Wi-Fi networks, and flow export resolves them to kernel interfaces.
  `janus.monitoring.prometheus.enable` serves node exporter on port 9100
  for IPv4 and IPv6, plus engine metrics in the textfile collector. That
  port is accepted only on `prometheus.zones` (default `mgmt`) and dropped
  on every other interface.
* `eval-proxy-local` fetches a page on `127.0.0.1` through the rendered
  sing-box Shadowsocks outbound. The fixture server speaks the same method
  and password. The router's firewall mark is not applied on that hop.
* `vm-x86_64-net` boots the `x86_64-test` image with a WAN and a LAN. A
  second guest takes a DHCPv4 lease, reaches a host service through NAT,
  receives `vm.test` from the engine, reads the SSH banner on the LAN, and
  cannot open SSH on the WAN. The mount check remains `vm-x86_64-test`.

## 3. Notes for later implementation

* Accepted ADRs bind. They are listed in `docs/adr/` and are not restated here.
* Undecided choices, if any, are *18* §2. Do not invent an answer for one.
  D-0045 asks whether the board-local secret path goes away.
  D-0048 asks whether an existing PPPoE username and password join the
  hot-override allowlist.
  D-0057 stays open for `compact` embedded and USB audio, and for Ara240 and Hailo-10H. `matched` includes the embedded or USB driver when `janus.audio.enable` is true (D-0061). Bluetooth A2DP is D-0061.
  D-0058 records the Soloist download and still asks how Ara240 and Hailo-10H reach an operator image.
* sing-box renders D-0037 through D-0042: fake-IP for names that LAN
  will proxy, `strip-for-proxied` per name, one policy per LAN, region
  bootstrap addresses, and `janus dns check` once per LAN. xray 26 routes
  each LAN by source and uses the same DNS decision for one shared policy.
  A household whose LANs do not share that DNS policy fails evaluation.
  `listen.lans` defaults to `all` and is DHCP option 6 plus RA DNS.
  `encryption` defaults to `prefer`; `require` accepts only DoH, DoT, and
  DoQ for client resolvers.   `domestic.ecs` defaults to `allow` and `remote.ecs` to `strip`. Neither
  engine attaches a client subnet. sing-box 1.13 disables the DNS cache
  for any query that carries one, and xray 26 has no client-subnet field.
  `cache.size` defaults to 4096 and `cache.minTtl` to 60. sing-box uses
  those as capacity and as the TTL it writes. xray 26 has neither knob,
  so another value fails evaluation. Each resolver list queries its first
  address. sing-box has one server per DNS rule and no failover group.
  xray 26 does not stably match one name on two servers. `fallback-only`
  is that limit and does not add a carrier server. `domestic-only` puts
  the first learned WAN address in front of the domestic list. A delegated
  RA names the IPv6 link-local. Which engine to keep, including different
  DNS policies per LAN, is *07* §2.1.
* The Yanyu profile names `lan1`–`lan4` by PCI address (*10* §3.1). It
  does not pick which jack is WAN. Limine on that image has not been
  booted on the lab AMI board.
* Battery shutdown arms on the mcuzone `0x40` profile, where a
  negative current means discharge. The Waveshare `0x43` profile stays
  unarmed.
* The CSR Bluetooth dongle `0a12:0001` stays on the allowlist. The image
  starts BlueZ and PipeWire when `janus.audio.enable` is true and
  `janus.audio.playback.output` is `bluetooth`, without Soloist (D-0061).
  `recording.input = bluetooth` still fails while HFP and HSP stay off.
  Board audio and a USB interface are the other two playback devices.
  CPU speech is in the image when `janus.edge.api.enable` and
  `janus.edge.speech.asr.enable` or `janus.edge.speech.tts.enable` are set. Both
  speech switches default off (D-0062).
* `janus.system.kernelProfile` is `standard`, `compact`, or `matched`
  (D-0051, D-0052). `standard` and `compact` are one kernel for every
  board. `standard` is the default and is the NixOS kernel, so aarch64
  and x86_64 keep the binary cache. `compact` drops a subsystem only
  when no household router board, current or later, has a use for it.
  The symbols are `modules/janus/system/kernel-profile.nix` and
  `kernel-matched.nix`. Sound,
  desktop and 3D GPUs, compute accelerators, cameras and TV, HDMI-CEC
  and infrared remotes, industrial I/O and Comedi, InfiniBand, and SAN
  go. NIC drivers stay, including ones no current board uses. Wi-Fi,
  USB, WWAN, Bluetooth, MMC, the NVMe host, AHCI, f2fs, vfat, virtio,
  simpledrm, and SoC scanout that does not depend on ALSA stay.
  Raspberry Pi HDMI (VC4) depends on ALSA, so it is not in `compact`.
  `matched` turns `SOUND` back on only when `janus.audio.enable` selects
  `embedded` or `usb`, and then only that device's driver. `DRM_VC4`
  stays off. Bluetooth playback does not turn sound on (D-0061, T-0018).
  The board consoles are serial. On the
  riscv64 6.18.54 NixOS kernel the sound, GPU, camera, industrial I/O,
  SAN, and InfiniBand trees were 13 616 of 22 886 compiler invocations,
  about 59 %, and about half of a 64-minute build phase at `-j20`.
  `compact` keeps the small SoC scanout drivers inside the GPU tree, so
  that share is an upper bound. The flashed image already ships the
  shrunk module set, so current boards do not gain storage from
  `compact`. The compile-time cut matters while kernel patches still
  force a rebuild, and on riscv64 and armv7l, which have no cache.
  `matched` keeps a driver only when this board or a declared peripheral
  uses it (D-0052). Spotify Soloist audio, the Ara240
  runtime, and the Hailo-10H need sound or a compute accelerator. `compact`
  drops both.
  Whether a later image that enables one of them must set `standard`, or
  whether `compact` keeps those subsystems when the service is on, stays
  open (D-0057). Until that row is decided, those services are not built.
* Spotify Soloist is the playback program documented at
  <https://developer.spotify.com/documentation/soloist>. The API key
  starts the daemon. The WebSocket has no authentication and stays on
  loopback. AraRT is the NXP runtime for the Ara240 DNPU (UM12562,
  UG10166). The HTTP face other devices call is the eIQ AAF Connector.
  The router does not have to be an i.MX board. The DNPU attaches over
  PCIe or USB. The Hailo device is the Hailo-10H (D-0060), PCIe M.2.
  HailoRT for it is the `master` branch of
  <https://github.com/hailo-ai/hailort>, which covers Hailo-10 and
  Hailo-15. The `hailo8` branch is not this plan. LLM deployment is
  <https://hailo.ai/blog/bringing-generative-ai-to-the-edge-llm-on-hailo-10h/>.
  The planned model on both accelerators is an LLM of 0.5B to 3B
  parameters. Vision models are not in the plan.   Speech recognition is
  published for the Hailo-10H (Whisper `base`, `tiny`, and `tiny.en`)
  and Optimum-Ara includes `whisper.py`. Neither is this workload.
  CPU recognition and synthesis are D-0062: released `whisper.cpp`
  with the multilingual `base` weights, and released Piper. Speech
  synthesis is not an accelerator model: Hailo runs Piper on the host
  CPU, and NXP's VITS TTS is documented for i.MX NPUs.
* The station uplink (D-0063, FR-NET-018, *10* §4.11) is specified and not
  lowered. The allowlist has no `0bda:8179`. An access point on
  `0bda:8176` still blacklists the `rtl8xxxu` module. The definition
  assigns `rtl8192cu` to that ID only and leaves `rtl8xxxu` loaded for
  the station stick.
* The board image must not contain a compiler or `janus-build`. The `nix`
  binary stays for activation and for `nix-store --import` (*05*, *09*
  §8.2). `nix.enable = false`, nixpkgs sources are absent, and `/nix` is
  read-only except during that deploy, so the board does not evaluate.
  The dev shell is only for the build host.
* No MCP server is included. One would only repeat `janus-build` before
  that program exists, and a stub that returned invented data would be
  worse than no server.
* The maintenance page (*20*) listens, logs in, and runs the allowlisted
  commands. The retro console is the intended design: one column, one
  geometry for light and dark, and no radius, shadow, gradient, icon,
  or webfont. The page stays that simple. Some functions and elements
  are still unusable or only partly worked out. Later work keeps the
  console and considers every function and every element already on
  the page, until each behavior is clear and fluid. It does not replace
  the console with another style, and it does not add a control *20*
  leaves out.

## 4. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| NixOS read-only `/etc` overlay still maturing | boot issues on some releases | pin release; VM test; fallback to tmpfs `/etc` with copied tree |
| f2fs population without root in Nix sandbox (`sload.f2fs`) has edge cases (xattrs, symlinks) | broken images | golden tests mounting images in VM; erofs fallback for ro partitions |
| Emulated aarch64 builds are slow for user changes | poor UX | rely on binary cache; document native/cross options; keep Janus-specific packages tiny |
| Engine upstream churn (sing-box config format) | renderer breakage | pin engine version per release; golden tests |
| Subscription providers' formats vary wildly | parse failures | normalizer test corpus; `format` override; permissive parsing with warnings |
| armv7l/riscv64 without cache | hours-long builds | Tier 3, clearly labelled |
| Closed Soloist binary, Ara240 runtime, and Hailo-10H firmware | license, redistribution, image size | Soloist is downloaded for three architectures when enabled, and the pin expires (D-0058, T-0010). Ara240 and Hailo-10H are not vendored |
