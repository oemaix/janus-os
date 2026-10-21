# 11 — Security Model

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-10-17 |

## 1. Assets

| Asset | Why it matters |
|-------|----------------|
| Node credentials, subscription URLs | Leakage burns paid relays and identifies the user as a circumvention user |
| PPPoE / Wi-Fi / WireGuard secrets | Account and network takeover |
| LAN hosts | Router is the perimeter |
| DNS queries and traffic metadata | Primary surveillance vector, especially over IPv6 |
| Router availability | Household connectivity; state partition integrity |
| Build host | Compromise yields a malicious image with full trust |

## 2. Adversaries

| Adversary | Capability | In scope |
|-----------|------------|----------|
| Carrier / national filter | Observe and inject on WAN, poison DNS, block endpoints, fingerprint TLS, log IPv6 addresses | yes |
| LAN guest / compromised IoT | Lateral movement, DNS bypass, ARP tricks | yes |
| Internet scanner | Probe WAN ports | yes |
| Physical attacker with the SD card | Read all data on the card | partially (see §7) |
| Malicious subscription provider | Feed hostile node lists / oversized data | yes |
| Compromised build host | Anything | out of scope; documented as trust root |

## 3. Trust boundaries

```
[build host] --image/closure--> [Board: ro store]  --> [state partition rw]
                                      │
              LAN zones (lan/guest/iot) │ mgmt zone (tailscale)  wan zone
```

* The store is trusted (it is the image). The state partition is
  *untrusted data*: everything read from it is schema-validated (subscription
  JSON, Geo data sizes/formats, selection files).
* Zones define network trust. Nothing listens on `wan` by default.

## 4. Controls

### 4.1 Access

* SSH: public key only; ≥1 key required at evaluation (FR-ACC-001/002).
  `PermitRootLogin prohibit-password`, modern ciphers/KEX only, no
  agent/X11 forwarding, `MaxAuthTries 3`, rate-limited in nftables.
* Password login: opt-in; requires an existing key; a root password hash
  file on the state partition is used, never an inline plaintext.
* `janus` CLI is the only privileged operator tool; runs via `sudo` policies
  scoped to specific systemd units and files (no general shell needed for
  daily tasks, but root shell remains available to the key holder).
* Maintenance page (*20*): off unless `janus.access.web.enable` is set.
  TLS only, `lan` and `mgmt` by default, never `wan`. Login is a passphrase,
  not the root password, and it does not turn on SSH password
  authentication. The passphrase is a per-host sops file (§4.3). The
  service user `janus-web` may run only the `janus` argument lists in
  *20* §6.

### 4.2 Services

* Every Janus service runs as a dedicated user with systemd hardening
  (`ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`,
  `CapabilityBoundingSet` limited to `CAP_NET_ADMIN`/`CAP_NET_RAW`/
  `CAP_NET_BIND_SERVICE` where needed, `RestrictAddressFamilies`,
  `SystemCallFilter=@system-service`).
  `janus-web` is the exception to `NoNewPrivileges`: it runs `janus`
  through the setuid sudo wrapper (*20* §6). `NoNewPrivileges` would
  mount that namespace `nosuid`, and the wrapper could not become root.
  The bounding set omits `CAP_SYS_ADMIN`, so that root child cannot
  remount the namespace. Janet is the main process and sends readiness
  itself (`NotifyAccess=main`).
* The proxy engine runs as `janus-engine` with `CAP_NET_ADMIN` (TUN),
  `CAP_NET_BIND_SERVICE`, and `CAP_NET_RAW`. It may write only
  `/var/lib/janus/engine`. A root oneshot renders the configuration,
  because that step reads secret files, then the engine reads the result.
  The engine waits up to 90 s for time sync and then starts anyway.
* `janus-persist-etc` and `janus-deploy-rollback` are not sandboxed.
  They bind-mount state into `/etc` and remount `/boot` or `/nix`.
* No telemetry: engines' and tools' reporting features are compiled out or
  disabled (FR-SEC-011); NTP and Geo/subscription refresh are the only
  router-initiated outbound connections besides user tunnels.

### 4.3 Secrets

sops-nix with age is the default (ADR-0014, ADR-0022). Ciphertext lives
in the private config repo, one credential per file under `secrets/`
(*08* §11). Each router has its own age keypair. `janus-build secret
keygen <host>` creates it outside the Nix build. The public key is
committed at `secrets/keys/<host>.pub`. The private key is installed on
that router's state partition and is not retained on the build host.
The password manager is the backup copy. The build host encrypts to
public keys and cannot decrypt the files.

The repo is the ciphertext a boot can decrypt. It is not the plaintext
credential store. A changed Wi-Fi passphrase, PPPoE password, Tailscale
auth key, subscription URL, or maintenance-page passphrase is supplied
again through `janus-build secret set`. Boot-time activation decrypts
into `/run/secrets` (tmpfs).
The Nix store holds ciphertext only. The private key is not a build
output.

A file under `subscription/` or `nodes/` is encrypted to every host that
references it. Any of those routers can read it. A file under `wifi/`,
`pppoe/`, `tailscale/`, `wireguard/`, or `web/` is encrypted to that
host only.

| Secret | In sops | Notes |
|--------|---------|-------|
| PPPoE username and password | yes | Username is low sensitivity but paired with the password; keep both together. |
| Wi-Fi passphrase | yes | SSID is not a secret; it is broadcast. |
| Subscription URL | yes | The node list is volatile data; the URL usually embeds a token and is not. A hot override may replace the URL on the board (mode `0600`) until the user updates sops. |
| Manual node credentials (UUID, password, REALITY keys) | yes | |
| WireGuard private key, mesh auth key | yes | |
| Maintenance page passphrase | yes | One line in `secrets/web/<host>.yaml`, encrypted to that host (ADR-0023). Not the SSH root password. `passphraseFile` remains for a file created on the board. |
| SSH host keys | no | Generated on first boot, stored under `/var/lib/janus/etc`. Not the age key. |
| Age private key | no | One per router, on that router's state partition. The build host does not keep it. Whoever has the SD card can read it and the ciphertext encrypted to that router. Disk encryption is not in scope (see §5). |

| Style | Where the secret ends up | Use when |
|-------|--------------------------|----------|
| sops-nix | ciphertext in git and in the store; plaintext in `/run/secrets` | default |
| File (`janus secrets put`) | state partition, `0600` | a secret created on the board, or a hot-override passphrase |
| Inline (`password = "…"`) | world-readable `/nix/store` | lab only; `janus.security.allowInlineSecrets = true` |

agenix was rejected as the default: it solves the same problem with a
narrower tool, and sops-nix is the one NixOS operators already have in a
multi-host repo. A user MAY use agenix via plain NixOS options; Janus does
not document two first-class paths.

### 4.4 Network

* Default-deny inbound on `wan` and IPv6; stateful firewall; anti-spoofing
  (`rp_filter` loose on multi-WAN, strict otherwise; nftables `fib` checks).
* RA-guard and DHCP-server-guard on LAN bridges (drop RAs/DHCP offers from
  LAN hosts) to prevent rogue routers.
* Guest/IoT LAN: bridge port isolation, no inter-zone forwarding, only
  DHCP/DNS/ICMP to the router.
* Plaintext DNS from LAN redirected to the router; DoT blocked by default;
  known-DoH endpoints blockable (policy) so devices cannot bypass split DNS.
* Engine egress marked and routed to avoid loops; interception fails closed:
  if the engine is down, proxied LANs lose Internet for proxied destinations
  rather than leaking directly (`janus.proxy.failMode = "closed" | "open"`,
  default `closed`).

### 4.5 Privacy over IPv6 (FR-SEC-010)

* Router addresses: RFC 7217 stable-privacy, never EUI-64.
* LAN default `disabled` when tunneling; `delegated` requires tunnel-aware
  interception; optional NPTv6 to hide prefix stability from remote sites.
* AAAA stripping for proxied domains prevents hosts from preferring a direct
  IPv6 path around the tunnel. The default `strip-for-proxied` withholds a
  globally routable AAAA from a proxied name. An address in the IPv6
  fake-IP range is not that leak. A direct name keeps a real AAAA.
  `keep` allows the leak (D-0038).
* Documentation states clearly that host-side privacy extensions are the
  host's choice; Janus can only avoid handing hosts a global prefix.

### 4.6 TLS fingerprinting resistance

* uTLS fingerprints (`chrome` default) for VLESS/Trojan; REALITY with
  believable `serverName`; Vision to avoid TLS-in-TLS patterns.
* Time is a dependency for TLS: engine start waits (bounded) for
  `time-sync.target`; NTP is reachable directly (plain NTP is not blocked in
  the reference environment) and via the tunnel as fallback.

### 4.7 Supply chain

* nixpkgs pinned by hash; engines from nixpkgs or Janus overlay pinned by
  source hash; Geo data pinned by version + hash for pure builds.
* `build.json` in every image records inputs; `nix flake metadata` reproduces
  them.
* Subscriptions are inherently untrusted input: size caps (1 MiB default),
  schema validation, protocol allow-list, refusal of nodes pointing at
  private/loopback addresses unless explicitly allowed.

## 5. Residual risks

* Anyone with the SD card can read that router's age private key and every
  secret encrypted to it, including shared subscription and node files
  (no disk encryption). Mitigation: physical control; future LUKS with
  TPM/OTP is not realistic on these boards. Another router's per-host
  secrets stay ciphertext.
* A backup archive from `janus backup` contains the age private key.
  Leaving that archive on the build host restores decrypt capability for
  that router. `fleet pull --with-secrets` and `secret rewrap` also put
  plaintext in the SSH session.
* A rogue subscription can direct traffic to attacker-controlled relays;
  this is inherent to the subscription model. Mitigation: per-subscription
  `allowedServers`/`allowedPorts` filters (P2), and TLS verification never
  disabled by default (`tls.insecure` prints a warning).
* Traffic analysis of the tunnel itself (volume/timing) is out of scope.

## 6. Security update policy

Janus has no on-device updates by design. Security fixes ship as new
releases; users rebuild. The changelog flags CVE-driven releases, and the
`janus` CLI can print the image's component versions for comparison
(`janus version --components`).
