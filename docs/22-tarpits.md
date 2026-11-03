# 22 — Implementation tarpits

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-04 |

A tarpit is a failure that looks like progress until a later build or
boot. The binding choice stays in the cited document. This list is the
constraint that choice ran into.

Each row is `T-nnnn`. The number is assigned once and is not reused. A
deleted number is not reused. `open` means the tree still hits the row.
`kept` means the code follows it. A `kept` row stays, so the next change
does not undo it.

| # | State | Trap |
|---|-------|------|
| T-0001 | kept | `generate-config.pl` gets two passes. Answering `n` when the alternatives have no `n` repeats the question and then ends the script (`Error in reading or end of file`). A required answer for a symbol that was not asked fails with `error: unused option`. An optional unused answer is a warning. The arm64 defconfig patch in `modules/janus/system/kernel-profile.nix` exists because a `select` kept the SAS transport `y` after the HBAs were turned off. |
| T-0002 | kept | `select` holds the target at `y` or `m`. Turning the target off while the selector stays on is T-0001. Seen on 6.18: `HIBMCGE` selects `MOTORCOMM_PHY`, `USB_NET_HUAWEI_CDC_NCM` selects `USB_WDM`, and `NET_DSA_REALTEK` selects `REALTEK_PHY`. Turn the selector off, or keep the target. |
| T-0003 | kept | Nixpkgs sets some children as required answers. Once the parent is `n` they are not asked, and the required answer fails the build. Replace that answer with optional `n` (`lib.kernel.option lib.kernel.no`). A hidden symbol is ignored. `RTW88_8822BE` and `RTW88_8822CE` stay required while `WLAN` is on, because no allowlisted stick uses `RTW88`. Optional `n` applies whenever `RTW88` is off, not only when every Wi-Fi driver is off. |
| T-0004 | kept | `SATA_MOBILE_LPM_POLICY` is an integer. Nixpkgs sets freeform `"3"`. `n` is not a legal answer. When AHCI is off, set optional freeform `"3"` so the hidden symbol is not a required unused option. |
| T-0005 | kept | A boot MMC host that `boot.initrd.availableKernelModules` does not list stays built in. Forcing a defconfig `y` to `m` leaves the root disk with no driver in the initrd. Le Potato: `MMC_MESON_GX`, and the initrd lists `mmc_block` only. Zero 2 W SD card: `MMC_BCM2835` (`sdhost`). `boot.initrd.allowMissingModules` defaults to false. A listed name with no `.ko` fails the image build. A built-in driver has no `.ko`, so listing that name also fails. See D-0052 and *10* §3.6 and §4.7. |
| T-0006 | kept | On the Zero 2 W, `sdhci_iproc` (`MMC_SDHCI_IPROC`) is the Arasan radio, not the SD card. The initrd does not list it. An access point loads `sdhci_iproc` with `brcmfmac` from `boot.kernelModules`. That option is an attribute set applied with `attrNames`, so the order written in Nix is not the load order. See *10* §4.7. |
| T-0007 | kept | On the Pi 3 and Pi 3+, the SD card is `sdhost` (`MMC_BCM2835`) and stays built in. The initrd lists neither `bcm2835` nor `sdhci_iproc`. `sdhci` is the radio SDIO and stays off: this profile has no onboard-radio peripheral. The boot files are `bcm2837-rpi-3-b.dtb` and `bcm2837-rpi-3-b-plus.dtb`. The Pi 4 card slot stays on `MMC_SDHCI_IPROC`. The Pi 2 initrd lists `bcm2835`, so that host is a module. See D-0052 and *10* §3. |
| T-0008 | kept | `eval-kernel-profile` and `eval-kernel-profile-matched` read the Nix attribute set. `generate-config.pl` runs in `eval-kernel-config`. A symbol assertion can require `=m` for a host the initrd does not load (T-0005). A new file is invisible to the flake until `git add`. A dirty edit of a tracked file is visible. Adding the file is not a commit. |
| T-0009 | kept | Huawei `12d1:1506` in `ncm` binds `huawei_cdc_ncm`. That driver selects `cdc_ncm` and `USB_WDM`. Loading `cdc_ncm` alone does not bind the stick. Leaving `USB_NET_HUAWEI_CDC_NCM` at its defconfig value while `USB_USBNET` is on still selects `USB_WDM` (T-0002). See *10* §4.2 and D-0052. |
| T-0010 | kept | The Soloist URLs on the downloads page have no version and are replaced in place. `flake.lock` pins each archive (`soloist-x86_64`, `soloist-aarch64`, `soloist-armv7l`). `nix flake update` moves the narHash. An unpinned fetch follows the URL and can install a build that was not locked. A locked build expires 90 days after its build date and the program exits 10, and the unit does not restart on that status. Update the lock before then. See D-0058. |
| T-0011 | kept | `matched` answers `BT_HCIUART_SERDEV` with optional `n` while the UART parent is off. Onboard Bluetooth needs that symbol and `BT_HCIUART_BCM` at `y`, or the controller does not bind. Set both when `playback.output` is `bluetooth`. Leaving `SERDEV` at `n` while `BT_HCIUART` is `m` looks configured and never probes. See D-0061. |
| T-0012 | kept | The ROCK Pi 4C blacklists `hci_uart`. Building `BT_HCIUART` does not start the onboard controller while that name is blacklisted. Drop the blacklist only when `playback.output` is `bluetooth`. `btusb` stays available for a dongle. See D-0053 and D-0061. |
| T-0013 | kept | `bluetoothctl pair` without `--agent NoInputNoOutput` does not finish Just Works pairing. The command has no terminal to confirm a prompt. A `scan on` that exits before `pair` also drops a speaker that is only discoverable briefly. Keep that agent on pair and connect when no code was given, and leave the scan running until pair returns. A code starts `janus-bt-agent` for that address only, after the scan is up, and stops it before connect. The code is stdin. The agent accepts authorization for that address and confirms a shown number only when it is the code. It exits when its parent exits. `bluetoothctl` itself does not accept the code. |
| T-0015 | kept | `pair` by name must use devices that appeared in that search. `bluetoothctl devices` is the cache and still holds a speaker that is not nearby. Pairing the cached name connects the wrong device. `connect`, `disconnect`, and `remove` still use the cache, because those speakers are already known. |
| T-0016 | kept | The maintenance page has one Janet thread. `os/execute` stalls every fiber for the whole command, so discovery and pairing freeze status and login. Spawn the command and wait with `os/proc-wait`, which suspends only the fiber that asked. |
| T-0017 | kept | `janus-bluetooth` has no local variables. `parse_scan` and `find_name` run in the same shell. `parse_scan` must not assign `name`. That variable is the name the operator asked to pair. Overwriting it makes the scanned speaker match itself, so a request for a different name still pairs the nearby device. |
| T-0014 | kept | The system PipeWire socket is `/run/pipewire-0`. A client with no `PIPEWIRE_RUNTIME_DIR` looks under `XDG_RUNTIME_DIR` and does not open that socket. Soloist and `wpctl` need `PIPEWIRE_RUNTIME_DIR=/run`. The Bluetooth path has no `playback.node`, so a missed socket is silence. |
