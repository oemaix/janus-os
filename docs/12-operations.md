# 12 — Operations and Maintenance

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-27 |

## 1. What maintenance is

A router is used by a person who will not rebuild an image to add a printer
lease or to paste a new subscription URL, and who will also not accept a
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
janus-build fleet pull <host>
```

The command reads the set over SSH and writes it into places the repo
already has: the sops key that host's `urlSecret` or `passphraseSecret`
names, and `hosts/<host>/overrides.nix` for static leases (*16* §4). It
does not commit. The user reviews the diff and commits.

There is no silent sync. A user who never pulls still has the override in
`janus backup`. Editing the same key in git and on the router without
pulling is drift; `janus status` prints it rather than guessing which
side wins. The running value is the override until the next deploy,
which replaces overrides that the new image now contains.

### 1.3 Editing on the build host, then updating the routers

The usual path for a subscription URL or a Wi-Fi passphrase is to edit
`secrets.yaml` on the build host, commit, and run `janus-build fleet apply`.
The build host decrypts with its copy of the one age key (*16* §1). Each
reachable router receives the hot-override projection for that host:
its subscription URLs, its existing Wi-Fi passphrases, and the static
leases in `hosts/<name>/overrides.nix`.

`fleet apply` is not a partial deploy. If the commit since the running
image also changes something outside that projection, the command prints
those paths and changes nothing. `--only-overrides` applies the
projection and leaves the rest for `janus-build deploy`. A router that is down
is listed and left unchanged.

The board does not pull the repo, and one router does not push values to
another. A shared secret that two routers have overridden to different
values is left unchanged by `janus-build fleet pull` until those values agree
(*16* §4).

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
| The same URL is shared by several routers | Edit the shared sops secret, commit, `janus-build fleet apply` | one secret, then a hot override on each reachable host (*12* §1.3) |

`janus status` shows the last success, the last error, and the selected
node for each group. That is the maintenance surface for 1.0. A small web
page that only calls these commands is a later option (FR-ACC-005); it
does not replace the CLI and it does not edit `configuration.nix`.

## 2. Day-0: first deployment

1. `janus-build init` on the build host. That runs `nix flake init -t`.
2. Edit `configuration.nix` (board, ports, WAN, LAN, SSH key,
   subscriptions). `janus-build secret keygen`, then `janus-build secret edit`.
3. `janus-build build <host>`; flash the printed image.
4. Boot; connect to LAN; `ssh root@192.168.10.1` (or the configured address).
5. The age key is generated on the build host before the first build, and
   `secrets.yaml` is encrypted to it. After the first boot, install that
   private key once: `janus secrets install-age-key` (paste). Services that
   need secrets start when the key appears. A secret that will never live
   in git can instead be loaded with `janus secrets put`.
6. `janus status` — verify WAN, DNS, proxy health.

Alternative for step 5: `janus-build deploy --secrets ./secrets/ <host>`
pushes all secret files before or after flashing.

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
| DNS leak / poison check | `janus dns check` |
| Set a hot override on the router | `janus override set <key> <value>`; `janus override diff`; later `janus-build fleet pull <host>` |
| Push committed overrides | `janus-build fleet apply [<host>]` (*16*) |
| Router status from the build host | `janus-build status [<host>]` |
| Archive one router | `janus-build backup <host>` |
| Logs | `janus logs [unit] [-f]` (journalctl wrapper with Janus units) |
| Firewall view | `janus fw list` (rendered nftables with zone annotations) |
| Version/provenance | `janus version --components` (reads `/etc/janus/build.json`) |
| Factory reset | `janus reset --state` (wipes state partition, reboots; seeds from image) |
| Reboot | `janus reboot` |

All subcommands are also usable non-interactively (JSON output with
`--json`) for scripting from the build host.

## 4. Scheduled jobs (on the Board)

| Timer | Default | Purpose |
|-------|---------|---------|
| `janus-refresh-subscriptions@<name>` | per subscription (`6h`) | Fetch, validate, reload |
| `janus-refresh-geodata` | weekly | Same for Geo data |
| `janus-refresh-bootstrap` | weekly | Refresh DoH/DoT bootstrap IPs |
| `janus-healthcheck` | 1 min | WAN health, failover, engine liveness (restart with backoff), DNS self-test |
| `janus-monitoring-save` | 15 min | Persist counters |
| `fstrim` | weekly | Discard on f2fs partitions |

Timers use `Persistent=true` so a missed run executes after boot, and
`RandomizedDelaySec` to avoid thundering herds against providers.

## 5. Failure handling

| Failure | Behavior |
|---------|----------|
| Subscription fetch fails | keep last good data; warning in `janus status`; retry with backoff |
| Refresh yields < `minimumNodes` or invalid data | rejected; previous kept |
| Engine crash | systemd restart with backoff; proxied traffic stays dropped until the engine is back (ADR-0016). `failMode = "open"` is the override that lets it leave via the WAN |
| WAN down | health check marks it; backup WAN promoted if configured; DNS keeps answering from cache |
| State partition corrupted | fsck; if unrecoverable, reformat and reseed (logged, HMI notice) |
| Time far off at boot (no RTC) | engine waits for NTP up to 90 s, then starts anyway; REALITY/TLS may fail until time syncs |
| Full state partition | bounded writers make this unlikely; `janus status` warns at 80 %; journal/vnstat rotate |

## 6. Upgrading Janus itself

1. On the build host: `janus-build update`, then read the changelog for
   option changes (deprecations produce evaluation warnings with the new
   option path).
2. `janus-build build <host>`, then `janus-build deploy --preserve-state`
   (re-flash) or `janus-build deploy` (closure push, P2).
3. After boot, `janus status` and `janus version` confirm; if the new
   generation fails to boot, the previous one is offered once (closure push
   path) or re-flash the previous image (re-flash path).

## 7. Backup and restore

The declarative configuration is the private git repo. Backup is not a
second copy of that repo, and it is not how subscription URLs are saved.
Those URLs return to the repo through `janus-build fleet pull`.

What is actually worth archiving is whatever a rebuild cannot recreate:

| Item | In `janus backup` | Why |
|------|-------------------|-----|
| Age private key | required | Generated on the build host. Without it, `secrets.yaml` cannot be decrypted. The recommended copy is a password manager plus a `0600` file outside the repo, for example `~/.config/janus/age.key`. Other stores are allowed; this is the one the manual will teach. |
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
* Connection audit (FR-MON-007, after 1.0): `janus.monitoring.audit.enable`
  includes it, default off. `janus audit start` and `janus audit stop`
  pause it without a rebuild. `janus audit start` refuses when the
  configuration did not include the feature. The file is JSON Lines
  (one object per line). The log is metadata for the owner (for example,
  checking whether a LAN device reports home to an unexpected network).
  It is not a packet capture, and Janus does not analyse it on the board.

## 9. Support bundle

`janus support-bundle` collects redacted status, rendered configs (secrets
scrubbed), journal excerpts and `build.json` into a tarball for bug reports.
