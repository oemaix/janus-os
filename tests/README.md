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

CI runs the eval checks and the options document
(`.github/workflows/eval.yml`). The VM check builds a system image.

`limine-bios` runs the image builder's Limine scripts on a GPT disk with
FAT32 and checks that QEMU BIOS loads the kernel file. `eval-router` checks the generated nftables masquerade, the DHCP client,
dnsmasq, OpenSSH, and vnstat. `cli-usage` and `cli-init` cover the phase 1
commands. Golden files for the engines are still absent. A VM check does
not yet exchange DHCP or NAT traffic.
