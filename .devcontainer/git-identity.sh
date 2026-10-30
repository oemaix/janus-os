#!/bin/sh
# Container user. Include the read-only host gitconfig. Do not write it.
set -eu
host=/etc/gitconfig.host
dest=${HOME}/.gitconfig
workspace=${containerWorkspaceFolder:-/workspace}
{
  if [ -f "$host" ]; then
    printf '[include]\n\tpath = %s\n' "$host"
  fi
  printf '[safe]\n\tdirectory = %s\n' "$workspace"
} > "$dest"
chmod 600 "$dest"
