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
  `install-age-key` restarts `sops-install-secrets` when that unit
  exists, then failed PPPoE and Wi-Fi units, then `janus-web` and
  `janus-web-tls` when either page unit failed. A `urlSecret` subscription stays an empty snapshot until
  `janus proxy refresh`. `subscriptions.<name>.enable` defaults to true.
  False on one host drops that subscription's nodes, snapshot, and timer,
  and keeps `url` or `urlSecret` so the host still names the secret file
  (D-0044). `refresh` and `geodata.refresh` accept a five-field cron whose
  day-of-week is `*` or a list such as `2,4,6`. `0` and `7` are Sunday.
  The day-of-month and the month stay `*`. A destination that refuses an
  exit from Iran, China, or Russia is future work (*13*).
- Router commands are `docs/14-cli.md`. Build-host commands are
  `docs/16-build-host-cli.md`. `janus.*` options are
  `docs/08-configuration-reference.md`. Phase 1 commands exist, and so
  do proxy, DNS, fleet, status, backup, deploy, and `janus audit`.
  On the board, `janus deploy` exits 2 and names `janus-build`. Hot
  overrides cover an existing subscription URL, a static lease on an
  existing LAN, and an existing Wi-Fi passphrase.
- `janus.system.region` is `cn` (default), `ru`, or `ir`. It selects domestic DNS
  and the `blockQuic` default. That reject follows direct rules; it is
  not a drop of every UDP/443. `janus.proxy.rules` stays empty until
  written. The example has the `cn`, `ru`, and `ir` lists. `ir` requires
  `janus.dns.domestic.resolvers`. The region is not a hot override.
- Each LAN inherits `janus.proxy.mode`, `rules`, `defaultTarget`,
  `exceptions`, and `janus.dns` (D-0042). A set `proxy.rules` replaces
  the inherited list. Nodes, groups, subscriptions, and `failMode` stay
  on the router. One engine matches the LAN by source. `bypass` is not
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
  `mgmt`). `janus web stop` pauses it without a rebuild. The passphrase
  is not the root password. Compare `janus web fingerprint` with the
  page before typing it. The page is status, maintenance actions, and
  the hot-override allowlist.
- `janus.storage.slots.enable` defaults to false. With it set, deploy
  writes the inactive ROOT and NIX slot and then changes the boot entry.
  The state partition is shared. Confirm with `janus-build deploy --confirm`.
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
- Raspberry Pi 2 v1.1 (`rpi2`) and StarFive VisionFive 2 are Tier 3.
  `janus.build.strategy` defaults to `cross` for them. `lib.mkRouter`
  takes `buildSystem`. Pure evaluation defaults it to `x86_64-linux`.
  `janus-build` on another machine uses that machine's system and refuses
  a mismatch. A Raspberry Pi 2 v1.2 uses the `rpi3` profile. `rpi4` is
  the Raspberry Pi 4 and the Compute Module 4. The Pi 400 is not a board.
- A mcuzone UPS at I²C `0x40` shows the cell in `janus status` and powers
  the router off while that cell is discharging, at the thresholds in
  docs/10 §4.5. Address `0x43` stays unarmed.
- The Raspberry Pi Zero 2 W onboard radio is a 2.4 GHz WPA2 access point
  (D-0043, docs/10 §4.7). Declare `match.onboard = true` and name that
  access point in the LAN members. 5 GHz and WPA3 fail evaluation.
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
