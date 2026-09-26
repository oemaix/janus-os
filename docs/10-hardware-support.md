# 10 — Hardware Support

| Field | Value |
|-------|-------|
| Status | Draft |
| Version | 0.1.0 |
| Last updated | 2026-09-26 |

## 1. Terminology

* **Board** — the single-board computer running Janus OS.
* **Peripheral** — an add-on device attached to a Board.

(These replace "device" and "add-on" from the requirement note.)

## 2. Support tiers

| Tier | Meaning |
|------|---------|
| **1** | Release-blocking. Image built and boot/route-tested for every release on hardware the project can power-cycle; power-cut test performed. Binary cache available. Tier 1 does not mean every board meets the NanoPi R4S throughput targets. |
| **2** | Image built in CI for every release; boot tested best-effort by maintainers or community. |
| **3** | Board profile exists; builds may take hours (no binary cache); community-tested only. |

## 3. Boards

| Board | SoC / Arch | Ports | Tier | Notes |
|-------|------------|-------|------|-------|
| **NanoPi R4S** | RK3399 · aarch64 | 2× 1 GbE (RTL8211E + RTL8111H/PCIe) | 1 | Reference router board. Mainline U-Boot at raw offset (sector 64); GPT. No Wi-Fi. |
| **Raspberry Pi 4 / 400 / CM4** | BCM2711 · aarch64 | 1× 1 GbE (+ USB 3 NICs) | 1 | Firmware needs FAT boot partition with `config.txt`; boots via U-Boot or directly. On-board Wi-Fi (AP capable, 2.4/5 GHz). Not in the owner's current lab list (U8). |
| **Raspberry Pi 3 / 3+** | BCM2837 · aarch64 | 1× 100 MbE (USB 2 shared) | 2 | Low throughput; fine for tunnel-only use behind another router. |
| **Raspberry Pi Zero 2 W** | BCM2710A1 · aarch64 | Wi-Fi 4 + Bluetooth, no Ethernet | 1 | Owner's lab. 512 MiB RAM. Needs a USB Ethernet peripheral for a wired WAN or LAN. On-board Wi-Fi and Bluetooth need the redistributable closed Broadcom firmware (FR-HW-006). Not a 500-node target. INA219 UPS overlay is part of this board's lab setup (FR-HW-008). |
| **Libre Computer Le Potato (AML-S905X-CC)** | S905X · aarch64 | 1× 100 MbE | 1 | Owner's lab. Mainline U-Boot with FIP at raw offset; eMMC or SD. Lab peripherals: Fibocom NL668 (U2), RTL8188CUS (U3), CSR Bluetooth. |
| **StarFive VisionFive 2** | JH7110 · riscv64 | 2× 1 GbE | 3 | Needs recent kernel; SPL + U-Boot in dedicated GPT partitions (types `2E54B353…`, `BC13C2FF…`); no binary cache. |
| **Raspberry Pi 2 (v1.1)** | BCM2836 · armv7l | 1× 100 MbE | 3 | 32-bit; no cache; RPi 2 v1.2 is BCM2837 and uses the `rpi3` profile. |
| **Yanyu STX-R19F** (`yanyu-stx-r19f`) | Intel Celeron J1900 (Bay Trail-D) · x86_64 | 4× Intel 82583V GbE on PCIe, SATA SSD. No Wi-Fi, Bluetooth, or WWAN. | 1 | Lab reference x86 board. Legacy AMI BIOS, GRUB, 4 GiB RAM. Case-label map is U1. |
| **`x86_64-test`** | QEMU | virtio NICs | — | CI/VM test target only, not for deployment. |

Each board profile (`modules/boards/<board>.nix`) provides:

* kernel package/config and device trees; redistributable firmware, including closed blobs when the board does not work without them;
* boot method and boot partition contents (FAT layout, `extlinux.conf`,
  U-Boot binaries, raw offsets `firmwareOffsetMiB`);
* partition table type (GPT/MBR/hybrid);
* default `janus.network.ports` mapping with human names (`wan`, `lan`);
* known quirks (e.g. R4S PCIe NIC MAC randomization → stable MAC derived
  from SoC serial; RPi USB NIC enumeration order → match by path);
* thermal/fan hooks if any; LEDs mapped to states (WAN up, tunnel healthy).

### 3.1 Yanyu STX-R19F

Measured on the lab unit (OpenWrt kernel 4.14, hostname Mercury).

| Item | Value |
|------|--------|
| CPU | Intel Celeron J1900 @ 1.99 GHz. 64-bit (`lm`). No `aes` in `/proc/cpuinfo` flags, so AES-NI is absent. |
| RAM | 4 GiB (`MemTotal` ≈ 3.75 GiB). The 500-node memory budget applies. |
| Firmware | American Megatrends 5.6.5, 2018-10-10. No `/sys/firmware/efi`: legacy BIOS only. DMI `board_vendor=YANYU`, `board_name=STX-R19F`. `sys_vendor` and `product_name` are the generic string `baytrail`. |
| Disk | Samsung SSD PM83, ≈ 32 GB, kernel name `sda` on the E3800 SATA AHCI controller. The image is written over the whole disk. The OpenWrt squashfs partition table is not kept. |
| Boot | GRUB for legacy BIOS (`boot.loader.grub.device` on the disk). UEFI and systemd-boot do not apply. Consoles: `tty0` and `ttyS0,115200n8` (16550A at I/O `0x3f8`). `/dev/rtc0` exists. No `/dev/watchdog`. |
| NICs | Four Intel 82583V, driver `e1000e`, PCIe x1 Gen2, one function behind each root port. Probe order on that kernel: `01:00.0`, `02:00.0`, `03:00.0`, `04:00.0`. The profile matches these PCI paths and does not use the names `eth0`–`eth3`. MACs on the lab unit are sequential; they are not part of the profile. |
| Absent | USB peripherals, Wi-Fi, Bluetooth, WWAN. The only USB device besides the root hub is the onboard Intel function `8087:07e6`. |

Until U1 is filled in, the profile exposes the four ports as `nic1`–`nic4` in PCI order and does not declare which one is WAN.

## 4. Peripherals

### 4.1 Classes

| Class | Purpose | Backing software |
|-------|---------|------------------|
| `nic` | Additional Ethernet port (USB 3 GbE, USB 2.5 GbE) | kernel drivers (`r8152`, `ax88179`, `aqc111`); udev naming |
| `wifi` | Access point for a LAN (STA/uplink mode out of scope for 1.0) | `hostapd`, mac80211 drivers; firmware from `linux-firmware` |
| `wwan` | 4G/5G uplink | `usb_modeswitch`, kernel `cdc_ether`/`cdc_ncm`/`rndis_host`/`qmi_wwan`/`cdc_mbim`; `libqmi`/`libmbim` CLIs; optional ModemManager |
| `bluetooth` | Present on the allowlist. No routing feature is assigned yet (U5). | BlueZ (optional, off by default) |
| `hmi` | Small LCD/OLED/e-ink status display, optional buttons | `janus-hmi` daemon (framebuffer/SPI drivers), `gpio-keys` |
| `power` | Battery voltage, current, power (INA219) | in-tree `ti,ina219` hwmon; a generated device-tree overlay on boards that need one |

### 4.2 WWAN model

A 4G dongle is *one Peripheral of class `wwan`* regardless of how it
presents itself. The `wwan.mode` selects the data-plane driver; the control
plane (AT over USB serial, QMI, MBIM) is optional and used for status only
(signal, operator, SIM state, data usage), never for routing decisions.

| Mode | Data plane | Appears as | Control plane |
|------|------------|------------|---------------|
| `ecm` / `ncm` / `rndis` | dongle does NAT/DHCP internally or bridges | Ethernet NIC → treated by networkd as a DHCP client link | AT port (`/dev/ttyUSB<n>`), if exposed after mode switch |
| `qmi` | raw-IP via `qmi_wwan` | `wwan0` | `qmicli` for connect/status |
| `mbim` | `cdc_mbim` | `wwan0` | `mbimcli` |

The board-agnostic module handles mode switching (`usb_modeswitch` rules
from the allowlist only), link bring-up per mode, and health reporting
into `/run/janus/wwan/<name>`. A WAN with `mode = "wwan"` references the
peripheral; internally it becomes a `dhcp` WAN (Ethernet modes) or a
QMI/MBIM-managed link.

Support is an allowlist (FR-HW-007). Many dongles implement several USB
compositions and only one of them is reliable; some need vendor tools or
a sequence that breaks on the next firmware. Those devices are out of
scope. A USB ID that is not in §4.3 fails evaluation. Users do not get a
generic "try AT commands until it connects" path.

### 4.3 Support matrix (initial)

| Peripheral | IDs | Class | Status |
|------------|-----|-------|--------|
| Realtek RTL8153 USB 3 GbE | `0bda:8153` | nic | supported |
| Realtek RTL8156 USB 2.5 GbE | `0bda:8156` | nic | supported |
| ASIX AX88179 | `0b95:1790` | nic | supported |
| MediaTek MT7612U (e.g. Alfa AWUS036ACM) | `0e8d:7612` | wifi (AP 2.4/5) | supported |
| MediaTek MT7921AU | `0e8d:7961` | wifi (AP) | supported (recent kernel) |
| Realtek RTL8812AU | `0bda:8812` | wifi | unsupported (out-of-tree driver) |
| Realtek RTL8188CUS | `0bda:8176` | wifi | lab device on Le Potato; AP vs station undecided (U3). No out-of-tree driver. |
| Fibocom NL668 | USB ID not yet recorded | wwan (LTE Cat.4) | lab device on Le Potato; mode undecided (U2) |
| EigenComm, exposed as a NIC | `19d1:0001` | wwan (ethernet mode, LTE Cat.1) | supported on Zero 2 W |
| mcuzone Pi Zero UPS (INA219) | I²C `0x40` | power | supported on Zero 2 W (FR-HW-008) |
| Waveshare Pi Zero UPS (INA219) | I²C `0x43` | power | supported; owner's board is the `0x40` profile |
| Huawei E3372h (HiLink) | `12d1:14dc` / `12d1:1f01` | wwan (ecm/rndis) | supported |
| Huawei E3372s (stick) | `12d1:1506` | wwan (ncm) + AT | supported |
| Quectel EC25 / EM12 (USB) | `2c7c:0125` / `2c7c:0512` | wwan (qmi) + AT | supported |
| ZTE MF833 | `19d2:1405` | wwan (rndis) | supported |
| Generic CSR BT 4.0 dongle | `0a12:0001` | bluetooth | supported; confirmed on Le Potato. Purpose undecided (U5). |
| SSD1306 128×64 I²C OLED | — | hmi | supported |
| Waveshare 2.13" e-Paper HAT | — | hmi | supported |
| ST7789 240×240 SPI LCD | — | hmi | planned |

Peripherals not in the matrix produce an evaluation warning (FR-HW-005);
users may add `hardware.firmware`/kernel modules via raw NixOS options.

## 5. Performance notes (guidance for NFR-004/005)

| Board | NAT (1500 B) | VLESS+Vision through tunnel | Note |
|-------|--------------|-----------------------------|------|
| NanoPi R4S | line rate 1 GbE | 300–500 Mbit/s | RK3399 crypto extensions help TLS |
| RPi 4 | ~900 Mbit/s | 200–350 Mbit/s | USB NIC for 2nd port costs CPU |
| RPi 3 | ~95 Mbit/s | 40–60 Mbit/s | USB 2 bus shared |
| RPi Zero 2 W | ~90 Mbit/s via USB NIC | 30–50 Mbit/s | 512 MiB RAM; Wi-Fi AP and a tunnel together are the tight case |
| VisionFive 2 | ~900 Mbit/s | untested | |
| Le Potato | ~95 Mbit/s | 40–60 Mbit/s | |
| Yanyu STX-R19F | untested; four native GbE ports | untested | J1900 has no AES-NI; expect ChaCha to beat AES |

Figures are targets to validate on the bench, not guarantees.

## 6. Adding a board (checklist for UC-14)

1. Create `modules/boards/<name>.nix` with the fields listed in §3.
2. Add the board to `janus.hardware.board` enum and to this matrix.
3. Add `checks.build-<name>`; for Tier 1/2 add a lab boot test entry.
4. Document quirks and default port naming in this file.
