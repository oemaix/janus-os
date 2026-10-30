#!/bin/sh
# Host-side initializeCommand. Refuses the wrong profile. Writes .devcontainer/host-user.
set -eu
mode=${1:?profile mode}
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=${DEVCONTAINER_CHECK_ROOT:-}

die() {
  echo "$*" >&2
  exit 1
}

host_path() {
  printf '%s%s' "$root" "$1"
}

has_nix() {
  if [ -d "$(host_path /nix/store)" ]; then
    return 0
  fi
  # A fixture must not see the machine's own nix on PATH.
  if [ -n "$root" ]; then
    return 1
  fi
  command -v nix >/dev/null 2>&1
}

require_nvidia_runtime() {
  if [ -n "${DEVCONTAINER_DOCKER_INFO+x}" ]; then
    runtimes=$DEVCONTAINER_DOCKER_INFO
  else
    command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
    runtimes=$(docker info --format '{{.DefaultRuntime}} {{range $name, $rt := .Runtimes}}{{$name}} {{end}}') \
      || die "docker info failed"
  fi
  case " $runtimes " in
    *" nvidia "*) return 0 ;;
  esac
  die "Docker has no NVIDIA runtime, so --gpus all cannot see the cards. On NixOS enable hardware.nvidia-container-toolkit. On another host install the NVIDIA container toolkit and restart the daemon."
}

case "$mode" in
  nixos)
    [ -x "$(host_path /run/current-system/sw/bin/nix)" ] \
      || die "This profile is for a NixOS host. Pick Nix host, or Other host when this machine has no Nix."
    ;;
  nix)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host profile."
    has_nix || die "This host has no Nix store. Pick Other host."
    ;;
  other)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host profile."
    if has_nix; then
      die "This host has Nix. Pick the NixOS host or Nix host profile."
    fi
    ;;
  nixos-nvidia)
    [ -x "$(host_path /run/current-system/sw/bin/nix)" ] \
      || die "This profile is for a NixOS host. Pick Nix host with GPU, or Other host with GPU when this machine has no Nix."
    [ -d "$(host_path /run/opengl-driver)" ] \
      || die "NixOS NVIDIA needs /run/opengl-driver (hardware.graphics)."
    require_nvidia_runtime
    ;;
  nix-nvidia)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host with GPU profile."
    has_nix || die "This host has no Nix store. Pick Other host with GPU."
    require_nvidia_runtime
    ;;
  other-nvidia)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host with GPU profile."
    if has_nix; then
      die "This host has Nix. Pick the NixOS or Nix host with GPU profile."
    fi
    require_nvidia_runtime
    ;;
  nixos-rocm)
    [ -x "$(host_path /run/current-system/sw/bin/nix)" ] \
      || die "This profile is for a NixOS host. Pick Nix host with GPU, or Other host with GPU when this machine has no Nix."
    [ -e "$(host_path /dev/kfd)" ] && [ -d "$(host_path /dev/dri)" ] \
      || die "ROCm needs the device node /dev/kfd and the directory /dev/dri."
    ;;
  nix-rocm)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host with GPU profile."
    has_nix || die "This host has no Nix store. Pick Other host with GPU."
    [ -e "$(host_path /dev/kfd)" ] && [ -d "$(host_path /dev/dri)" ] \
      || die "ROCm needs the device node /dev/kfd and the directory /dev/dri."
    ;;
  other-rocm)
    [ ! -e "$(host_path /run/current-system)" ] \
      || die "This host is NixOS. Pick the NixOS host with GPU profile."
    if has_nix; then
      die "This host has Nix. Pick the NixOS or Nix host with GPU profile."
    fi
    [ -e "$(host_path /dev/kfd)" ] && [ -d "$(host_path /dev/dri)" ] \
      || die "ROCm needs the device node /dev/kfd and the directory /dev/dri."
    ;;
  *)
    die "unknown profile mode: $mode"
    ;;
esac

printf '%s\n' "$(id -un)" > "${DEVCONTAINER_HOST_USER_FILE:-$script_dir/host-user}"
