# 14 — Router command-line specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-12 |

This is the contract for the on-router `janus` command. Implementation
follows this file. The user manual will later show the same commands with
examples; it does not define them. The build host uses a different
program, `janus-build` (*16*). On the board, `janus deploy` and
`janus fleet` exit `2` and name that program.

## 1. Invocation

```
janus [--json] <command> [<args>]
janus --help
janus --usage
```

* `--help` and `--usage` print the same command list on stdout and exit
  `0`. They do not run a command. `--json` before either flag does not
  change that text. A usage error prints the synopsis on stderr, names
  `--help`, and exits `2`.
* `--json` prints one JSON object on stdout and keeps logs on stderr.
  Exit code `0` is success. `2` is a usage or validation error. `1` is a
  runtime failure (refresh failed, engine did not reload).
* The command refuses to evaluate Nix, to run `nixos-rebuild`, and to
  talk to a git remote (FR-OPS-001, FR-OPS-010).
* A request outside the hot-override allowlist exits `2` and names the
  rebuild the user would do on the build host instead.

## 2. Maintenance actions

These do not change configuration or hot overrides.

| Command | Effect |
|---------|--------|
| `janus status` | WANs, LANs, lease count, engine health, selected node per group, last subscription and Geo refresh (time and error), drift, state-partition use, power-sensor readings when a `power` peripheral exists |
| `janus proxy refresh [name]` | Fetch subscriptions now. No name means all. |
| `janus proxy geodata refresh` | Fetch Geo data now. |
| `janus proxy select <group> <node>` | Temporary node choice. Survives reboot. Cleared when a rebuild changes that group's `default`. |
| `janus proxy groups` | Groups, strategy, current node, members |
| `janus proxy test <group>` | Latency test |
| `janus wan restart <name>` | Restart one WAN |
| `janus wan show <name>` | Addresses, learned DNS, uptime, health |
| `janus lan leases [lan]` | DHCP leases |
| `janus traffic [iface] [--daily\|--monthly]` | Counters |
| `janus traffic top` | Top talkers; requires `scope = per-host` |
| `janus dns query <name>` | Resolve as the router would |
| `janus dns flush` | Clear the DNS cache |
| `janus dns stats` | Cache and upstream counters |
| `janus dns check` | On-router leak and poisoning probes, once per LAN: one domestic name and one foreign name (FR-DNS-011, D-0041). Does not impersonate a LAN client. Does not change policy. |
| `janus logs [unit] [-f]` | Journal for Janus units |
| `janus fw list` | nftables ruleset with zone notes |
| `janus version [--components]` | Image provenance from `/etc/janus/build.json` |
| `janus reboot` | Reboot |
| `janus reset --state` | Wipe the state partition and reboot. Requires `--yes`. |
| `janus bluetooth list` | Paired devices: address, name, paired, connected, trusted, and whether this is the last connected speaker. Exit `2` when Bluetooth playback is not in the image. |
| `janus bluetooth discover` | Nearby devices for about eight seconds: address and name. This is how an unknown address is learned. |
| `janus bluetooth pair <address-or-name> [code]` | Pair, trust, and connect one speaker. A name must match exactly one device. No argument is rejected. `code` is 1 to 16 letters or digits when the speaker asks for one. Omit it for Just Works. That device becomes the last connected device. |
| `janus bluetooth connect <address-or-name>` | Connect one paired speaker and remember it. A name must match exactly one paired device. |
| `janus bluetooth disconnect <address-or-name>` | Disconnect that device. This boot does not connect that address again. Another address is left alone. The next boot connects the last device again. |
| `janus bluetooth remove <address-or-name>` | Remove the pairing. If it was the last device, nothing is connected after boot. |

Label inspection is not a command in this table. ADR-0027, ADR-0028, and
*07* §11 specify it for later. `groups`, `select`, and `test` stay until
that work. When §11 replaces them, those commands are removed. The CLI
does not present a group. There is no compatibility command and no
migration.

## 3. Hot overrides

Allowlist (FR-OPS-007). Nothing else is accepted.

| Key | Command |
|-----|---------|
| `proxy.subscriptions.<name>.url` | `janus override set proxy.subscriptions.<name>.url <url>`, or with no `<url>` read stdin |
| `network.lans.<name>.dhcp.staticLeases.<host>` | `janus override set network.lans.<name>.dhcp.staticLeases.<host> --mac <mac> --ip <ip>` |
| `network.wifi.<name>.passphrase` | `janus override set network.wifi.<name>.passphrase` (reads stdin, writes the secrets directory, not the JSON) |

The subscription, the LAN, and the Wi-Fi AP must already exist in the
embedded configuration. A static-lease hostname may be new on that LAN.
Creating a subscription, a LAN, or a Wi-Fi AP is a rebuild.

| Command | Effect |
|---------|--------|
| `janus override show` | Current stored overrides, and which ones differ from the image. This is the set, not the history of edits. Secret values are redacted. `--json` is what `janus-build fleet pull` reads by default. |
| `janus override show --secrets` | Same set, with secret values. This is the stdout `janus-build fleet pull --with-secrets` reads. There is no `janus override export`. |
| `janus override diff` | Drift only. Secret values stay redacted. |
| `janus override unset <key>` | Remove one override and reload |

Applying a valid override reloads only the affected service (subscription
refresh, DHCP, hostapd). A failed reload keeps the previous override.

The board does not turn overrides into Nix. `janus-build fleet pull` on
the build host does that (*16* §5).

## 4. Secrets

| Command | Effect |
|---------|--------|
| `janus secrets install-age-key` | Read this router's age private key on stdin into `/var/lib/janus/secrets/age.key` (mode `0600`). On a terminal, print `Paste the age private key, then press Enter and Ctrl-D.` on stderr before reading. A pipe stays quiet. Input with no `AGE-SECRET-KEY-1` line is refused, and the previous key stays. Restart `sops-install-secrets`, then a failed PPPoE unit, then a failed `janus-wireguard-secret-<name>`. When that restart succeeds, reconfigure `wg-<name>`. If that device is not there yet, reload networkd. Then `janus-wifi-secret-<name>` when that unit exists and `janus-hostapd-<name>` failed, then failed Wi-Fi units, then `janus-tailscale-auth` and `tailscaled` when either failed, then `janus-web-secret` when that unit exists and `janus-web`, `janus-web-tls`, or `janus-web-secret` failed, then `janus-web` and `janus-web-tls`, then `janus-http-secret` when that unit exists and `janus-http`, `janus-http-tls`, or `janus-http-secret` failed, then `janus-http` and `janus-http-tls`. |
| `janus secrets put <name>` | Read a secret on stdin for a value that will not enter git |

The age key is created on the build host by `janus-build secret keygen <host>` (*16*). This command installs the private key. It does not generate one. The build host does not keep a copy.

## 5. Audit (FR-MON-007)

| Command | Effect |
|---------|--------|
| `janus audit start` | Start recording. Exit `2` if `janus.monitoring.audit.enable` is false. |
| `janus audit stop` | Stop recording. Does not remove the configuration flag. |
| `janus audit status` | Whether recording is on, path, size, oldest record |
| `janus audit export` | Write the JSON Lines log to stdout |

## 6. Backup

| Command | Effect |
|---------|--------|
| `janus backup` | Archive to stdout per FR-OPS-011 |
| `janus restore` | Read an archive on stdin. Requires `--yes`. |

## 7. Maintenance page

The page is *20*. These commands switch the listener. They do not change
`janus.access.web.enable`.

| Command | Effect |
|---------|--------|
| `janus web start` | Start the listener. Exit `2` if `janus.access.web.enable` is false. Exit `1` if the passphrase file is missing or empty. When `janus-web-secret` exists, or the passphrase path is under `/run/secrets`, start that install before the file test. If the install fails, exit `1` and say the passphrase secret could not be installed. |
| `janus web stop` | Stop the listener. Does not remove the configuration flag. |
| `janus web status` | Listening or stopped, port, zones, certificate fingerprint. |
| `janus web fingerprint` | SHA-256 of the certificate. Exit `2` if the page is not in the image. |

## 8. Edge API and speech

The listener is *08* §1c. Speech is *08* §1d. These commands apply when
that listener is in the image (D-0062). They do not change
`janus.edge.api.enable`.

| Command | Effect |
|---------|--------|
| `janus edge api start` | Start the listener. Exit `2` if `janus.edge.api.enable` is false. Exit `1` if the token file is missing or empty. When `janus-http-secret` exists, or the token path is under `/run/secrets`, start that install before the file test. |
| `janus edge api stop` | Stop the listener. Does not remove the configuration flag. |
| `janus edge api status` | Listening or stopped, port, zones, whether recognition and synthesis are in the image, certificate fingerprint. |
| `janus edge api fingerprint` | SHA-256 of the certificate. Exit `2` if the listener is not in the image. |
| `janus edge speech asr` | Read WAV, or signed 16-bit PCM at 16 kHz mono, on stdin and write the transcript on stdout. Exit `2` if recognition is not in the image. A failed engine keeps its exit status. Does not use the bearer token. |
| `janus edge speech tts [--play]` | Read the text argument and write WAV on stdout. `--play` plays `janus.audio.playback` and exits `2` when that device is unset. Exit `2` if synthesis is not in the image. Does not use the bearer token. |

## 9. Stability

Command names and the allowlist keys in §2–§6 are stable for 1.0. The
`janus web` commands in §7 apply when the page is in the image. The
`janus edge api` and `janus edge speech` commands in §8 apply when that listener
is in the image. Adding a key is a documentation change in this file
before the code accepts it.
