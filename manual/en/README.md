# Janus OS

Janus OS does not ship a router system. You build your own: an image
on one computer, flashed to a small board. The image is NixOS. The
board does not build software and does not evaluate Nix. The computer
that builds the image needs Nix with flakes. It does not have to run
NixOS.

The project is public and licensed under the Apache License, Version 2.0.

## What you can do today

The router image boots in a VM. Image profiles exist for the NanoPi R4S,
the Le Potato, the Raspberry Pi Zero 2 W, the Raspberry Pi 3 / 3+, the
Raspberry Pi 2 v1.1, the StarFive VisionFive 2, and the Yanyu STX-R19F
(Limine on legacy BIOS). `janus` and `janus-build`
implement the phase 1 commands, plus proxy, DNS, fleet, status, backup,
deploy, and the connection audit. On the board, `janus deploy` exits 2
and names `janus-build`. A Waveshare 1.3" OLED HAT on a Raspberry Pi
Zero 2 W or a Raspberry Pi 3 shows status. From the panel you can refresh
the proxy, select a node, reboot, or wipe state. A mcuzone UPS on that
board can power it off while the cell is discharging.

A development shell exists for people working on the source: from a
clone of this repository, run `nix develop`. Operating a router does
not need that clone.

## Nix on the build machine

This project is a Nix flake. `nix run` and `nix flake` stay unavailable
until Nix is configured to allow them.

On a machine that is not NixOS, install Nix first:
<https://nixos.org/download/>.

A standard install still leaves the Nix command and flakes off. Add
this line to `/etc/nix/nix.conf`. A single-user install uses
`~/.config/nix/nix.conf` instead:

```
experimental-features = nix-command flakes
```

After editing `/etc/nix/nix.conf`, restart the daemon with
`sudo systemctl restart nix-daemon`. On NixOS, set the same switch in
the system configuration and rebuild:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

When `nix flake --help` prints usage, this step is already done.

## Create the fleet repository

`janus-build` is not installed on its own. The first command names the
Janus flake and creates the private directory:

```
nix run github:oemaix/janus-os#janus-build -- init ./fleet
```

A local clone is the same command with a directory in place of the
GitHub flake:

```
nix run ./janus-os#janus-build -- init ./fleet
```

`init` takes the new directory, `./fleet`. It does not take a flake
address. That address is the `nix run` target, and the new repository
pins the same Janus. Continue inside the fleet repository:

```
cd fleet
nix develop
```

`janus-build` is then on `PATH`.

## Build and flash

In that shell:

1. `janus-build host add <host>` names one board.
2. The host file sets the board, the WAN, and at least one LAN. Ports
   come from the board profile. Commit that host.
3. `janus-build secret keygen <host>` creates this router's age key.
   It writes the public key to `secrets/keys/<host>.pub` and prints the
   private key once. Store that private key in a password manager, such
   as KeePass. The build machine does not keep a copy, and the key does
   not go into git. Do this after the host exists and before the build.
4. `janus-build secret set <path>` encrypts each credential this host
   needs: a PPPoE password, a Wi-Fi passphrase, a subscription URL, or a
   manual node. The public key from the previous step must already exist.
5. `janus-build build <host>` writes `janus-<host>.img`. The image
   contains that ciphertext. It does not contain the private key.
6. Flash that image. The state partition starts empty.
7. SSH in as root with the key from the host configuration. There is no
   password login.
8. Install the private key from the password manager, once, with
   `janus-build deploy --age-key <host>` on the build machine.
   (`janus secrets install-age-key` on the router does the same thing.)
   PPPoE, Wi-Fi, and a subscription URL that is a secret stay unavailable
   until this step.
9. `janus proxy refresh` fills a subscription that came from `urlSecret`.
    Until the key is installed and that refresh runs, the snapshot is empty.

A host with no encrypted credential can skip the key, `secret set`, and
the install. LAN and SSH do not need the age key.

Option names are in
[docs/08-configuration-reference.md](../../docs/08-configuration-reference.md).
`janus-build check <host>` evaluates the configuration without building
the image.

## Day to day

`janus status` on the board reports the running system. Subscription
refresh, node selection, and DNS checks are `janus proxy` and `janus dns`.

These changes do not need a new image:

- the URL of a subscription that is already in the image
- a static lease on a LAN that is already in the image, including a new
  hostname
- the passphrase of a Wi-Fi network that is already in the image

`janus override show` lists them. `janus-build fleet pull` writes leases
back into the private repository. `janus-build fleet apply` pushes the
committed subscription URL, Wi-Fi passphrase, and leases. Anything else
in that commit is left for a deploy.

## Install a new system

Reflash `janus-<host>.img` when the partition layout changes.
`janus-build deploy --preserve-state <host>` copies the state set to the
build machine first. It does not flash. After the new image boots,
`janus restore` puts that archive back.

`janus-build deploy <host>` copies a new system closure and updates the
boot entry, then reboots. When the board is up, run
`janus-build deploy --confirm <host>`. Without that confirmation, the
next boot restores the previous boot entry.

A/B slots are off unless the image was built with
`janus.storage.slots.enable = true`. Flash that image once. Later
deploys write the other root and store slot, then change the boot entry.
The state partition is shared, so overrides and the age key stay. Confirm
the same way. If the new images do not fit the slots from the flash,
deploy stops and asks for a new flash. A disk flashed without the option
has no second slot; deploy says so.

## Connection audit

The audit is off unless the image sets `janus.monitoring.audit.enable =
true`. After that image boots, recording is on. `janus audit stop` pauses
it without a rebuild. `janus audit start` turns it back on. If the image
was built without the switch, `janus audit start` exits 2.

`janus audit status` prints whether recording is on, the path, the size,
and the oldest record. `janus audit export` prints the log. Each line is
one JSON object: protocol, source, destination, ports, byte count, start,
end, and a domain when the router already knows it. The file is
`/var/lib/janus/audit/connections.jsonl` on the state partition. The
default retention is 7 days. Copy the log off the board to read it.
Payloads are not stored, and the board does not analyse the log.

An empty interface list audits the proxied LANs. `audit.interfaces` names
LANs to audit instead.

## Status panel

A Waveshare 1.3" OLED HAT on a Raspberry Pi Zero 2 W or a Raspberry Pi 3
shows status. Name the peripheral in the host file:

```
janus.hardware.peripherals.panel = {
  class = "hmi";
  hmi.profile = "waveshare-1.3-oled-hat";
};
```

The joystick changes page and row. The centre press confirms a tunnel
node. KEY1 runs `janus proxy refresh`. Holding KEY3 for three seconds
runs `janus reboot`. `hmi.keys.KEY1`, `hmi.keys.KEY2`, and `hmi.keys.KEY3`
may be `refresh`, `reboot-hold`, `factory-reset`, or `unbound`.
`factory-reset` runs `janus reset --state --yes`, which wipes the state
partition and reboots. The panel does not change the configuration, hot
overrides, or secrets. After a minute with no input the screen sleeps;
the next press wakes the same page.

## Battery

A mcuzone Pi Zero UPS at I²C `0x40` shows the cell in `janus status`.
While the cell is discharging, the router powers off if the voltage stays
at or below 3.50 V for 60 seconds, or at or below 3.30 V for 10 seconds.
At boot, a discharging cell already below 3.55 V powers off before the
network starts. Charging, a current within 5 mA of zero, a missing
sensor, and `power.shutdown.enable = false` leave the router running.
The Waveshare address `0x43` stays unarmed and shows no readings.

## Tier 3 boards

The Raspberry Pi 2 v1.1 (BCM2836) and the StarFive VisionFive 2 are Tier
3 profiles. A Raspberry Pi 2 v1.2 is a BCM2837 and uses the Raspberry Pi
3 profile. These two images are cross-compiled. There is no binary
cache, so the first build takes a long time. `janus.build.strategy` is
`cross` for them. The fleet flake passes `buildSystem` to `mkRouter`.
A pure evaluation has no current system, so the fallback is
`x86_64-linux`. `janus-build` on another machine evaluates with that
machine's system, and stops when the image is still set to build
somewhere else. Set `emulated` only when the build machine can run that
architecture.

The Pi 2 image is 32-bit. Its boot partition is the FAT filesystem the
board firmware reads. The VisionFive 2 image puts SPL and U-Boot in the
GPT partitions the board looks up, then boots from `extlinux.conf`.
U-Boot picks the device tree for that board revision. Neither profile
chooses which jack is the WAN.

## Flows and metrics

Flow export is off until `janus.monitoring.flows.export.collector` is a
hostname or an IPv4 address. The protocol is `ipfix` (the default, port
4739) or `netflow9`. Janus sends flows for every WAN and every LAN
bridge. `janus.monitoring.interfaces` names a smaller set of WAN, LAN,
port, VLAN, or Wi-Fi names from the configuration. Janus resolves those
names to kernel interfaces such as `eth0`, `ppp-<wan>`, and `br-<lan>`.
The collector is usually on `mgmt` or a LAN. The export keeps a ring of
8192 flows in memory. It is not a packet capture.

`janus.monitoring.prometheus.enable = true` listens on port 9100 for
IPv4 and IPv6. The default zone list is `mgmt`. Traffic to that port is
accepted on those zones and dropped on every other interface, including
a LAN whose input policy is accept. `prometheus.zones` changes the
zones. The endpoint is node exporter plus
engine metrics: whether the engine is up, the selected node, the last
delay of that node, the last successful subscription refresh, the last
Geo refresh, and whether that refresh failed.

`janus.monitoring.scope = "flows"` does not by itself name a collector.
Set `flows.export.collector` as well.

## What the board does not do

The board does not run `nixos-rebuild` and does not evaluate Nix. Structural
changes are a new image or a deploy from the build machine. Command lists
are [docs/14-cli.md](../../docs/14-cli.md) on the router and
[docs/16-build-host-cli.md](../../docs/16-build-host-cli.md) on the build
machine. Hardware and the phased plan are in [docs/](../../docs/README.md).

## Languages

1. English, this file.
2. [Russian](../ru/README.md).
3. [Persian](../fa/README.md).
