# 12 — Operations and Maintenance

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-22 |

## 1. What maintenance is

A router is used by a person who will not rebuild an image to add a printer
lease or to paste a new proxy subscription URL, and who will also not accept a
box that can be changed from the shell with nothing written down. Janus
keeps both constraints by splitting work into three kinds.

| Kind | Examples | How it takes effect | Record |
|------|----------|---------------------|--------|
| **Maintenance action** | refresh subscriptions, refresh Geo data, select another node while one is dead, restart a WAN, `janus dns check` | CLI (or a later maintenance page). No rebuild. | journal + `janus status`; node selection persists until a rebuild changes that group's default |
| **Hot override** | change an existing subscription URL, add a static lease, rotate a Wi-Fi passphrase | `janus override set`; a runtime renderer reloads the affected service | `/var/lib/janus/overrides.json` (passphrases in the secrets directory). `janus status` shows drift against the image |
| **Configuration** | swap WAN/LAN ports, add a LAN or a subscription, change traffic mode, routing rules, firewall, board, engine | Edit the private config repo on the build host, commit, rebuild, deploy | git |

The board does not run `nixos-rebuild`. Frequent edits are hot overrides
exactly so that a rebuild is not the price of ordinary use. Structural
edits stay in git so the project does not become an imperative router with
a Nix build step nobody runs.

### 1.1 Allowlist

Overridable without a rebuild:

* `proxy.subscriptions.<existing>.url`
* `network.lans.<existing>.dhcp.staticLeases.<host>`
* `network.wifi.<existing>.passphrase`

Not overridable: new subscriptions, new LANs, port forwards, routing
rules, groups, WAN mode, port assignment. Those change units, firewall,
or identity of the router and go through a rebuild. If a requested key is
not on the allowlist, the CLI refuses it and names the rebuild path.

### 1.2 How a hot override gets back into git

The router stores the current allowlisted values. It does not store the
sequence of edits, and it does not know which module file in the repo
should change. `janus override show` is that current set.

From the build host:

```
janus-build fleet pull [<host>]
```

No host means every reachable router. The command reads the set over SSH.
Secret values stay on the router. The output names a credential that has
an override and does not write it. Static leases go to
`hosts/<host>/overrides.nix` (*16* §5).

```
janus-build fleet pull [<host>] --with-secrets
```

The router decrypts those overrides. The build host encrypts them to the
public keys of the existing secret files and writes those files. It warns
that the session carried plaintext and that no plaintext file was kept.
The user reviews the ciphertext diff and commits.

The command does not commit.

There is no silent sync. A user who never pulls still has the override in
`janus backup`. Editing the same key in git and on the router without
pulling is drift; `janus status` prints it rather than guessing which
side wins. The running value is the override until the next deploy,
which replaces overrides that the new image now contains.

### 1.3 Editing on the build host, then updating the routers

The usual path for a subscription URL or a Wi-Fi passphrase is
`janus-build secret set` on that one file, commit, and
`janus-build fleet apply`. The build host cannot decrypt (*16* §2). It
sends secret ciphertext to each reachable router. The router decrypts
with its own age key and applies the override, together with the static
leases in `hosts/<name>/overrides.nix`.

`fleet apply` is not a partial deploy. If the commit since the running
image also changes something outside that projection, the command prints
those paths and changes nothing. `--only-overrides` applies the
projection and leaves the rest for `janus-build deploy`. A router that is down
is listed and left unchanged.

The board does not pull the repo, and one router does not push values to
another. A shared secret that two reachable routers have overridden to
different values is left unchanged by `janus-build fleet pull --with-secrets`
until those values agree (*16* §5).

### 1.4 Circumvention is the unstable part

Ordinary router state (link up, DHCP, NAT) is monitored like any other
router: interface counters, WAN health, lease table.

The tunnel needs its own signals because it fails more often than Ethernet:

| Event | What the operator does | Kind |
|-------|------------------------|------|
| A node stops answering | `janus proxy select <group> <other>` (url-test also moves by itself) | maintenance action |
| Geo data refresh failed | `janus proxy geodata refresh` | maintenance action |
| Subscription fetch failed | `janus proxy refresh <name>` | maintenance action |
| The vendor changed the subscription URL on one router | `janus override set proxy.subscriptions.<name>.url <url>` | hot override |
| The same URL is shared by several routers | `janus-build secret set` on that subscription file, commit, `janus-build fleet apply` | one ciphertext file, then each reachable host decrypts and applies it (*12* §1.3) |

`janus status` shows the last success, the last error, and the selected
node for each group. That is the maintenance surface for 1.0. The
maintenance page (*20*) calls these commands and the hot-override
allowlist. It does not replace the CLI and it does not edit
`configuration.nix`. The image includes it only when
`janus.access.web.enable` is set. `janus web stop` then pauses the
listener without a rebuild.

## 2. Day-0: first deployment

1. On a build host that has Nix and does not yet have a fleet repo:
   `nix run github:oemaix/janus-os#janus-build -- init <dir>` (*16* §0).
   Enter that directory and run `nix develop`. Later commands are
   `janus-build`.
2. `janus-build host add <host>` unless `init --host` already did.
   Edit `hosts/<host>/configuration.nix` (board, ports, WAN, LAN, SSH key).
   Put a shared subscription in `common/default.nix`. Commit. Then
   `janus-build secret keygen <host>`, store the printed private key in a
   password manager, and `janus-build secret set` for each credential file
   that host needs.
3. `janus-build build <host>`; flash the printed image. The image contains
   ciphertext. It does not contain the age private key.
4. Boot; connect to LAN; `ssh root@192.168.10.1` (or the configured address).
5. Install that host's private key once, from the password manager:
   `janus secrets install-age-key`. On a terminal the command prints
   `Paste the age private key, then press Enter and Ctrl-D.` A pipe stays
   quiet. Input with no `AGE-SECRET-KEY-1` line is refused, and the
   previous key stays. Do not leave the key on the build host. Services
   that need secrets start when the key appears. A secret that will never
   live in git can instead be loaded with `janus secrets put`.
6. `janus status` — verify WAN, DNS, proxy health.

Alternative for step 5: `janus-build deploy --age-key <host>` checks SSH
with stdin closed. On a terminal it prints the same line only after that
session answers. A failed session does not read stdin. It does not store
the key. The SSH destination is `janus.access.deploy.address`, read from
the fleet repo when the command runs (*16*, Q-0043). A bare IPv6 literal
is sent as `root@[address]`.

## 3. Day-2 tasks

| Task | Command / action |
|------|------------------|
| Overall status | `janus status` (WANs, LANs, DHCP leases count, engine health, selected nodes, last refresh, state partition usage) |
| Refresh subscriptions now | `janus proxy refresh [name]` |
| Refresh Geo data now | `janus proxy geodata refresh` |
| Pick a node manually | `janus proxy select <group> <node>`; `janus proxy groups` lists options |
| Latency test a group | `janus proxy test <group>` |
| Restart a WAN | `janus wan restart <name>` |
| Show WAN details | `janus wan show <name>` (addresses, DNS learned, uptime, health) |
| DHCP leases | `janus lan leases [lan]` |
| Traffic counters | `janus traffic [iface] [--daily\|--monthly]` |
| Live top talkers | `janus traffic top` (requires `scope = per-host`) |
| DNS diagnostics | `janus dns query <name>`, `janus dns flush`, `janus dns stats` |
| DNS leak / poison check | `janus dns check` (on the router, once per LAN: one domestic name and one foreign name; it does not impersonate a LAN client) |
| Set a hot override on the router | `janus override set <key> <value>`; `janus override diff`; later `janus-build fleet pull` (leases), or `janus-build fleet pull --with-secrets` when the credential itself should be written back |
| Push committed overrides | `janus-build fleet apply [<host>]` (*16*) |
| Router status from the build host | `janus-build status [<host>]` |
| Archive one router | `janus-build backup <host>` |
| Logs | `janus logs [unit] [-f]` (journalctl wrapper with Janus units) |
| Firewall view | `janus fw list` (rendered nftables with zone annotations) |
| Version/provenance | `janus version --components` (reads `/etc/janus/build.json`) |
| Maintenance page | `janus web status`. `janus web stop` pauses the listener; `janus web start` brings it back. Exit `2` when the image was built without `janus.access.web.enable` (*20*). |
| Factory reset | `janus reset --state` (wipes state partition, reboots; seeds from image) |
| Reboot | `janus reboot` |

All subcommands are also usable non-interactively (JSON output with
`--json`) for scripting from the build host.

## 4. Scheduled jobs (on the Board)

| Timer | Default | Purpose |
|-------|---------|---------|
| `janus-proxy-refresh-<name>` | per subscription (`6h`) | Fetch, validate, reload. The template unit is `janus-proxy-refresh@.service`. A subscription with `enable = false` has no timer (D-0044). |
| `janus-geodata-refresh` | weekly | Geo rule sets. The schedule may be a five-field cron whose day-of-week is a list, such as `0 4 * * 2,4,6` (D-0044). |
| `janus-reboot` | off | Maintenance reboot (`janus.system.reboot.schedule`). `monthly` is 04:00 on the 1st, `yearly` is 04:00 on 1 January, or a five-field cron whose day-of-week is `*`. The service only reboots. `janus.system.reboot.fsck` runs `janus-reboot-fsck` first, which requests a full state check on that boot only (D-0049). |
| `janus-wan-health` | 30 s after boot, then the WAN interval (`10s`) | WAN health and backup failover. Engine restart is the unit's own `Restart=`. |
| `janus-metrics` | 60 s | Engine metrics text, when Prometheus is on |
| vnstat | `SaveInterval` 15 min | Persist interface counters. There is no `janus-monitoring-save` unit. |
| `fstrim` | weekly | Discard on f2fs partitions |

Subscription, Geo refresh, and `janus-reboot` set `Persistent=true` and
`RandomizedDelaySec=10min`, so a missed run executes after boot and
providers are not hit at the same moment. A missed reboot then runs once
after that boot.

## 5. Failure handling

| Failure | Behavior |
|---------|----------|
| Subscription fetch fails | keep last good data; warning in `janus status`; retry with backoff |
| Refresh yields < `minimumNodes` or invalid data | rejected; previous kept |
| Engine crash | systemd restart with backoff; proxied traffic stays dropped until the engine is back (ADR-0016). `failMode = "open"` is the override that lets it leave via the WAN |
| WAN down | health check marks it; backup WAN promoted if configured; DNS keeps answering from cache |
| State partition corrupted | `fsck.f2fs -a` every boot; a full check only when the maintenance reboot sets `janus.system.reboot.fsck`. If unrecoverable, reformat and reseed (logged, HMI notice). A slow check or a missing block device is not corruption. Status 4 or 255 is checked again before that. A failed grow does not skip the check (D-0049). |
| Time far off at boot (no RTC) | engine waits for NTP up to 90 s, then starts anyway; REALITY/TLS may fail until time syncs |
| Full state partition | bounded writers make this unlikely; `janus status` warns at 80 %; journal/vnstat rotate |

## 6. Upgrading Janus itself

1. On the build host: `janus-build update` follows the current train
   (*09* §10, ADR-0024). A different train is
   `janus-build update --train <train>`, where `<train>` is `main` or
   `X.Y`. When that pin does not evaluate, `nix develop` cannot start and
   `janus-build` is not available. `nix flake update janus` in the fleet
   repo moves the same lock without evaluating the pin (*16* §0). Read
   the changelog for option changes (deprecations produce evaluation
   warnings with the new option path).
2. `janus-build build <host>`, then `janus-build deploy --preserve-state`
   (re-flash) or `janus-build deploy` (closure push, P2).
3. After boot, `janus status` and `janus version` confirm; if the new
   generation fails to boot, the previous one is offered once (closure push
   path) or re-flash the previous image (re-flash path).

## 7. Backup and restore

The declarative configuration is the private git repo, including
ciphertext. Backup is not a second copy of that repo. A subscription URL
that was typed on the router returns through
`janus-build fleet pull --with-secrets`. The default pull does not copy it.

What is actually worth archiving is whatever a rebuild cannot recreate:

| Item | In `janus backup` | Why |
|------|-------------------|-----|
| Age private key | required | One per router, generated on the build host and not retained there. Without it, that router's secret files cannot be decrypted. The copy to keep is a password manager. A `0600` file on the build host is not the steady state. An archive left on the build host is a private key again. |
| Hot overrides not yet pulled | required | They are the only record until the next commit. |
| Manual node selection, traffic statistics | included | Operational, not reconstructable from git. |
| Subscription cache, Geo cache, logs | optional | A refresh or a new boot replaces them. Useful when the WAN is down and the cache is the last good data. |
| DHCP dynamic leases | omitted | They come back from clients. Static leases are configuration or overrides. |
| SSH host keys | optional | Restoring them avoids a host-key warning after a reflash. |

`janus restore < file` writes the archive back and reloads services. The
board does not back itself up to the git remote.

## 8. Monitoring integration

* Local: `janus traffic`, `janus status`, HMI pages.
* Remote (optional): IPFIX export to a collector in `mgmt`/LAN; Prometheus
  endpoint on `mgmt` zone; syslog forwarding via `journald` remote (P3).
* Connection audit (FR-MON-007): `janus.monitoring.audit.enable` includes
  it, default off. With the switch on, recording starts at boot.
  `janus audit stop` pauses it without a rebuild, and `janus audit start`
  turns it back on. `janus audit start` exits 2 when the image was built
  without the switch. The file is JSON Lines (one object per line) at
  `/var/lib/janus/audit/connections.jsonl`. The log is metadata for the
  owner (for example, checking whether a LAN device reports home to an
  unexpected network). It is not a packet capture, and Janus does not
  analyse it on the board.

## 9. Support bundle

`janus support-bundle` collects redacted status, rendered configs (secrets
scrubbed), journal excerpts and `build.json` into a tarball for bug reports.
