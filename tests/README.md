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
dnsmasq, OpenSSH, and vnstat. `eval-web` checks the maintenance page model, the TLS listener, and the
runtime pause. `eval-hmi` checks the panel model, the
Waveshare binding, and `janus reset --state` without `--yes`. It compiles
the panel and the SPI overlay for the machine running the check. `eval-boot-slot` checks that a Raspberry Pi `config.txt` follows slot B
onto `initrd-b` and back, that `kernel` and `initrd` symlinks are read
from the inactive slot store for both slots, and that a link leaving that
store is refused. `eval-deploy-slots` checks that a slot deploy
mounts the inactive store on `/run/janus-slot-nix` and remounts `/boot`
read-only when that step fails. `eval-power` checks the cell
cutoff and compiles the Raspberry Pi overlay with that machine's `dtc`.
`eval-power-x86` keeps the INA219 on `x86_64-test` and does not install a
device-tree overlay. `eval-monitoring` checks IPFIX and NetFlow export, resolution of
configured interface names, the Prometheus endpoint confined to its
zones, and the engine metrics text. `eval-rpi2-mbr` checks the hybrid
MBR type byte and the LBA fields. `eval-tier3-boot` checks that the
VisionFive boot files name the QSPI SPL and ITB and the QSPI size limits, that the Pi 2,
VisionFive, and NanoPi R4S device-tree names exist in the kernel source, that the VisionFive YT8531 receive-clock patch applies to that source with the flag in both init conditions, and that the compiled R4S SD node drops `sd-uhs-sdr104` and sets `no-1-8-v`. `eval-boards` includes the Raspberry
Pi 2, Raspberry Pi 4, and VisionFive 2 profiles. `eval-proxy-local` fetches a page through the
rendered Shadowsocks outbound and a server on `127.0.0.1`. `cli-usage`
and `cli-init` cover the phase 1 commands. Golden files for the engines
are still absent.
