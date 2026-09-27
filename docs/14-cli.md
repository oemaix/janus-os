# 14 — Router command-line specification

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

This is the contract for the on-router `janus` command. Implementation
follows this file. The user manual will later show the same commands with
examples; it does not define them. The build host uses a different
program, `janus-build` (*16*). On the board, `janus deploy` and
`janus fleet` exit `2` and name that program.

## 1. Invocation

```
janus [--json] <command> [<args>]
```

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
| `janus dns check` | Leak and poisoning probes (FR-DNS-011). Does not change policy. |
| `janus logs [unit] [-f]` | Journal for Janus units |
| `janus fw list` | nftables ruleset with zone notes |
| `janus version [--components]` | Image provenance from `/etc/janus/build.json` |
| `janus reboot` | Reboot |
| `janus reset --state` | Wipe the state partition and reboot. Requires `--yes`. |

## 3. Hot overrides

Allowlist (FR-OPS-007). Nothing else is accepted.

| Key | Command |
|-----|---------|
| `proxy.subscriptions.<name>.url` | `janus override set proxy.subscriptions.<name>.url <url>`, or with no `<url>` read stdin |
| `network.lans.<name>.dhcp.staticLeases.<host>` | `janus override set network.lans.<name>.dhcp.staticLeases.<host> --mac <mac> --ip <ip>` |
| `network.wifi.<name>.passphrase` | `janus override set network.wifi.<name>.passphrase` (reads stdin, writes the secrets directory, not the JSON) |

`<name>` and `<host>` must already exist in the embedded configuration.
Creating a subscription, a LAN, or a Wi-Fi AP is a rebuild.

| Command | Effect |
|---------|--------|
| `janus override show` | Current stored overrides, and which ones differ from the image. This is the set, not the history of edits. `--json` is what `janus-build fleet pull` reads. |
| `janus override diff` | Drift only |
| `janus override unset <key>` | Remove one override and reload |

Applying a valid override reloads only the affected service (subscription
refresh, DHCP, hostapd). A failed reload keeps the previous override.

The board does not turn overrides into Nix. `janus-build fleet pull` on
the build host does that (*16* §5).

## 4. Secrets

| Command | Effect |
|---------|--------|
| `janus secrets install-age-key` | Read the age private key on stdin into `/var/lib/janus/secrets/age.key` (mode `0600`) and restart units that decrypt secrets |
| `janus secrets put <name>` | Read a secret on stdin for a value that will not enter git |

The age key is created on the build host (`age-keygen`), not by this command.

## 5. Audit (after 1.0, FR-MON-007)

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

## 7. Stability

Command names and the allowlist keys above are stable for 1.0. Adding a
key is a documentation change in this file before the code accepts it.
