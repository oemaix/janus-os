# 20 — Maintenance page

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.3.0 |
| Last updated | 2026-10-20 |

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
both are set, and when `passphraseSecret` has no `sops.secrets.<name>.sopsFile`.
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

The login box has the hostname, the certificate fingerprint, and one
row action: the field `passphrase` with `enter` at the end of that row.
There is no username and no second factor. The row rules are §7.4. The
patterns are §7.5.

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
counter is global. A failed login shows `rejected`. During the lockout
it shows `closed`. Both words follow the page language (§7).

A mutation requires the cookie and the header `X-Janus: 1`. The page
script sends that header. GET reads require the cookie.

## 4. Sections

One column of three bands (§7.4). The middle band is a fixed row of
section names. A section is omitted when its subject is absent (proxy
disabled, no LAN, no Wi-Fi AP, no audit in the image). The order does
not change. Where each action sits is §7.5.

| Section | Contents | Actions |
|---------|----------|---------|
| `status` | The fields of `janus status`: one row per WAN (name, up or down, address), one row per LAN (name, lease count), engine, one row per group (name, selected node), last subscription refresh, last Geo refresh, drift, state-partition use, power readings when a `power` peripheral exists | none |
| `tunnel` | Groups, strategy, current node, members, subscription names | `refresh` every subscription, `geo`, `test` on a group, `select` by pressing a member, `refresh` one subscription |
| `network` | One typed WAN name, LAN names from the image | `show` and `restart` that WAN. `leases` for one LAN. |
| `overrides` | Allowlist rows in §5 | `set`, `unset` |
| `monitoring` | `janus traffic`, `janus dns stats`, and one audit line from `janus audit status` when that feature is in the image | `traffic`, `daily`, `monthly`, and `top` when the scope is `per-host`. `stats`, `check`, `flush`. `query` for one name. |
| `system` | `janus version --components` | `reboot` |

`status` refreshes every 10 seconds while it is the open section and the
browser tab is visible. Other sections load on entry and again after an
action.

`janus traffic top` is requested only when `janus.monitoring.scope` is
`per-host`. Otherwise the monitoring section shows the scope and no top
table.

The audit line is recording on or off, path, and size. The page does not
export the log and does not start or stop recording.

An action shows the catalog word `running`, then `ok` or the CLI error
text. `running` and `ok` follow the page language. The CLI error text
does not. There is no progress graphic.

`reboot` asks for the Latin word `reboot` in a field, in every language.
Any other text does nothing. The page has no factory reset, no backup,
no restore, and no secret install.

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

One column. One console. Light and dark share the geometry. Rectangles
have no radius, no shadow, no gradient, and no icon. The page loads no
webfont and no face from the router. The browser supplies the stack.

### 7.1 Palette

`bg` is the page. `raised` is a box, a field, and a resting control.
`fg` is text. `frame` is the box border and the control border. `line`
is a row rule. `inverse-bg` and `inverse-fg` are the active control.

| Token | Dark | Light |
|-------|------|-------|
| `bg` | `#002b36` | `#fdf6e3` |
| `raised` | `#073642` | `#eee8d5` |
| `fg` | `#93a1a1` | `#586e75` |
| `line` | `#586e75` | `#93a1a1` |
| `frame` | `#93a1a1` | `#586e75` |
| `inverse-bg` | `#eee8d5` | `#586e75` |
| `inverse-fg` | `#002b36` | `#fdf6e3` |

Accents are text and the focus ring. Each accent has one hex for the
dark canvas and one for the light canvas, so a 15px word stays readable
on `bg`. Orange, magenta, and violet are reserved. The page does not use
them.

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| `blue` | `#3b94d2` | `#0674c2` | Hostname, focus ring |
| `cyan` | `#2aa198` | `#217d76` | Certificate fingerprint |
| `green` | `#859900` | `#687800` | `ok`, `up` |
| `yellow` | `#b58900` | `#8f6c00` | `running` |
| `red` | `#f9514e` | `#d5302d` | `alarm`, `down`, `rejected`, `closed`, `failed`, the reboot control |
| `orange` | `#e76630` | `#c44915` | Reserved |
| `magenta` | `#ec549d` | `#cb347d` | Reserved |
| `violet` | `#7e84e6` | `#4f55c4` | Reserved |

The open section, the active theme, the active language, and the
selected node are `inverse-bg` with `inverse-fg`. Every other control is
`raised` with `fg` and a 1px `frame`.

A healthy top bar shows `ok` in `green`. A fault shows `alarm` in `red`,
and the `status` box frame becomes 2px `red`. Every other frame is 1px
`frame`. A row rule is 1px `line`. Focus is 2px `blue`, square to the
control, with no offset and no glow.

`up` is `green`. `down` is `red`. `running` is `yellow`. The reboot
control is `red` text and a 1px `red` frame on `raised`. That control is
the danger exception. A hostname value is `blue`. The fingerprint is
`cyan`. Every other value is `fg`.

### 7.2 Type

English and Russian use the mono stack. Persian chrome uses the Arabic
stack, because a mono face does not join Arabic letters. Weight and size
are a scale.

| Stack | Faces |
|-------|-------|
| Mono | `ui-monospace, "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", monospace` |
| Arabic | `"Noto Naskh Arabic", "Noto Sans Arabic", "DejaVu Sans", sans-serif` |

The mono stack sets `font-variant-ligatures: none`. Letter-spacing on
the wordmark is `0.06em`, and on a box heading `0.04em`. The Arabic
stack uses `0`. Letter-spacing on joined Arabic letters is a bug.

| Role | Size | Weight | Line height |
|------|------|--------|-------------|
| Wordmark `janus` | 16px | 650 | 1.2 |
| Controls | 14px | 550 | 1.2 |
| Box heading | 12px | 650 | 1.2 |
| Rows | 15px | 450 | 1.45 |
| Fingerprint and `pre` | 13px | 450 | 1.4 |

These stay on the mono stack in Persian too, and they stay left to
right: the wordmark, a hostname, a fingerprint, an address, a MAC, a
key, a node name, an interface name, a strategy name, a typed field, and
CLI error text.

### 7.3 Case

Latin chrome is lowercase, the same words as the CLI. Russian chrome is
lowercase. Persian has no case.

A hostname is not chrome. The page prints the spelling from the
configuration or from the lease, including its letters' case. `potato`
stays `potato`. The page does not print `POTATO` or `Potato`. The label
is the catalog word `host`. The value is `blue` and mono. The same rule
covers the router hostname, a static-lease host, and a DHCP hostname.
The page does not list the fleet. `janus-build fleet` stays on the build
host.

`wan`, `lan`, `mac`, `ip`, and `dns` stay Latin tokens in every language.
Digits are Western `0-9`. The page does not substitute Eastern digits.

### 7.4 Bands and rows

The signed-in page is three bands in one column. A band does not share
a line with another band.

| Band | What it holds |
|------|----------------|
| Bar | The wordmark, the alarm word, the theme choice, the language choice. |
| Strip | The section choice. Exactly one section is open. An omitted section is not drawn. |
| Box | The open section. Its first line is the section name. |

The result line sits between the strip and the box. It is empty until an
action. The pressed control shows `running` until the action returns,
then its own label again. The result line is where `ok` or the CLI error
text stays. The CLI error text is not translated (§7.7).

The column is at most `72ch`, at the start, with `16px` padding. Text
aligns to the start. The page does not justify. The bar's bottom edge is
a `frame` rule, and the strip sits on that edge. `12px` separates the
strip from the result line, and the result line from the box. The box
padding is `12px`. A row rule is `line` and spans the tracks inside that
padding.

The bar is one line. When it does not fit, the theme choice and the
language choice wrap together onto the next line of the bar, at the end
edge. The strip stays the band below. The strip is as wide as its
controls. It does not draw an empty segment past the last one.

A row has three tracks. The label track is `12rem`. The value track
takes the rest. The action track is as wide as the widest row action in
that box, and a shorter row action stretches to that width. The gap is
`16px`. Below `36rem` the row is one track: label, then value, then
action.

A label does not break. A strip control does not break; the strip wraps
by whole control. A value may wrap. A single token wider than the value
track breaks anywhere. Hyphenation is off.

A read-only value may contain a catalog word and a datum. That is one
value, not a second field. On a status row, `node` and the node name are
one value.

The fingerprint is continuous hex. The page inserts a wrap opportunity
after every four digits. That opportunity is not a character. A selection
copies the same line as `janus web fingerprint`.

A `pre` block spans all three tracks, keeps its spaces, and wraps
(`white-space: pre-wrap`).

Keyboard order is the document order: the bar, the strip, then the open
box from top to bottom.

### 7.5 Controls

Inverse means the current choice. It does not mark the last press.
Theme, language, the open section, and the selected node are inverse.
An action button returns to a resting control when the action returns.

Every control is one of these patterns.

| Pattern | Shape | Rule |
|---------|-------|------|
| Choice | Segments that share edges. One segment is inverse. | Theme, language, and the strip. A member list is a choice whose labels are data, drawn in the value track. |
| Read-only row | Label, then a value across the value track and the action track. | No button. |
| Row action | Label, one field in the value track, one action in the action track. | The action applies to that field. The action is one button, or one segmented group of buttons that all apply to that same field. A field that a section action reads leaves the action track empty. |
| Pair | Two or more rows. The action is only on the last. Earlier rows leave the action track empty. | The action applies to every field in the pair. The fields still share a width. An empty required field does nothing. |
| Section action | Buttons in the value track, under the heading and before the rows. | No field of their own. Buttons that share a subject share edges. None stays inverse. |
| Secret | A read-only row, then a row action. | The read-only value is `image` or `override`. The field is write-only and starts empty. The page never shows the stored value. Both rows use the same name as the label. |
| Danger | A row action drawn in `red`, then a hint. | The hint is the next row: an empty label, and the hint in the value track. The button does nothing until the field is the required word. |

A choice with no entries is omitted, and so is its row. A group with no
members keeps its head and `test`, and draws no member choice.

| Place | Pattern |
|-------|---------|
| Login | Read-only `host`. Read-only `fingerprint`. Row action `passphrase` with `enter`. There is no strip. The result line sits under the passphrase row. `rejected` and `closed` use it. |
| `status` | Read-only rows only. One row per WAN: label `wan` and the name, value `up` or `down` and the address. One row per LAN: label `lan` and the name, value `leases` and the count. Then `engine`, `refresh`, `geo`, `drift`, `state`, and `power` when a reading exists. One row per group: label `group` and the name, value `node` and the node name. |
| `tunnel` | Section actions `refresh` and `geo`, sharing edges. `refresh` here has no field and refreshes every subscription. Each group is a row action: the label is the group name, the value is the strategy, the action is `test`. Under that row, the members are a choice in the value track. The current node is inverse. Activating a member runs `select`. The button text is the node name. There is no second form for typing a group and a node. One row action `subscription`: the field is a choice of names, the action is `refresh` for that name only. The same catalog word as the section action. The place is the difference. No subscription omits that row. |
| `network` | Row action `wan`. The field is the typed name. The action is the segmented pair `show` and `restart`. Row action `lan`. The field is a choice of LAN names from the image facts. The action is `leases`. No LAN omits that row. |
| `overrides` | Each subscription and each Wi-Fi AP is a secret. A lease is a pair: `lease` (a LAN choice), `host`, `mac`, and `ip`, with `set` only on the `ip` row. An empty host, MAC, or address does nothing. Row action `unset`: the field is the key. |
| `monitoring` | Read-only `scope`. The `iface` row is a field and no action. An empty field means every interface. Section actions `traffic`, `daily`, and `monthly` share edges and use that field. `top` joins that group only when the scope is `per-host`. A second group, sharing edges among itself: `stats`, `check`, `flush`. Row action `name` with `query`. Read-only `audit` when that feature is in the image. |
| `system` | The version is a `pre` block. Danger: label `reboot`, the confirmation field, the red `reboot` button. The hint row is `reboot-hint`. The button runs only when the field is the Latin word `reboot`. |

### 7.6 Direction, theme, and language

`en` and `ru` set `dir="ltr"`. `fa` sets `dir="rtl"` and `lang="fa"`.
Spacing and alignment use logical properties (`padding-inline`,
`text-align: start`, `margin-inline`). The column sits on the start edge,
which is the right edge in Persian. The section order in the document
does not change, so `status` is the first control at that edge.

A value is a bidi isolate. Identifiers, addresses, the fingerprint, and
typed fields are `dir="ltr"` inside that isolate, so an address does not
reverse. The passphrase field and the reboot field are left to right.

The first visit follows `prefers-color-scheme`. The theme control is
`light` then `dark`, stored in the browser under `janus-theme`. The
language control is `en`, `ru`, `fa`, in that order, stored under
`janus-lang`. The tags are the labels. They are not translated. The first
visit walks `navigator.languages` and takes the first primary tag among
`en`, `ru`, and `fa`. Otherwise it is `en`. The language does not follow
`janus.system.region`. The router stores neither choice, and neither
choice takes a rebuild.

Theme is one segmented control. Language is a second. `16px` separates
them. Segments share edges. The active segment is inverse.

### 7.7 Strings

The catalog is the whole visible vocabulary. A visible word that is not
a key below, and is not data, is a bug. Data is not translated: hostnames,
node names, interface names, group names, subscription names, Wi-Fi names,
strategy names, scope values, and CLI `message` text. The page maps a body
that is exactly `ok`, `failed`, `rejected`, `closed`, `alarm`, or `running`
through the catalog. Any longer message is shown as the CLI wrote it, in
mono, left to right.

The wordmark `janus` is Latin in every language. The confirmation the
reboot field accepts is the Latin word `reboot`. The label and the hint
are translated. The button shows the catalog word. `select` is not a
drawn label. A member button shows the node name.

| Key | English | Russian | Persian |
|-----|---------|---------|---------|
| `light` | light | светлая | روشن |
| `dark` | dark | тёмная | تیره |
| `host` | host | хост | میزبان |
| `fingerprint` | fingerprint | отпечаток | اثرانگشت |
| `passphrase` | passphrase | пароль | گذرواژه |
| `enter` | enter | войти | ورود |
| `rejected` | rejected | отказано | رد شد |
| `closed` | closed | закрыто | بسته |
| `status` | status | состояние | وضعیت |
| `tunnel` | tunnel | туннель | تونل |
| `network` | network | сеть | شبکه |
| `overrides` | overrides | переопределения | بازنویسی |
| `monitoring` | monitoring | мониторинг | پایش |
| `system` | system | система | سیستم |
| `refresh` | refresh | обновить | تازه‌سازی |
| `geo` | geo | гео | ژئو |
| `subscription` | subscription | подписка | اشتراک |
| `group` | group | группа | گروه |
| `node` | node | узел | گره |
| `select` | select | выбрать | انتخاب |
| `test` | test | тест | آزمون |
| `show` | show | показать | نمایش |
| `restart` | restart | перезапустить | شروع دوباره |
| `leases` | leases | аренды | اجاره‌ها |
| `lease` | lease | аренда | اجاره |
| `set` | set | задать | ثبت |
| `unset` | unset | снять | برداشتن |
| `scope` | scope | охват | دامنه |
| `iface` | iface | интерфейс | رابط |
| `traffic` | traffic | трафик | ترافیک |
| `daily` | daily | сутки | روزانه |
| `monthly` | monthly | месяц | ماهانه |
| `top` | top | топ | برترین |
| `stats` | stats | статистика | آمار |
| `check` | check | проверить | بررسی |
| `flush` | flush | сбросить | تخلیه |
| `name` | name | имя | نام |
| `query` | query | запрос | پرس‌وجو |
| `audit` | audit | аудит | بازبینی |
| `reboot` | reboot | перезагрузка | راه‌اندازی دوباره |
| `reboot-hint` | type reboot | введите reboot | کلمه reboot را بنویسید |
| `ok` | ok | ок | سالم |
| `alarm` | alarm | сбой | هشدار |
| `up` | up | вкл | وصل |
| `down` | down | выкл | قطع |
| `running` | running | идёт | در حال اجرا |
| `failed` | failed | ошибка | ناموفق |
| `image` | image | образ | تصویر |
| `override` | override | замена | بازنویسی |
| `script` | this page needs the browser script | этой странице нужен сценарий браузера | این صفحه به اسکریپت مرورگر نیاز دارد |

### 7.8 Picture

Brackets are the inverse control. A field is drawn as dots. `potato` is
`blue`. The fingerprint is `cyan`. On the signed-in bar, `ok` is
`green`. `enter` is a resting row action, on the passphrase row.

```
+------------------------------------------------------------------+
| janus                         [light] dark    [en] ru  fa        |
+------------------------------------------------------------------+
| host              potato                                         |
| fingerprint       aabbccdd                                       |
|                   eeff00112233                                   |
| passphrase        ..............                       enter     |
+------------------------------------------------------------------+
```

```
+------------------------------------------------------------------+
| janus          ok             [light] dark    [en] ru  fa        |
+------------------------------------------------------------------+
| [status]  tunnel  network  overrides  monitoring  system         |
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

`node` and `Tokyo` on the status row are one value. The tunnel box puts
section actions in the value track. They are not inverse. `Tokyo` is
the current member. `refresh` on the subscription row is the one-name
action, not the section action.

```
+------------------------------------------------------------------+
| tunnel                                                           |
|------------------------------------------------------------------|
|                   refresh  geo                                   |
|------------------------------------------------------------------|
| proxy             url-test                             test      |
|                   [Tokyo]  Osaka                                 |
| subscription      main                                refresh    |
+------------------------------------------------------------------+
```

In Persian the same blocks sit on the right. `potato`, the fingerprint,
and `203.0.113.10` stay left to right.

## 8. Out of scope

* A general configuration GUI. New subscriptions, LANs, port forwards,
  routing rules, firewall, board, and engine stay a rebuild.
* Factory reset, backup, restore, age-key install, `override show
  --secrets`, audit export, and `janus logs -f`.
* Stopping the listener from the page. That switch is `janus web stop`
  over SSH.
* A rounded corner, a shadow, a gradient, a webfont, an icon, or a script
  loaded from another host.
* A meaning for `orange`, `magenta`, or `violet`. Those tokens stay reserved.
* A fleet list on this page, and a theme or a language stored on the router.
* A phone layout with different sections.
