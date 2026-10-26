# 19 — Questions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-26 |

These answers explain a choice that already binds somewhere else. The
cited ADR, requirement, or section is that place. This list does not
add a second statement of the choice. Choices that are not ADRs are *18*.

Each question is `Q-nnnn`. The number is assigned once and is not reused.

| # | Question | Answer |
|---|----------|--------|
| Q-0001 | Why embed the whole flake tree, not only `configuration.nix`? | Modular configs import by relative path, and a rebuild needs the lock file. Files outside the tree are not captured. See D-0002. |
| Q-0002 | Can subscription updates go through `nixos-rebuild` on the board? | No. Changes are maintenance actions, hot overrides, or a rebuild on the build host. See ADR-0017. |
| Q-0003 | Why not reuse NetworkManager profiles? | NetworkManager is built for a host, not for router zones. Janus lowers to networkd and nftables. See ADR-0004. |
| Q-0004 | Which DNS policies can a user ask for, and what is `forwarders`? | Unset, a LAN inherits `janus.dns` and its mode picks the unmatched path. A set `dns` overrides those fields. `recursive = false` answers only hosts and leases. `forwarders` stays a per-domain upstream. See D-0042. |
| Q-0005 | Can the user pick sing-box or Xray? | Yes. One canonical model, two renderers, sing-box by default. See ADR-0006. |
| Q-0006 | Should matchers and tooling move to Go because the engines are Go? | No. Janet stays. The engines are not libraries the router links. See ADR-0008 and ADR-0020. |
| Q-0007 | Are subscription URLs secrets? | Yes. They go through sops-nix and age. The Wi-Fi SSID is not a secret. Node lists stay volatile data. See ADR-0014. |
| Q-0008 | Where does DNS policy run? | Inside the selected engine. Fake-IP is `auto`, `true`, or `false`. See ADR-0019 and FR-DNS-010. |
| Q-0009 | Does a new subscription URL rebuild on the board, and does each user fork the OS? | The board does not evaluate Nix. Users keep a private config repo that pins Janus OS. See ADR-0017 and ADR-0018. |
| Q-0010 | Must the config repo have a remote, and does the board push to it? | Local git is required. A remote is not. One repo holds many routers. The board does not push or pull. See ADR-0021. |
| Q-0011 | How does the lab Fibocom NL668 attach? | USB `05c6:90b6` appears as Ethernet. Janus takes DHCP from the module and does not send an APN. See *10* §4.2. |
| Q-0012 | What if a fleet commit also changes the firewall or a port? | `fleet apply` prints those paths and changes nothing. Structural changes wait for `janus-build deploy`. See D-0024. |
| Q-0013 | Should the router print Nix for its overrides? | No. It does not know how the repo splits modules. `janus override show` is the current set. See D-0025. |
| Q-0014 | Which Yanyu case label is which PCI port? | On the measured boot, LAN1–LAN4 were `eth0`–`eth3`, which are `01:00.0`–`04:00.0`. The profile uses the PCI addresses and does not assign WAN. See *10* §3.1. |
| Q-0015 | Which INA219 current sign means discharge? | On mcuzone `0x40` the cell was discharging and the current was negative. Waveshare `0x43` is unmeasured and stays unarmed. See *10* §4.5. |
| Q-0016 | Does Raspberry Pi 4 stay Tier 1? | No. That choice is D-0016. |
| Q-0017 | Which DHCP server? | dnsmasq, for DHCP only. Router advertisements stay with networkd. See ADR-0009. |
| Q-0018 | Which tool builds the disk image? | The custom builder in *09* §6, until systemd-repart can create and populate f2fs. See ADR-0010. |
| Q-0019 | TUN or TPROXY? | sing-box defaults to TUN. Xray defaults to TPROXY. See ADR-0011. |
| Q-0020 | Must a subscription fetch be pure? | Impure by default. `snapshot.hash` pins a snapshot when it is set. See ADR-0012. |
| Q-0021 | Is the journal persistent? | Volatile. `journal.persistent` is an opt-in cap on `/var`. See ADR-0013. |
| Q-0022 | What controls a QMI or MBIM modem? | `qmicli` and `mbimcli`. Ethernet-mode WWAN stays a DHCP client. See ADR-0015. |
| Q-0023 | What happens when the engine is down? | Proxied traffic is dropped. `failMode = "open"` is the override that sends it out the WAN. See ADR-0016. |
| Q-0024 | Why not one age key for every router, kept on the build host? | That key decrypts the whole household from any SD card. Each router has its own key. The build host keeps the public key and encrypts. See ADR-0022. |
| Q-0025 | Why is the Raspberry Pi 400 not a board? | It has no Ethernet jack, so a boot there would not exercise the Pi 4 port. See D-0032. |
| Q-0026 | Which web server serves the maintenance page? | None of nginx, Caddy, or lighttpd. `janus-web` is Janet, and stunnel terminates TLS. The page is one route table in front of `janus`. See *20* §2 and D-0033. |
| Q-0027 | How does the page log in when root has no password? | With its own passphrase file. SSH stays public-key only. A lost passphrase is replaced over SSH. See *20* §3 and ADR-0007. |
| Q-0028 | Does the maintenance page have a light and a dark theme? | Yes. One console layout and the palette in *20* §7. The browser stores the choice under `janus-theme`. |
| Q-0029 | Does Russia or Iran need its own proxy implementation? | No. The tunnel, the engine, and fail-closed stay. The reference region swaps domestic DNS names, domestic resolvers, and the QUIC default. Routing rules stay in the configuration. See D-0034 and *21*. |
| Q-0030 | Is the Russia preset a list called russia/global? | No. Domestic suffixes, `category-ru`, and `geoip:ru` go direct. The default target is the rest. SagerNet does not publish `geosite-ru`. See *21* §4.2. |
| Q-0031 | Why does the Iran preset not name Shecan or Electro? | Those resolvers answer filtered names. Domestic DNS is only for names that stay direct. The operator sets an encrypted inland resolver. See *21* §4.3. |
| Q-0032 | Do Russia and Iran need use cases beyond `janus.system.region`? | The household flow is Mei's. The exceptions are an Iranian resolver, a Russian Telegram rule, and node choice. See *21* §6. |
| Q-0033 | Why does `janus.system.region` not fill in routing rules? | An unset list stays empty. The three lists are templates in the example. DNS and `blockQuic` still follow the region. See D-0034 and *21* §2. |
| Q-0034 | Is fake-IP only for a name that matches an explicit proxy rule? | No. Unmatched names follow `defaultTarget`, and a group target is proxied too. Direct uses the domestic resolver. Block is rejected. See D-0037. |
| Q-0035 | Why does `strip-for-proxied` stay the default? | A globally routable AAAA lets the host leave the tunnel. An address in the IPv6 fake-IP range is not that leak. Direct names keep a real AAAA. `keep` is the leak. See D-0038. |
| Q-0036 | Does every LAN share one traffic mode? | No. `janus.proxy.mode` is the inherited default. A guest LAN sets `proxy.mode = "bypass"`. An unset DNS policy then sends every recursive name to the domestic encrypted resolvers, not the carrier and not the tunnel. See D-0042. |
| Q-0039 | Why is a per-LAN mode not three engines, and why do rules replace instead of append? | Nodes and groups are one pool. The engine matches the LAN by source. An appended list makes the winner depend on two orders. A LAN that wants the owner's rules leaves `proxy.rules` unset, or binds the same Nix list. See D-0042. |
| Q-0037 | Should DoH and DoT addresses be pinned at build time and refreshed on a timer? | No. The build host is often outside the region, anycast answers differ, a failed lookup would fail the image, and a refresh needs a resolver that itself needs those addresses. The operator may set `janus.dns.bootstrap`. Unset, the preset supplies IP literals. See D-0040. |
| Q-0038 | Can `janus dns check` pretend to be a LAN client, and do Russia and Iran poison DNS the way China does? | It runs on the router. It cannot show that a phone can still reach another resolver. China forges plaintext answers on the path. Russia and Iran more often lie in the ISP resolver and block by SNI or address. The preset has no bogon list for those two. See D-0041. |
| Q-0040 | Does the Zero 2 W onboard Wi-Fi work as an access point? | Yes. It is the board's own radio, 2.4 GHz WPA2, on in-tree `brcmfmac` and the redistributable Raspberry Pi wireless firmware. 5 GHz and WPA3 are not this chip. See D-0043 and *10* §4.7. |
| Q-0041 | Why keep a subscription declared on a router that does not use it? | A shared subscription file is encrypted to every host whose configuration names it. Removing the declaration drops that host from the recipient set. `enable = false` keeps the name and drops the nodes. See D-0044. |
| Q-0042 | Which languages does the maintenance page speak? | English, then Russian, then Persian, then Simplified Chinese. The stored tags are `en`, `ru`, `fa`, and `zh`. The control draws `en`, `ру`, `فا`, and `简中` in every page language. Persian sets `dir="rtl"`. Chinese is left to right. `zh-Hant` is not a page language. The reboot confirmation stays the Latin word `reboot`. See *20* §7 and D-0033. |
| Q-0043 | Does changing `janus.access.deploy.address` require a new image? | No. `janus-build` evaluates it from the fleet repo when `deploy`, `fleet apply`, `fleet pull`, `status`, or `backup` runs. The router does not use the option. `deploy`, `fleet pull`, `status`, and `backup` read an uncommitted edit. `fleet apply` still refuses a dirty tree. A LAN address can install the age key. A later edit can name a MagicDNS name, the Tailscale IPv4, or an IPv6 literal. A bare IPv6 literal is sent as `root@[address]`. See *08* §10 and *16*. |
| Q-0044 | Why is a full state check not run on every boot, and why does the state partition stop at 4 GiB? | A full `fsck.f2fs` reads metadata in proportion to the volume. On a slow card that check is long, and a timeout must not wipe the partition. Routers stay up, so the full check runs only when `janus.system.reboot.schedule` fires and `janus.system.reboot.fsck` is set. It stops after 30 minutes. A 4 GiB state partition finishes inside that, and so does 64 GiB. Hitting the cap fails that boot and does not reformat. The request is removed before the check, so a check that does not finish is not repeated. The reboot is a system maintenance window; the state check is one action on it. 4 GiB holds router state. A larger or smaller `state.maximumSize` is allowed. A cap below the flashed size does not shrink. See D-0049. |
| Q-0045 | Why does the ROCK Pi 4C not use nixpkgs `ubootRockPi4` as shipped, and why must SPI be clear? | That package is the 4A/4B defconfig and does not install `u-boot-rockchip.bin`. The profile builds `rock-pi-4c-rk3399_defconfig` and writes the combined image at sector 64. The boot ROM tries SPI NOR before eMMC and SD. A bootloader left in SPI is what the ROM starts, so sector 64 never runs. The image does not program SPI. After this U-Boot starts, a two-second serial menu tries eMMC and then SD, or the SD card alone. ROCK 4C+ is a different board. See D-0053 and *10* §3.5. |
| Q-0046 | Why does the Wi-Fi country follow `janus.system.region`, and why can it be replaced? | With no country the kernel uses the world domain, which disables channels an access point needs, including 5 GHz channels used in China. The region letters are the three countries this router is built for, so they are the default. The region stays the censorship environment. `janus.network.wifiCountry` is the regulatory country when the transmitter is somewhere else. See D-0054 and *06* §11. |
| Q-0047 | Why is the Le Potato image not a plain GPT disk? | The mask ROM needs sector 1 for `@AML`. A primary GPT in that sector fails the header check, and writing one back after boot wipes the firmware. Six partitions do not fit in four MBR primaries, so the extra ones are logical. The board still mounts by the GPT PARTUUIDs, through the backup header and the kernel parameter `gpt`. See D-0055 and *10* §3.6. |
| Q-0048 | Why does serial root login use its own option, and why is the account fixed? | `services.getty.autologinUser` also logs in on `tty1`. A board with HDMI or VGA would hand that console a root shell as well. The serial getty is the one the board `console=` names, and the baud stays the kernel setting. The image has no other interactive user. SSH stays key-only. See D-0056. |
| Q-0049 | Why does the persistent journal stay under `janus.system`? | ADR-0013 keeps journald volatile and leaves `journal.persistent` for a capped journal on `/var`. That is for a router which has left the bench, including after a power cut. `janus.debug` is the set to turn off before an image ships. The engine log is `janus.debug.engineLog`. See D-0057. |
