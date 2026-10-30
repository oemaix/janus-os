#!/bin/sh
# Container user. Private single-user Nix for a host that has no store.
# The named volume at /nix must already be writable by this user.
set -eu
if [ -x "${HOME:-}/.nix-profile/bin/nix" ]; then
  exit 0
fi
uid=$(id -u)
for dir in /nix/var/nix/profiles/per-user/*/profile/bin; do
  if [ -x "$dir/nix" ] && [ "$(stat -c '%u' "$dir/nix")" = "$uid" ]; then
    exit 0
  fi
done
installer=$(mktemp)
curl -fsSL -o "$installer" https://nixos.org/nix/install
sh "$installer" --no-daemon --yes
rm -f "$installer"
conf=${HOME}/.config/nix/nix.conf
mkdir -p "$(dirname "$conf")"
if [ ! -f "$conf" ] || ! grep -q '^[[:space:]]*experimental-features' "$conf"; then
  printf '%s\n' 'experimental-features = nix-command flakes' >> "$conf"
fi
if [ ! -f "$conf" ] || ! grep -q '^[[:space:]]*sandbox' "$conf"; then
  printf '%s\n' 'sandbox = false' >> "$conf"
fi
