# 22 — Implementation tarpits

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-03 |

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
