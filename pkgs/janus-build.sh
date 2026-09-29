# docs/16. Phase 1: init, host add, secret, check, build, update.
usage() {
  echo "janus-build <init|host|secret|check|build|update> [<args>]" >&2
  echo "See docs/16-build-host-cli.md." >&2
  exit 2
}

later() {
  echo "janus-build $* is not in this phase. See docs/16-build-host-cli.md." >&2
  exit 2
}

host_ok() {
  rest=${1#?}
  first=${1%"$rest"}
  case "$first" in
    [A-Za-z]) ;;
    *)
      echo "Host name '$1' must start with a letter and then use letters, digits, or hyphens." >&2
      exit 2
      ;;
  esac
  case "$rest" in
    *[!A-Za-z0-9-]*)
      echo "Host name '$1' must start with a letter and then use letters, digits, or hyphens." >&2
      exit 2
      ;;
  esac
}

require_repo() {
  if [ ! -f flake.nix ]; then
    echo "Run this in a fleet repo (janus-build init <dir>)." >&2
    exit 2
  fi
}

write_host() {
  name=$1
  host_ok "$name"
  if [ -e "hosts/$name" ]; then
    echo "hosts/$name already exists." >&2
    exit 2
  fi
  mkdir -p "hosts/$name"
  cat > "hosts/$name/configuration.nix" << EOF
{ ... }: {
  # Board, ports, WAN, LAN, and an SSH key are still unset.
  # See docs/examples/configuration.example.nix.
  janus.system.hostName = "$name";
}
EOF
  cat > "hosts/$name/overrides.nix" << EOF
{ ... }: {
}
EOF
}

cmd=${1:-}
if [ -z "$cmd" ]; then
  usage
fi
shift

case "$cmd" in
  init)
    dir=${1:-}
    shift || true
    if [ -z "$dir" ]; then
      usage
    fi
    if [ -e "$dir/flake.nix" ]; then
      echo "$dir already contains flake.nix." >&2
      exit 2
    fi
    mkdir -p "$dir"
    cp -a -- "$TEMPLATE/." "$dir/"
    chmod -R u+w "$dir"
    sed -i "s|github:oemaix/janus-os|$JANUS_URL|" "$dir/flake.nix"
    hosts=""
    while [ "${1:-}" = "--host" ]; do
      shift
      hosts="$hosts ${1:-}"
      shift || usage
    done
    (
      cd "$dir"
      for name in $hosts; do
        write_host "$name"
      done
      if [ ! -d .git ]; then
        git init -q
        git add .
        if git config user.email >/dev/null 2>&1; then
          git commit -q -m "Initial fleet repository."
        else
          git -c user.email=janus@localhost -c user.name=janus commit -q -m "Initial fleet repository."
        fi
      fi
    )
    ;;
  host)
    require_repo
    if [ "${1:-}" != "add" ]; then
      usage
    fi
    write_host "${2:-}"
    echo "Commit hosts/$2, then: janus-build secret keygen $2" >&2
    ;;
  secret)
    require_repo
    sub=${1:-}
    case "$sub" in
      keygen)
        host=${2:-}
        host_ok "$host"
        pub="secrets/keys/${host}.pub"
        if [ -e "$pub" ]; then
          echo "$pub already exists." >&2
          exit 2
        fi
        mkdir -p secrets/keys
        tmp=$(mktemp)
        rm -f "$tmp"
        age-keygen -o "$tmp" >/dev/null
        grep -m1 '^# public key:' "$tmp" | sed 's/^# public key: //' > "$pub"
        cat "$tmp"
        rm -f "$tmp"
        ;;
      set)
        path=${2:-}
        if [ -z "$path" ]; then
          usage
        fi
        case "$path" in
          secrets/wifi/*/*|secrets/pppoe/*/*|secrets/wireguard/*/*)
            host=$(echo "$path" | cut -d/ -f3)
            ;;
          secrets/tailscale/*)
            host=$(basename "$path" .yaml)
            ;;
          secrets/subscription/*|secrets/nodes/*)
            host=""
            ;;
          *)
            echo "Path '$path' is not a secret file from docs/16 §2." >&2
            exit 2
            ;;
        esac
        recipients=()
        if [ -n "$host" ]; then
          recipients=(-R "secrets/keys/${host}.pub")
          if [ ! -f "secrets/keys/${host}.pub" ]; then
            echo "Missing secrets/keys/${host}.pub." >&2
            exit 1
          fi
        else
          for pub in secrets/keys/*.pub; do
            if [ -f "$pub" ]; then
              recipients+=(-R "$pub")
            fi
          done
          if [ "${#recipients[@]}" -eq 0 ]; then
            echo "No host public keys to encrypt $path." >&2
            exit 1
          fi
        fi
        mkdir -p "$(dirname "$path")"
        age -e "${recipients[@]}" -o "$path"
        ;;
      rewrap)
        later "secret rewrap"
        ;;
      *) usage ;;
    esac
    ;;
  check)
    require_repo
    host=${1:-}
    if [ -n "$host" ]; then
      nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel.drvPath"
      echo
    else
      found=0
      for dir in hosts/*; do
        if [ -d "$dir" ]; then
          found=1
          name=$(basename "$dir")
          nix eval --raw ".#nixosConfigurations.${name}.config.system.build.toplevel.drvPath"
          echo
        fi
      done
      if [ "$found" = 0 ]; then
        echo "No hosts."
      fi
    fi
    ;;
  build)
    require_repo
    host=${1:-}
    if [ -n "$host" ]; then
      nix build --print-out-paths ".#nixosConfigurations.${host}.config.system.build.janusImage"
    else
      found=0
      for dir in hosts/*; do
        if [ -d "$dir" ]; then
          found=1
          name=$(basename "$dir")
          nix build --print-out-paths ".#nixosConfigurations.${name}.config.system.build.janusImage"
        fi
      done
      if [ "$found" = 0 ]; then
        echo "No hosts."
      fi
    fi
    ;;
  update)
    require_repo
    nix flake update janus
    ;;
  deploy|fleet|status|backup)
    later "$cmd"
    ;;
  *)
    usage
    ;;
esac
