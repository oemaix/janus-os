# 20 — Maintenance page

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-17 |

The maintenance page is the browser surface deferred by ADR-0007 and
bounded by FR-ACC-005 and D-0012. It calls the `janus` commands in *14*.
It does not replace SSH, and it does not edit `configuration.nix`.

1.0 ships without this page. An image includes it only when
`janus.access.web.enable` is set.

## 1. Build switch and runtime switch

| Option | Type | Default | Meaning |
|--------|------|---------|---------|
| `janus.access.web.enable` | bool | `false` | Include the page, the listener, and the firewall hole in the image. |
| `janus.access.web.port` | int | `8443` | TLS port. |
| `janus.access.web.zones` | list | `["lan" "mgmt"]` | Zones that may open the port. |
| `janus.access.web.passphraseSecret` | str | — | sops secret name. One line in `secrets/web/<host>.yaml`, encrypted to that host (ADR-0023). |
| `janus.access.web.passphraseFile` | path | — | File from `janus secrets put`. |

When `enable` is true, exactly one of `passphraseSecret` and
`passphraseFile` is set. Evaluation fails when neither is set, when
both are set, and when `passphraseSecret` is not a `sops.secrets` name.
Evaluation fails when `zones` contains `wan`. `guest` and `iot` are
reached only when the list names them.

The option is the image. A second switch is the running listener, the
same shape as `janus audit` (D-0018).

| Command | Effect |
|---------|--------|
| `janus web start` | Remove `/var/lib/janus/web/paused` and start the listener. Exit `2` when this image was built with `enable = false`. |
| `janus web stop` | Create that file and stop the listener. The option stays set. |
| `janus web status` | Listening or stopped, port, zones, certificate fingerprint. |
| `janus web fingerprint` | SHA-256 of the certificate, one line. Exit `2` when the page is not in the image. |

A missing paused file means listen. The first boot of an image that
includes the page listens. `janus web stop` survives reboot because the
file is on the state partition. Stopping the listener does not remove
the passphrase or the certificate. The CLI keeps working while the
listener is stopped.

`janus web start` with a missing or empty passphrase file exits `1` and
does not listen. The service condition is the same check, so boot does
not restart the unit.

## 2. Listener

Two processes, one service pair.

| Process | Role |
|---------|------|
| `stunnel` | TLS on `web.port`, IPv4 and IPv6. Forwards cleartext HTTP to the socket below. |
| `janus-web` | Janet program `janet/web.janet`. HTTP/1.1 on `/run/janus-web/http.sock`, mode `0660`. |

`janus-web` is the page. stunnel is the TLS boundary. The image does not
gain nginx, Caddy, or lighttpd for this feature. Janet is the tooling
language (ADR-0008, ADR-0020). The page does not implement TLS itself.

Nothing accepts plaintext HTTP. There is no redirect from port 80.

The firewall accepts `web.port` on `web.zones` and drops it on every
other interface, the same confinement as the Prometheus port (*06*).

The certificate is created on first start when it is absent:
`/var/lib/janus/web/cert.pem` and `key.pem`. The directory is mode
`0751`, owner `root`, group `janus-web-tls`, so the page user can walk
in and read the certificate. The certificate is mode `0644`. The key is
mode `0640` and readable by group `janus-web-tls` only. `/var/lib/janus`
stays mode `0755` so that directory remains reachable. The certificate
is self-signed. The subject is the hostname. Subject alternative names
are the hostname and each configured LAN address. The certificate is
not in the Nix store. There is no ACME client.

The operator compares the fingerprint on the login box with
`janus web fingerprint` over SSH before typing the passphrase.

The service user is `janus-web`. It is not root. It may run only the
`janus --json` argument lists in §6, through the scoped sudo policy in
*11* §4.1. Request bodies are not logged. The log line is method, path,
and status.

## 3. Login

SSH stays public-key only (ADR-0007). The page passphrase is a different
secret from `janus.access.ssh.rootPasswordFile`. Setting the page does
not enable SSH password authentication.

The browser has no SSH key, so the key is not the page login. A person
who still has the key and has lost the passphrase runs `janus-build
secret set secrets/web/<host>.yaml`, commits, and deploys. `janus secrets
put` remains when the new passphrase must not enter git; that path is
`passphraseFile`. Losing both the key and the passphrase means a new
image, the same outcome as losing the key.

The login box has the hostname, the certificate fingerprint, one field
`passphrase`, and the button `enter`. There is no username and no second
factor.

A matching passphrase sets a cookie:

| Attribute | Value |
|-----------|-------|
| Name | `janus_session` |
| Flags | `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/` |
| Idle | 12 hours, sliding |

The token is 32 random bytes. The server stores only its SHA-256, under
`/run/janus-web/sessions`. Reboot clears sessions. At most eight sessions
exist; a ninth drops the oldest.

Five failed attempts close login for 60 seconds for every client. The
counter is global.

A mutation requires the cookie and the header `X-Janus: 1`. The page
script sends that header. GET reads require the cookie.

## 4. Sections

One column. A fixed row of section names. A section is omitted when its
subject is absent (proxy disabled, no LAN, no Wi-Fi AP, no audit in the
image). The order does not change.

| Section | Contents | Actions |
|---------|----------|---------|
| `status` | The fields of `janus status`: one row per WAN (name, up or down, address), one row per LAN (name, lease count), engine, selected node per group, last subscription refresh, last Geo refresh, drift, state-partition use, power readings when a `power` peripheral exists | none |
| `tunnel` | Groups, strategy, current node, members | `refresh`, `refresh` one subscription, Geo refresh, `select`, `test` |
| `network` | `janus wan show`, DHCP leases | `restart` one WAN |
| `overrides` | Allowlist rows in §5 | `set`, `unset` |
| `monitoring` | `janus traffic`, `janus dns stats`, and one audit line from `janus audit status` when that feature is in the image | `dns check`, `dns query`, `dns flush`. Traffic period `daily` or `monthly`. |
| `system` | `janus version --components` | `reboot` |

`status` refreshes every 10 seconds while it is the open section and the
browser tab is visible. Other sections load on entry and again after an
action.

`janus traffic top` is requested only when `janus.monitoring.scope` is
`per-host`. Otherwise the monitoring section shows the scope and no top
table.

The audit line is recording on or off, path, and size. The page does not
export the log and does not start or stop recording.

An action shows the word `running`, then `ok` or the CLI error text.
There is no progress graphic.

`reboot` asks for the word `reboot` in a field. Any other text does
nothing. The page has no factory reset, no backup, no restore, and no
secret install.

## 5. Hot overrides

The allowlist is *14* §3. The page refuses every other key and names the
rebuild, the same refusal as the CLI.

| Key | What the page shows | How a new value is sent |
|-----|---------------------|-------------------------|
| `proxy.subscriptions.<existing>.url` | The subscription name, and `image` or `override`. The URL is a secret and is not shown. | stdin of `janus override set`. Not an argument. |
| `network.lans.<existing>.dhcp.staticLeases.<host>` | Hostname, MAC, and address. These are not secrets. | `janus override set` with `--mac` and `--ip` |
| `network.wifi.<existing>.passphrase` | The AP name, and `image` or `override`. The passphrase is not shown. | stdin of `janus override set`. Not an argument. |

`unset` removes that override. A secret field is write-only. The
response does not contain the value. The process list does not contain
it.

## 6. Routes

The HTML is one file from the Nix store: `GET /` and `GET /login`. No
other static path exists. The file embeds its script and its style.
Nothing is fetched from the network. There is no package registry and no
web font. The login document carries the hostname and the certificate
fingerprint. Subscription names, LAN addresses, Wi-Fi names, and the
other image facts are `GET /api/meta`, which requires the session cookie
and runs no `janus` command.

Every API path runs one fixed argument list. The server does not build a
shell command. Names and keys are checked against the allowlist shapes
before exec; the CLI checks again.

| Request | Command |
|---------|---------|
| `GET /api/meta` | No command. Image facts other than the login fingerprint. |
| `GET /api/status` | `janus --json status` |
| `GET /api/proxy/groups` | `janus --json proxy groups` |
| `POST /api/proxy/refresh` | `janus --json proxy refresh [name]` |
| `POST /api/proxy/geodata/refresh` | `janus --json proxy geodata refresh` |
| `POST /api/proxy/select` | `janus --json proxy select <group> <node>` |
| `POST /api/proxy/test` | `janus --json proxy test <group>` |
| `POST /api/wan/restart` | `janus --json wan restart <name>` |
| `GET /api/wan/show` | `janus --json wan show <name>` |
| `GET /api/lan/leases` | `janus --json lan leases [lan]` |
| `GET /api/traffic` | `janus --json traffic [iface] [--daily\|--monthly]` |
| `GET /api/traffic/top` | `janus --json traffic top` |
| `POST /api/dns/query` | `janus --json dns query <name>` |
| `POST /api/dns/flush` | `janus --json dns flush` |
| `GET /api/dns/stats` | `janus --json dns stats` |
| `POST /api/dns/check` | `janus --json dns check` |
| `GET /api/override` | `janus --json override show` |
| `POST /api/override` | `janus --json override set …` |
| `POST /api/override/unset` | `janus --json override unset <key>` |
| `GET /api/version` | `janus --json version --components` |
| `POST /api/reboot` | `janus reboot`, and only when the body confirm field is `reboot` |
| `GET /api/audit` | `janus --json audit status` |

Exit `0` is HTTP 200 and the CLI JSON. Exit `2` is HTTP 400. Exit `1` is
HTTP 409. Both error bodies are `{ "exit", "message" }` with the CLI
text. A missing session is HTTP 401. Any other path is HTTP 404.

`POST /login` takes the field `passphrase`. Success redirects to `/`.

## 7. Appearance

One layout. Two colors. Rectangles with no radius, no shadow, no
gradient, and no icon.

| Token | Light | Dark |
|-------|-------|------|
| Paper | `#ffffff` | `#111111` |
| Ink | `#111111` | `#eeeeee` |

Text, borders, and fills use paper and ink only. An alarm does not add a
hue. While `janus status` reports a fault, the `status` box border is
2px. Every other border is 1px solid ink.

Light and dark are that pair swapped. The geometry does not change. The
first visit follows `prefers-color-scheme`. The top bar has two controls,
`light` and `dark`. The choice is stored in the browser under
`janus-theme`. The router does not store it, and it does not take a
rebuild.

The active section, the active theme, and the selected node are ink
fill with paper text. Every other control is paper with ink text and a
1px border.

| Property | Value |
|----------|-------|
| Column | at most `40rem`, aligned to the start, padding 16px |
| Font | `ui-sans-serif, system-ui, sans-serif` at 16px |
| Values | `ui-monospace, monospace` for addresses, names, keys, fingerprints, and typed input |
| Focus | 2px solid ink, no offset, no glow |
| Narrow window | The section controls wrap. The page stays one column. |

```
+------------------------------------------------------------------+
| janus          ok                              [light]  dark     |
+------------------------------------------------------------------+
| [status]  tunnel   network   overrides   monitoring   system     |
+------------------------------------------------------------------+
| status                                                           |
|------------------------------------------------------------------|
| wan main          up        203.0.113.10                         |
| lan home          leases    4                                    |
| engine            active                                         |
| group proxy       node      Tokyo                                |
| refresh           ok                                             |
| geo               ok                                             |
| drift             no                                             |
| state             12%                                            |
+------------------------------------------------------------------+
```

Brackets in the picture are the ink-filled control. The login box is the
same rectangle, with the fingerprint on its own row and `enter` under
the field.

The page language is English, the same words as the CLI.

## 8. Out of scope

* A general configuration GUI. New subscriptions, LANs, port forwards,
  routing rules, firewall, board, and engine stay a rebuild.
* Factory reset, backup, restore, age-key install, `override show
  --secrets`, audit export, and `janus logs -f`.
* Stopping the listener from the page. That switch is `janus web stop`
  over SSH.
* A third color, a rounded corner, a webfont, an icon, or a script loaded
  from another host.
* Translated page strings. The manual languages do not add a second page.
* A phone layout with different sections.
