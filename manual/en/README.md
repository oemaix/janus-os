# Janus OS

Janus OS does not ship a router system. You build your own, on NixOS:
an image on one computer, flashed to a small board. The board does not
build software and does not evaluate Nix.

The project is public and licensed under the Apache License, Version 2.0.

## What you can do today

The router image boots in a VM. Image profiles exist for the NanoPi R4S,
the Le Potato, the Raspberry Pi Zero 2 W, the Raspberry Pi 3 / 3+, and
the Yanyu STX-R19F (Limine on legacy BIOS). `janus` and `janus-build`
implement the phase 1 commands, plus proxy, DNS, fleet, status, backup,
deploy, and the connection audit. On the board, `janus deploy` exits 2
and names `janus-build`.

A development shell exists for people working on the source: from the
repository root, run `nix develop`.

## Build and flash

On the build machine:

1. `janus-build init` creates the private configuration repository.
2. `janus-build host add` names one board.
3. The host file sets the board, the WAN, and at least one LAN. Ports
   come from the board profile.
4. `janus-build build <host>` writes `janus-<host>.img`.
5. Flash that image. The state partition starts empty.
6. SSH in as root with the key from the host configuration. There is no
   password login.

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
