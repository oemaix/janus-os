# Tests

Phase 0 checks:

* `checks.<system>.eval-*` — a minimal `x86_64-test` configuration
  evaluates, and known-bad configurations do not.
* `packages.<system>.docs-options` — the `janus.*` option reference.
* `checks.x86_64-linux.vm-x86_64-test` — the image boots. `/` and `/nix`
  are read-only, `/var` is read-write, `machine-id` is bind-mounted, and
  the seed stamp matches the embedded hash. A disk 256 MiB larger grows
  the state filesystem. A wiped state partition is reformatted and still
  boots. `extlinux.conf` and `cmdline.txt` name `init=`.

CI runs the eval checks and the options document
(`.github/workflows/eval.yml`). The VM check builds a system image.

Golden files for nftables, networkd, and the engines are still absent.
Do not add a test that treats an unlowered option as a working router.
