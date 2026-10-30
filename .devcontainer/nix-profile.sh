# Login shells, and sourced by /usr/local/bin/nix.
# Do not prepend /run/current-system/sw/bin: that is the NixOS userland.
if [ -S /nix/var/nix/daemon-socket/socket ]; then
  export NIX_REMOTE=daemon
fi
if [ -f /etc/nix/nix.conf ] && grep -q '^[[:space:]]*experimental-features' /etc/nix/nix.conf; then
  :
else
  case "${NIX_CONFIG:-}" in
    *experimental-features*) ;;
    "") export NIX_CONFIG='experimental-features = nix-command flakes' ;;
    *)
      NIX_CONFIG="${NIX_CONFIG}
experimental-features = nix-command flakes"
      export NIX_CONFIG
      ;;
  esac
fi
