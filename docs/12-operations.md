# 12 — Operations and Maintenance

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-15 |

## 1. The two kinds of change

| Kind | Examples | How it takes effect | Where it lives |
|------|----------|---------------------|----------------|
| **Configuration** | swap WAN/LAN ports, add a LAN, change traffic mode, add a subscription or manual node, change grouping/rules, enable a service | Edit `configuration.nix` on the build host → rebuild → deploy (re-flash or closure push) → reboot | Nix store (read-only) |
| **Data** | node lists fetched from subscriptions, Geo data, manual group selection, DHCP leases, statistics, secrets | Runtime refresh/reload, automatic on schedule or via `janus` CLI; no rebuild | State partition (`/var`) |

The requirement note asked whether *policy* changes (swap ports, add
subscription, update nodes, update Geo data) should all go through
`nixos-rebuild`. The answer this design gives: **definitions** are
configuration (rebuild), **contents** are data (refresh). Adding a
subscription URL is configuration; the nodes it yields are data. Swapping
ports is configuration. Updating Geo data is data. This keeps the Board free
of Nix evaluation while still letting relay lists stay fresh.

## 2. Day-0: first deployment

1. `nix flake init -t github:<org>/janus-os` on the build host.
2. Edit `configuration.nix` (board, ports, WAN, LAN, SSH key,
   subscriptions). Secrets referenced by `…File` paths are provisioned later.
3. `nix build .#images.<host>`; flash `result/janus-<host>.img`.
4. Boot; connect to LAN; `ssh root@192.168.10.1` (or the configured address).
5. Provision secrets: `janus secrets put pppoe < pppoe.txt`; PPPoE WAN comes
   up automatically when the file appears (`janus wan restart main`).
6. `janus status` — verify WAN, DNS, proxy health.

Alternative for step 5: `janus deploy --secrets ./secrets/ <host>` from the
build host pushes all secret files before/after flashing.

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
| Engine crash | systemd restart with backoff; `failMode` decides whether proxied LANs go direct meanwhile (default: closed) |
| WAN down | health check marks it; backup WAN promoted if configured; DNS keeps answering from cache |
| State partition corrupted | fsck; if unrecoverable, reformat and reseed (logged, HMI notice) |
| Time far off at boot (no RTC) | engine waits for NTP up to 90 s, then starts anyway; REALITY/TLS may fail until time syncs |
| Full state partition | bounded writers make this unlikely; `janus status` warns at 80 %; journal/vnstat rotate |

## 6. Upgrading Janus itself

1. On the build host: bump the `janus` flake input (`nix flake update
   janus`), read the changelog for option changes (deprecations produce
   evaluation warnings with the new option path).
2. Rebuild; deploy with `--preserve-state` (re-flash) or `janus deploy`
   (closure push, P2).
3. After boot, `janus status` and `janus version` confirm; if the new
   generation fails to boot, the previous one is offered once (closure push
   path) or re-flash the previous image (re-flash path).

## 7. Backup and restore

`janus backup > janus-state-$(date -I).tar.zst` archives secrets,
subscription cache, Geo data, selection, leases and statistics.
`janus restore < file` writes them back and reloads services. The
configuration itself is in git on the build host — that plus this archive
reproduces a router completely.

## 8. Monitoring integration

* Local: `janus traffic`, `janus status`, HMI pages.
* Remote (optional): IPFIX export to a collector in `mgmt`/LAN; Prometheus
  endpoint on `mgmt` zone; syslog forwarding via `journald` remote (P3).

## 9. Support bundle

`janus support-bundle` collects redacted status, rendered configs (secrets
scrubbed), journal excerpts and `build.json` into a tarball for bug reports.
