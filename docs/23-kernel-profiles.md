# 23 — Kernel profiles

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-11-14 |

This document explains how `janus.system.kernelProfile` is built.
The principles of the `matched` cut are §2.
The option contract is *08* §1. The binding choices are D-0051 and
D-0052. A failure that shows up only in a later build or boot is *22*.
This file does not add a choice. When it and a decision disagree, the
decision wins.

## 1. The three values

`standard` is the NixOS kernel. Janus adds no kernel patch, so aarch64
and x86_64 keep the binary cache.

`compact` is one config for every board. It drops a subsystem only when
no household router board, current or later, has a use for it. The
patch is `janus-kernel-compact`.

`matched` starts from that cut, then keeps a driver only when this
board or a declared peripheral uses it. It is one config per board.
The patch is `janus-kernel-matched`. The SoC-platform cut belongs here.
`compact` stays one kernel.

Both cuts are `boot.kernelPatches` on the NixOS kernel. They do not
switch the tree to a downstream defconfig.

## 2. Principles of the matched cut

`matched` is a deny list with explicit keepers, on top of `compact`.
The principles below restate D-0051 and D-0052. A change that breaks
one of them is a change of those decisions, not a local cleanup.

1. **Stay on the NixOS kernel.** The cut is a patch on the NixOS
   config. It does not switch the tree to a downstream defconfig.
   `standard` adds no patch, so aarch64 and x86_64 keep the binary
   cache.

2. **Share the subsystem cut. Match the board.** `compact` is one
   kernel for every board. `matched` includes that cut, then applies
   a second cut for this board and its declared peripherals. The SoC
   platforms and the per-driver restore belong only to `matched`.
   Putting them on `compact` would build a different kernel per board.

3. **Drop foreign SoC platforms first.** Each board keeps one vendor
   platform. The Raspberry Pi boards keep `ARCH_BCM` and
   `ARCH_BCM2835`. The NanoPi R4S and the ROCK Pi 4C keep
   `ARCH_ROCKCHIP`. Le Potato keeps `ARCH_MESON`. The VisionFive 2
   keeps `SOC_STARFIVE`. The Yanyu and `x86_64-test` receive no ARM
   or RISC-V platform symbol. A hidden symbol that follows a prompt
   is not named. One kept vendor still builds that vendor's other
   SoCs: an RK3399 board still builds the RK3562 clock. Clocks inside
   a vendor are not listed. A menu the kept platform does not select
   is forced on when the board needs it. Le Potato forces `PINCTRL`
   and `RESET_CONTROLLER`.

4. **Drop subsystems no router board uses.** This is the `compact`
   cut, and `matched` includes it. The subsystems are sound, desktop
   and 3D GPUs, compute accelerators, cameras and TV, HDMI-CEC and
   infrared remotes, industrial I/O and Comedi, InfiniBand, and SAN
   (Fibre Channel, FCoE, iSCSI, SAS RAID, the SCSI target, and
   NVMe-oF). Display is two steps. `compact` still keeps simpledrm,
   the virtio and bochs display, and SoC scanout that does not depend
   on ALSA. Pi HDMI depends on ALSA, so it is not in that set. The
   consoles are serial. `matched` then turns `DRM` off except on
   `x86_64-test`, which keeps it for the virtio and bochs display.
   An HMI panel is not restored as a DRM panel. It is the SPI or I²C
   bus the panel uses.

5. **Start from off, and restore a driver from a declaration.** The
   catalogs list drivers the architecture defconfig turns on. They
   are optional `n` unless a keeper names them. A keeper is this
   board's own Ethernet or storage, or a peripheral the configuration
   declares: a USB id, a WWAN mode, an onboard radio with
   `match.onboard`, a Bluetooth dongle, an HMI bus, or an INA219.
   An undeclared device stays out. Onboard Bluetooth UART comes back
   only when playback is `bluetooth`.

6. **Restore the device, not the subsystem.** A feature turns on the
   driver it uses. `janus.audio.enable` with an embedded or USB
   device turns `SOUND` back on and then only that device's driver.
   Bluetooth playback does not turn sound on. One USB Wi-Fi stick
   does not enable every WLAN vendor. `x86_64-test` restores virtio
   net, virtio block, and the virtio and bochs display, and no other
   board does.

7. **Build in a driver the initrd cannot load.** An MMC host that
   `boot.initrd.availableKernelModules` does not list stays `y`.
   Forcing it to `m` leaves the root disk with no driver until the
   module would have to be loaded from that disk.

8. **Name a driver the platform cut does not hide.** Turning a SoC
   platform off does not hide a driver that depends only on
   `ARM64`, on `DRM`, or on `ARM_SCMI_PROTOCOL`. `autoModules` would
   build that driver as `m`. Those survivors are named `n`. Nixpkgs
   restates some answers in a string after the structured set. The
   last line wins, so a board that does not use that answer repeats
   it as optional `n`.

9. **Do not fight Kconfig.** A `select` holds its target. Turn the
   selector off, or keep the target. Optional `n` is the answer when
   the question may disappear. Required `n` is reserved for a parent
   that must fail the build if a `select` turns it back on. An answer
   of `n` is legal only when the prompt offers `n`.

## 3. Files

| File | Role |
|------|------|
| `modules/janus/system/kernel-profile.nix` | The option, the `compact` lists, and the patch |
| `modules/janus/system/kernel-matched.nix` | The per-board keepers. A pure function of the board, the peripherals, and the audio flags. No `pkgs` |
| `modules/janus/system/kernel-compact-arm64-defconfig.patch` | Drops the HiSilicon SAS and MPT SAS lines from the arm64 defconfig seed |
| `tests/eval.nix` | `eval-kernel-profile` and `eval-kernel-profile-matched` read the Nix attribute set |
| `tests/kernel-config.nix` | `eval-kernel-config` runs `generate-config.pl` and reads the `.config` |

`kernel-matched.nix` returns `{ symbols, extraConfig }`. The profile
module merges `symbols` on top of the compact set and appends
`extraConfig` only for `matched`.

## 4. How an answer reaches `.config`

NixOS renders `structuredExtraConfig` to lines such as `FOO y` or
`FOO? n`. `generate-config.pl` then answers `make config`. The last
line for a symbol wins. A `?` is optional: a symbol that was not asked
is a warning. Without `?`, the same case is `error: unused option`
and the build stops (T-0001, T-0003).

The pieces are appended in this order:

1. Nixpkgs `common-config.nix`, as structured settings.
2. The Janus patch `structuredExtraConfig`. `mkForce` replaces a
   common-config value.
3. `stdenv.hostPlatform.linux-kernel.extraConfig`, a string. On
   aarch64 this restates the Pi firmware, ThunderX ECAM, and Tegra
   PCIe answers.
4. The patch `extraConfig` string. This is the last word (T-0041).

The profile uses four answers:

| Helper | Line | Use |
|--------|------|-----|
| `deny` | `FOO n` | A parent that must stay off. A later `select` that turns it back on fails the config |
| `forceOff` / `off` | `FOO? n` | A child that may disappear once its parent is `n` |
| `asMod` | `FOO m` | A driver this board loads |
| `asYes` | `FOO y` | A bool, or a driver the initrd does not list as a module |
| `clear` | unset | A freeform integer whose question disappears with its parent |

`autoModules` and `preferBuiltin` are on for the NixOS ARM and RISC-V
platforms. A tristate whose prompt default is `n`, shown as
`[N/m/y/?]`, is answered `m` unless Janus names it. A prompt that
shows a capital `Y` stays built in. Two passes run. Answering `n`
when the alternatives have no `n` repeats the question and stops the
script. `select` holds the target at `y` or `m`; turn the selector
off, or keep the target (T-0002).

## 5. `compact`

The cut applies for both `compact` and `matched`.

Required `n` on the parents: `SOUND`, `IIO`, `COMEDI`, `INFINIBAND`,
`MEDIA_SUPPORT`, `SCSI_SAS_ATTRS`, `SCSI_SAS_LIBSAS`. Optional `n` on
the children: desktop and 3D GPUs, compute accelerators, the sound
options common-config turns on, cameras and TV, HDMI-CEC and infrared
remotes, and SAN (Fibre Channel, FCoE, iSCSI, SAS RAID, the SCSI
target, NVMe-oF). `SND_AC97_POWER_SAVE_DEFAULT` and
`SND_HDA_POWER_SAVE_DEFAULT` are cleared because `n` is not an answer
for those integers.

The arm64 defconfig patch exists because HiSilicon SAS and MPT SAS
`select` the SAS transport before its question. Two passes then leave
the transport `y` after the HBAs are turned off (T-0001).

What stays is the same on every board: NIC drivers, Wi-Fi, USB, WWAN,
Bluetooth, MMC, the NVMe host, AHCI, f2fs, vfat, virtio, simpledrm,
and SoC scanout that does not depend on ALSA. Raspberry Pi HDMI
(`DRM_VC4`) depends on `SND`, so it is not in the GPU list. The board
consoles are serial. Rockchip and Meson scanout stay in `compact`.
`matched` turns them off later.

## 6. `matched`

The function builds catalogs of drivers the architecture defconfig
turns on. A keeper is removed from the catalog and then forced to `m`
or `y`. Everything else in the catalog is optional `n`. A symbol this
architecture does not ask is a warning, so one catalog can cover
aarch64, armv7, riscv64, and x86_64.

The board implies the architecture. ARM and RISC-V platform symbols
are not emitted for the Yanyu or for `x86_64-test`.

### 6.1 SoC platforms

One vendor platform stays. That vendor's other SoCs stay with it.
An RK3399 board still builds the RK3562 clock. The profile does not
name `CLK_RK*`.

| Boards | Kept |
|--------|------|
| Raspberry Pi Zero 2 W, Pi 2, Pi 3, Pi 4 | `ARCH_BCM`, `ARCH_BCM2835` |
| NanoPi R4S, ROCK Pi 4C | `ARCH_ROCKCHIP` |
| Le Potato | `ARCH_MESON` |
| VisionFive 2 | `SOC_STARFIVE` |
| Yanyu, `x86_64-test` | no ARM or RISC-V platform symbol |

Hidden symbols are not named. `ARCH_STARFIVE` follows
`SOC_STARFIVE`. On arm64, `ARCH_MICROCHIP` has no prompt. On armv7,
`ARCH_BCM_IPROC` and `ARCH_BCM_MOBILE` have no prompt. Sibling
platforms under a kept menu are named and set `n`. Under `ARCH_BCM`
that is every Broadcom SoC other than `ARCH_BCM2835`.

`ARCH_MESON` selects neither `PINCTRL` nor
`ARCH_HAS_RESET_CONTROLLER`. Le Potato forces both `y`, or the GXL
pinctrl and reset drivers are not asked (T-0041).

### 6.2 The Nixpkgs platform string

On aarch64 the platform string sets the Pi firmware, the mini UART,
`PCI_HOST_THUNDER_ECAM`, `PCI_TEGRA`, and `USB_XHCI_TEGRA` after the
structured set. `matched` repeats the ones this board does not use as
`SYMBOL? n` in the patch `extraConfig`. The Pi boards keep the
firmware and the mini UART: that console is `ttyS0`.
`PCI_HOST_THUNDER_PEM` is `y` in the arm64 defconfig and is not in
the platform string, so structured optional `n` is enough.

### 6.3 What a platform `n` does not hide

`autoModules` still builds a tristate that depends only on `ARM64`,
on `DRM`, or on `ARM_SCMI_PROTOCOL` (T-0042).

`matched` sets `SPMI` `n` and the i.MX SCMI extensions `n` on ARM and
RISC-V. `DRM` is `n` except on `x86_64-test`, which keeps it for the
virtio and bochs display. The common-config DRM children that then
stop being asked (`DRM_FBDEV_EMULATION`, `DRM_LOAD_EDID_FIRMWARE`,
`DRM_DISPLAY_DP_AUX_CHARDEV`, `DRM_PANIC` and its screen, `DRM_NOVA`)
are optional `n`. The same pass covers `FSL_MC_UAPI_SUPPORT` once
`ARCH_LAYERSCAPE` is `n`, and `SUN8I_DE2_CCU` once `ARCH_SUNXI` is
`n`.

HMI panels are not `DRM_PANEL_*`. `sh1106`, `st7789`, and the e-paper
HAT keep `SPI_BCM2835` and `SPI_SPIDEV`. `ssd1306` and the INA219 keep
`I2C_BCM2835`.

### 6.4 Board and peripheral keepers

A keeper is added only from the board or from a declared peripheral.
The catalogs in `kernel-matched.nix` are the full deny list. The
keepers are:

| Input | What stays |
|-------|------------|
| Onboard Ethernet | `E1000E` on the Yanyu, `R8169` on the NanoPi R4S, `BCMGENET` on the Pi 4, `DWMAC_ROCKCHIP` on the RK3399 boards, `DWMAC_MESON` on Le Potato, `DWMAC_STARFIVE` on the VisionFive 2, and that MAC's PHY |
| Storage | MMC on the boards that boot from it. NVMe on the ROCK Pi 4C and the VisionFive 2. AHCI and USB storage on the Yanyu |
| USB NIC, USB Wi-Fi, WWAN mode | The driver for that id or mode. Huawei `12d1:1506` in `ncm` also keeps `huawei_cdc_ncm` |
| Onboard radio | `BRCMFMAC` when `match.onboard` is set. `0bda:8176` keeps `rtl8xxxu` and leaves `rtl8192cu` off |
| Bluetooth dongle | `BT_HCIBTUSB` when a `bluetooth` peripheral is declared |
| Onboard Bluetooth | `BT_HCIUART` when `janus.audio.enable` is true and playback is `bluetooth`, on the Zero 2 W, the Pi 3, the Pi 4, and the ROCK Pi 4C |
| `x86_64-test` | virtio net, virtio block, virtio SCSI, and the virtio and bochs display |

An MMC host the initrd does not list stays built in: `MMC_MESON_GX`
on Le Potato, `MMC_BCM2835` on the Zero 2 W and the Pi 3, and
`MMC_SDHCI_IPROC` on the Pi 4. The Arasan host on the Zero 2 W and
the Pi 3 is the radio SDIO and is `m` only when that radio is
declared. The Pi 2 lists both hosts in the initrd, so both are
modules (T-0005, T-0007). The Pi 4 USB 3 controller sits behind
`PCIE_BRCMSTB`. That symbol defaults to `ARCH_BRCMSTB`, which this
profile turns off. The initrd lists `pcie_brcmstb`, so the driver is
`m` on the Pi 4 and `n` on the other boards (T-0043).

### 6.5 Sound

`compact` leaves `SOUND` `n`. `matched` applies the sound catalog
only when `janus.audio.enable` selects an embedded or USB device.
The catalog is then optional `n` except that device's driver.
Bluetooth playback does not turn `SOUND` on. `DRM_VC4` stays `n`
even when the Pi sound driver is on. `SND_SOC_ROCKCHIP` is not a
symbol on 6.18 and is not set (T-0018).

## 7. Checks

The attribute-set checks read `structuredExtraConfig` and the patch
`extraConfig`. They do not run `generate-config.pl`. A keeper that
is only `y` in the defconfig seed is invisible there, so the platform
keepers are also forced `y` in the set.

`eval-kernel-config` builds the `.config`. `off` accepts `n` or an
absent line, because a child is not asked once its parent is `n`.
The `compact` checks still expect `DRM_ROCKCHIP` and `DRM_MESON` on.
A new file is invisible to the flake until `git add` (T-0008).
