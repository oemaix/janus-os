#!/bin/sh
# /usr/local/bin/nix and nix-shell. Exec the host client. Do not start a daemon.
set -eu
# shellcheck disable=SC1091
. /etc/profile.d/nix-profile.sh
tool=$(basename "$0")
uid=$(id -u)
found=""
if [ -x /run/current-system/sw/bin/nix ]; then
  found=/run/current-system/sw/bin/nix
elif [ -S /nix/var/nix/daemon-socket/socket ] && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  found=/nix/var/nix/profiles/default/bin/nix
else
  for dir in /nix/var/nix/profiles/per-user/*/profile/bin; do
    if [ -x "$dir/nix" ] && [ "$(stat -c '%u' "$dir/nix")" = "$uid" ]; then
      found=$dir/nix
      break
    fi
  done
  if [ -z "$found" ] && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    found=/nix/var/nix/profiles/default/bin/nix
  fi
  if [ -z "$found" ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.nix-profile/bin/nix" ]; then
    found=$HOME/.nix-profile/bin/nix
  fi
fi
if [ -z "$found" ]; then
  echo "nix client not found" >&2
  exit 127
fi
target=$(dirname "$found")/$tool
if [ ! -x "$target" ]; then
  echo "host nix has no ${tool}" >&2
  exit 127
fi
if [ -S /nix/var/nix/daemon-socket/socket ]; then
  export NIX_REMOTE=daemon
fi
export PATH="$(dirname "$found"):$PATH"
exec "$target" "$@"
