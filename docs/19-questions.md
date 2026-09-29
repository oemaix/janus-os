# 19 — Questions

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-29 |

These answers explain a choice that already binds somewhere else. The
cited ADR, requirement, or section is that place. This list does not
add a second statement of the choice. Choices that are not ADRs are *18*.

Each question is `Q-nnnn`. The number is assigned once and is not reused.

| # | Question | Answer |
|---|----------|--------|
| Q-0001 | Why embed the whole flake tree, not only `configuration.nix`? | Modular configs import by relative path, and a rebuild needs the lock file. Files outside the tree are not captured. See D-0002. |
| Q-0002 | Can subscription updates go through `nixos-rebuild` on the board? | No. Changes are maintenance actions, hot overrides, or a rebuild on the build host. See ADR-0017. |
| Q-0003 | Why not reuse NetworkManager profiles? | NetworkManager is built for a host, not for router zones. Janus lowers to networkd and nftables. See ADR-0004. |
| Q-0004 | Which DNS policies can a user ask for, and what is `forwarders`? | The knobs in *07* §7.2 stay. Each LAN picks a named policy. `forwarders` is a per-domain upstream, not a second policy. |
| Q-0005 | Can the user pick sing-box or Xray? | Yes. One canonical model, two renderers, sing-box by default. See ADR-0006. |
| Q-0006 | Should matchers and tooling move to Go because the engines are Go? | No. Janet stays. The engines are not libraries the router links. See ADR-0008 and ADR-0020. |
| Q-0007 | Are subscription URLs secrets? | Yes. They go through sops-nix and age. The Wi-Fi SSID is not a secret. Node lists stay volatile data. See ADR-0014. |
| Q-0008 | Where does DNS policy run? | Inside the selected engine. Fake-IP is `auto`, `on`, or `off`. See ADR-0019. |
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
