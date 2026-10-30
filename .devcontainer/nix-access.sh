#!/bin/sh
# Root only. Supplementary groups for the host daemon socket and, when a GPU
# profile mounted them, the device nodes. Do not start nix-daemon. Do not chown /nix.
set -eu
user=${1:?container user}
seen=" "

add_gid() {
  gid=$1
  label=$2
  case "$seen" in
    *" $gid "*) return 0 ;;
  esac
  seen="$seen$gid "
  name=$(getent group "$gid" | cut -d: -f1 || true)
  if [ -z "$name" ]; then
    name=$label
    if getent group "$name" >/dev/null 2>&1; then
      name="${label}-${gid}"
    fi
    groupadd --gid "$gid" "$name"
  fi
  case ",$(id -nG "$user")," in
    *",$name,"*) ;;
    *) usermod -aG "$name" "$user" ;;
  esac
}

sock=/nix/var/nix/daemon-socket/socket
if [ -S "$sock" ]; then
  add_gid "$(stat -c '%g' "$sock")" nix-daemon
fi

# No-op on profiles that did not pass these devices in.
for node in /dev/dri/renderD* /dev/dri/card* /dev/kfd \
  /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-modeset /dev/nvidia[0-9] \
  /dev/nvidia-caps/*; do
  [ -e "$node" ] || continue
  add_gid "$(stat -c '%g' "$node")" "dev-$(basename "$node")"
done
