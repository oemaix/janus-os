#!/bin/sh
# Root. Nix CUDA/OpenGL dlopens /run/opengl-driver/lib. NixOS GPU profiles mount
# that path. Other-host GPU profiles have the toolkit's libcuda elsewhere.
# Do nothing when the directory is already there, or when this container has no GPU.
set -eu
if [ -e /run/opengl-driver/lib ]; then
  exit 0
fi
lib=$(find /usr /opt /usr/local -name 'libcuda.so.1' 2>/dev/null | head -n 1 || true)
if [ -z "$lib" ]; then
  exit 0
fi
install -d /run/opengl-driver
ln -s "$(dirname "$lib")" /run/opengl-driver/lib
