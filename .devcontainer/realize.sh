#!/bin/sh
# Root, via sudo from postCreateCommand. Socket group, then the flake, as the container user.
set -eu
user=${1:?container user}
case "${2:-}" in
  ""|private) ;;
  *)
    echo "realize: unknown mode ${2}" >&2
    exit 1
    ;;
esac
home=$(getent passwd "$user" | cut -d: -f6)
export HOME=$home
export USER=$user
export LOGNAME=$user
export containerWorkspaceFolder=${containerWorkspaceFolder:-/workspace}
cd "$containerWorkspaceFolder"

/opt/devcontainer/nix-access.sh "$user"
/opt/devcontainer/gpu-link.sh

# Rootless Docker presents the host user as uid 0. updateRemoteUserUID applies
# the host numbers instead, so the editor cannot write the workspace. Match the
# owner as this mount shows it. -o lets the account share uid 0 with root.
# Do not chown the workspace: that would change the host owner.
if [ -d "$containerWorkspaceFolder" ]; then
  owner=$(stat -c '%u' "$containerWorkspaceFolder")
  wgroup=$(stat -c '%g' "$containerWorkspaceFolder")
  if ! getent group "$wgroup" >/dev/null; then
    groupadd -o -g "$wgroup" devcontainer-ws
  fi
  if [ "$(id -u "$user")" != "$owner" ] || [ "$(id -g "$user")" != "$wgroup" ]; then
    usermod -o -u "$owner" -g "$wgroup" "$user"
  fi
fi
prim=$(id -g "$user")
# Private Nix is a named volume, not the host store. The directory starts
# root-owned. The installer runs as the container user after the uid rewrite.
if [ "${2:-}" = private ]; then
  install -d /nix
  chown "$user:$prim" /nix
fi
# Single-user Nix has no daemon. Builds then run in this container, where the
# user-namespace sandbox is not available. sandbox = false stays in the
# container home. The daemon path does not write it.
# The client names its profile per-user/<passwd name>. That name is dev, so
# link it to the host user instead of creating a second profile on the store.
if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
  hostuser=dev
  if [ -s .devcontainer/host-user ]; then
    hostuser=$(head -n 1 .devcontainer/host-user)
  fi
  if ! printf '%s\n' "$hostuser" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*$'; then
    hostuser=dev
  fi
  if [ "${2:-}" != private ] && [ "$hostuser" != dev ]; then
    link_as_dev() {
      parent=$1
      if [ ! -d "$parent" ]; then
        install -d -o "$user" -g "$prim" "$parent"
      fi
      if [ -e "$parent/dev" ] || [ -L "$parent/dev" ]; then
        return 0
      fi
      if [ ! -d "$parent/$hostuser" ]; then
        install -d -o "$user" -g "$prim" "$parent/$hostuser"
      fi
      ln -s "$hostuser" "$parent/dev"
    }
    link_as_dev /nix/var/nix/profiles/per-user
    link_as_dev /nix/var/nix/gcroots/per-user
  fi
  install -d -o "$user" -g "$prim" "$HOME/.config/nix"
  if [ ! -f "$HOME/.config/nix/nix.conf" ] || ! grep -q '^sandbox' "$HOME/.config/nix/nix.conf"; then
    printf '%s\n' 'sandbox = false' >> "$HOME/.config/nix/nix.conf"
    chown "$user:$prim" "$HOME/.config/nix/nix.conf"
  fi
fi
run() {
  setpriv --reuid="$user" --regid="$prim" --init-groups --inh-caps=-all -- "$@"
}
if [ "${2:-}" = private ]; then
  run /opt/devcontainer/install-nix.sh
fi
run /opt/devcontainer/git-identity.sh
run nix develop --command true
