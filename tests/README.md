# Tests

Phase 1 checks:

* `checks.<system>.eval-*` — configurations evaluate, including the
  phase 1 board profiles (`eval-boards`), and known-bad configurations
  do not.
* `packages.<system>.docs-options` — the `janus.*` option reference.
* `checks.x86_64-linux.vm-x86_64-test` — the image boots. `/` and `/nix`
  are read-only, `/var` is read-write, `machine-id` is bind-mounted, and
  the seed stamp matches the embedded hash. A disk 256 MiB larger grows
  the state filesystem. A wiped state partition is reformatted and still
  boots. `extlinux.conf` and `cmdline.txt` name `init=`.
* `checks.x86_64-linux.vm-x86_64-net` — a second guest on the LAN takes a
  DHCPv4 lease, reaches the host through NAT, resolves `vm.test`, and
  sees SSH open on the LAN and closed on the WAN.

CI runs the eval checks and the options document
(`.github/workflows/eval.yml`). The VM check builds a system image.

`limine-bios` runs the image builder's Limine scripts on a GPT disk with
FAT32 and checks that QEMU BIOS loads the kernel file. `eval-router` checks the generated nftables masquerade, the DHCP client,
dnsmasq, OpenSSH, and vnstat. `eval-hmi` checks the panel model, the
Waveshare binding, and `janus reset --state` without `--yes`. It compiles
the panel for the machine running the check. `eval-power` checks the cell
cutoff and compiles the Raspberry Pi overlay with that machine's `dtc`.
`eval-power-x86` keeps the INA219 on `x86_64-test` and does not install a
device-tree overlay. `eval-proxy-local` fetches a page through the
rendered Shadowsocks outbound and a server on `127.0.0.1`. `cli-usage`
and `cli-init` cover the phase 1 commands. Golden files for the engines
are still absent.
