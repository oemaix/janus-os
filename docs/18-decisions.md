# 18 — Decisions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-18 |

A row here is a choice that binds implementation and is not an ADR. The
cited requirement or design section is the text that binds. An accepted
ADR is the record for that choice and is not copied here. Questions that
only explain a choice are *19*.

Each choice is `D-nnnn`. The number is assigned once, in either section,
and it stays when a row moves from Undecided to Decided. A deleted number
is not reused.

Undecided rows are open. Implementation does not invent an answer for them.

## 1. Decided

| # | Choice | Where |
|---|--------|-------|
| D-0001 | One configuration file and a module list are both valid. The fleet template gives each router `hosts/<name>/configuration.nix`. `flake.nix` is the index. Shared modules are `common/default.nix`. | FR-CFG-006, FR-CFG-011, *09* §3 |
| D-0002 | The flake tree that built the image is embedded at `/etc/janus/source`. | FR-CFG-008 |
| D-0003 | Mutable data lives on the `/var` state partition. | FR-STO-004 |
| D-0004 | Traffic modes are `bypass`, `rule-based`, and `proxy-all`. A rule target may be `direct`. | *01*, FR-PRX-020 |
| D-0005 | The computer is a Board. An add-on is a Peripheral. | *01* |
| D-0006 | A cellular module is one `wwan` Peripheral, including one that looks like Ethernet. | *10* §4.2 |
| D-0007 | Wi-Fi dongles are the matrix in *10* §4.3. Drivers are mainline only. | *10* §4.3 |
| D-0008 | IPv6 is a per-LAN policy. The default is `disabled` when tunneling. | *06* §9 |
| D-0009 | Remote access is Tailscale into the `mgmt` zone, SSH only. Advertising routes and an exit node are opt-in. A raw WireGuard peer is optional. Reverse SSH is not a backend. | FR-RA |
| D-0010 | Closed firmware is allowed when the blob is redistributable and required. Out-of-tree drivers are not added to widen support. | FR-HW-006 |
| D-0011 | WWAN is an allowlist. There is no best-effort bring-up. | FR-HW-007 |
| D-0012 | Management in 1.0 is the CLI. A later page covers status, maintenance actions, and hot overrides only. | FR-ACC-005 |
| D-0013 | The OS repository is public. User-facing text is English, then Russian, then Persian. There is no hosted builder. | *00* §9 |
| D-0014 | Backup stores what git cannot recreate: the age key, and overrides that have not been pulled. | FR-OPS-011 |
| D-0015 | `docs/` is the definition suite. `manual/` is the user guide. `llms.txt` points at `ai.md`. | *14*, *16* |
| D-0016 | Tier 1 is Zero 2 W, Le Potato, NanoPi R4S, and Yanyu STX-R19F. Raspberry Pi 4 and Compute Module 4 are Tier 2. | *10* |
| D-0017 | The VLAN model is general. 1.0 implements LAN VLANs. WAN VLAN, the `iptv` role, and IGMP are after 1.0. | FR-NET-005, FR-NET-014, FR-NET-020 |
| D-0018 | A connection audit log is off unless configured, metadata only, on the state partition. `janus audit stop` pauses it without a rebuild. | FR-MON-007 |
| D-0019 | RTL8188CUS is a 2.4 GHz access point on in-tree `rtl8192cu`. | *10* §4.4 |
| D-0020 | The router shuts down on a low cell only while that cell is discharging, and only at the default voltages. | *10* §4.5, FR-HW-008 |
| D-0021 | The Waveshare panel is a Janus HMI profile. | *10* §4.6 |
| D-0022 | Pages and capabilities are one model. Panel size and the keys on the board are profiles. | *15* |
| D-0023 | A shared subscription secret is edited once and pushed with `janus-build fleet apply`. | FR-OPS-012, *16* |
| D-0024 | `fleet apply` prints non-override paths and changes nothing. `--only-overrides` pushes the allowlist only. | *16* §4 |
| D-0025 | The router does not emit Nix. `janus-build fleet pull` writes the repo files. | FR-OPS-008, *16* §5 |
| D-0026 | `janus-build` is the build-host life cycle. A later wizard is a front end for `init`. | *16* |
| D-0027 | `janus` runs on the router. `janus-build` runs on the build host. | *16* |
| D-0028 | The license is Apache-2.0. User-facing text is English, then Russian, then Persian. | `LICENSE`, *00* §9 |
| D-0029 | The Yanyu Janus image uses Limine on legacy BIOS and GPT. The measured OpenWrt install uses GRUB. UEFI and systemd-boot do not apply. | *10* §3.1, *05* §2, *09* §4 |
| D-0030 | Proxied LAN traffic, other than private destinations and traffic to the router, is marked `0x4a01` and looked up in table 2022. The configured IPv6 fake-IP range is not private, and port 53 is not marked `0x4a01`. While the engine is down and `failMode` is `closed`, that table's default is a blackhole. While the engine is up, the default is `dev tun0`. Engine egress stays mark `0x4a` and is not looked up in table 2022. TCP/53 is redirected to `[::]:5353`. UDP/53 is tproxied there with mark `0x4a02`, looked up in table 2023 (`local default dev lo`), including while the engine is down. Refresh SOCKS listens on `127.0.0.1:2080` and the Clash API on `127.0.0.1:9090`. A rule whose target is `direct` because of a domain list is enforced by the engine, so it drops with the engine; the private-range exception is in nftables and stays direct. This row is the sing-box data plane. | ADR-0011, ADR-0016, *07* |
| D-0031 | When `janus.proxy.engine` is `xray`, proxied LAN traffic is not marked `0x4a01` and is not looked up in table 2022. It is tproxied to port 12345 with mark `0x4a02` and table 2023. `failMode = closed` installs that rule while the process is down, so a closed port drops the traffic. `failMode = open` installs it only while Xray is up. `tls.insecure` and a Shadowsocks plugin are not rendered; evaluation fails (ADR-0006). | ADR-0006, *07* |
| D-0032 | Raspberry Pi 400 is not a board. It has no Ethernet jack. The `rpi4` profile is the Pi 4 and the Compute Module 4 on the official IO board. | *10* §3 |
| D-0033 | The maintenance page is *20*. Janet serves it and stunnel terminates TLS. The build option includes it, default off. `janus web stop` pauses the listener. Login is a page passphrase. Light and dark are one monochrome layout. | FR-ACC-006, *20*, ADR-0023 |
| D-0034 | `janus.system.region` is `cn` (default), `ru`, or `ir`. It selects domestic DNS and the `blockQuic` default. Routing rules stay empty until written. The example carries the three lists. It is not a second proxy implementation. `ir` has no built-in domestic resolver. | *21*, FR-PRX-027 |
| D-0035 | `janus.storage.readOnlyFs` accepts `f2fs`, `erofs`, and `squashfs`. The image builder populates f2fs only. `erofs` and `squashfs` fail evaluation. The names stay reserved for a later builder. | *05* §8, *05* §9 |
| D-0036 | An unset WAN metric is 100 plus the WAN index. A backup WAN is 1100 plus the index, so it stays above every default. | *06* §4, *08* §4.3 |
| D-0037 | Fake-IP is the answer for a name the router will proxy. In `rule-based` that is a rule whose target is a group, and the default target when that target is a group. A `direct` rule uses the domestic resolver. A `block` rule is rejected and is not a fake-IP. `proxy-all` uses fake-IP except `exceptions` and `fakeIp.exclude`. `bypass`, and `fakeIp.enable = false`, do not. An explicit proxy rule alone is not the whole set, because unmatched names follow `defaultTarget`. | *07* §7.3, FR-DNS-005 |
| D-0038 | `ipv6Answers` defaults to `strip-for-proxied`. A proxied name must not receive a globally routable AAAA. An address in the configured IPv6 fake-IP range is not a leak. A direct name keeps a real AAAA. `strip-all` strips direct names too. `keep` is the leak. | *07* §7.1, *11* §4.5 |
| D-0039 | A zone has no path to WAN until a firewall policy accepts it. Zones do not forward to each other until a policy accepts that either. Which LAN is proxied, and which DNS policy it uses, is D-0042. | *06* §8, D-0042 |
| D-0042 | Each LAN has `proxy.mode`, `proxy.rules`, `proxy.defaultTarget`, `proxy.exceptions`, and `dns`. Unset, each inherits the router value. A set `rules` list replaces the inherited list. It does not append. Nodes, groups, subscriptions, and `failMode` stay on the router. There is one engine. `bypass` is not intercepted. `rule-based` and `proxy-all` are. `proxied` is not a second switch. Unset DNS follows the mode: `rule-based` is the household split, `proxy-all` answers a proxied name with fake-IP or the remote resolver, and `bypass` sends every recursive name to the domestic encrypted resolvers. A set `dns` has the same shape as `janus.dns` and overrides the inherited fields. `dns.recursive = false` answers only hosts and static leases. A `bypass` LAN that sets fake-IP on, or sets `remote.resolvers`, fails evaluation. A name that the LAN will proxy must not be answered by the domestic resolver. | *07* §5, *07* §7.2, *06* §5, FR-PRX-023, FR-DNS-014 |
| D-0040 | `janus.dns.bootstrap` is a list of IP addresses, used only to resolve DoH and DoT hostnames. Unset, it follows the *21* preset: `cn` is `223.5.5.5` and `223.6.6.6`, `ru` is `77.88.8.8` and `77.88.8.1`, `ir` is empty. An explicit list replaces the preset. The build does not look those hostnames up, and no timer refreshes the list. An encrypted resolver whose host is a name, with an empty list, fails evaluation. | *07* §7.4, *09* §5, *21*, FR-DNS-013 |
| D-0041 | `janus dns check` runs on the router and does not impersonate a LAN client. In `rule-based` and `proxy-all` it probes one domestic name from the region and one foreign name (`example.com`). With fake-IP on, the domestic answer is real and not bogus, and the foreign answer is a fake-IP or a remote answer that is not bogus and did not come from the domestic resolver. `bypass`, and fake-IP off, expect real answers for both, and a foreign answer in `bogusAnswers` fails. China forges plaintext answers on the path. Russia and Iran more often lie in the ISP resolver and block by SNI or address. The preset ships no Russia or Iran bogon list. The command reports and does not change policy. | *07* §7.2, FR-DNS-011, *21* §7 |
| D-0043 | The Raspberry Pi Zero 2 W onboard radio is a 2.4 GHz WPA2 access point on in-tree `brcmfmac` and the redistributable Raspberry Pi wireless firmware. It is declared with `match.onboard = true`. | *10* §4.7, FR-HW-006, D-0010 |
| D-0044 | `janus.proxy.subscriptions.<name>.enable` defaults to true. False drops that subscription from the snapshot, the refresh timer, and the engine on this router. `url` or `urlSecret` stays, so the host still names the secret file and remains a recipient. A cache file `/var/lib/janus/subscriptions/<name>.json` is loaded only when that subscription is enabled in this image. The file stays on disk. A group that names a disabled subscription fails evaluation. `subscriptions.<name>.refresh` and `geodata.refresh` accept a five-field cron whose day-of-month and month are `*`. The day-of-week may be `*` or a comma-separated list. `0` and `7` are Sunday, and `1` is Monday. Those numbers become systemd weekday names. | *07* §3.2, *08* §0, FR-PRX-003, ADR-0022 |

## 2. Undecided

| # | Choice | Where |
|---|--------|-------|
| D-0045 | Open. The board-local secret path may go, so a credential arrives only as a sops name. That path is `janus secrets put` on the router, `janus.remoteAccess.tailscale.authKeyFile`, and `janus.access.web.passphraseFile`. There is no `janus secret set` on the board. `janus-build secret set` on the build host stays. | *14* §2, *08* §9, *08* §11 |
| D-0046 | The seed presets the clash dashboard into `engine/ui` when `janus.proxy.enable` is true (`janus.storage.seedEngineUi`, filled by the proxy module). sing-box 1.13 downloads `external_ui` synchronously at start; on a censored first-boot uplink that download deadlocks the engine before the first subscription refresh, because the proxy group is still empty so even a proxy detour degrades to a direct egress. The manifest records `"ui":"preset"`; the seed generation stays 1 so an already-provisioned router keeps its newer runtime state. Deleting `/var/lib/janus/engine/ui` re-triggers the `engineSettings` download URL as the manual-update channel. | *05* §6, *08* §6 |
