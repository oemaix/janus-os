# docs/16. deploy is still a later phase.
usage() {
  echo "janus-build <init|host|secret|check|build|update|fleet|status|backup> [<args>]" >&2
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

list_hosts() {
  one=${1:-}
  if [ -n "$one" ]; then
    printf '%s\n' "$one"
    return
  fi
  found=0
  for dir in hosts/*; do
    if [ -d "$dir" ]; then
      found=1
      basename "$dir"
    fi
  done
  if [ "$found" = 0 ]; then
    echo "No hosts." >&2
    exit 2
  fi
}

host_address() {
  nix eval --raw ".#nixosConfigurations.${1}.config.janus.access.deploy.address"
}

ssh_to() {
  addr=$1
  shift
  case "$addr" in
    *@*) dest=$addr ;;
    *) dest="root@${addr}" ;;
  esac
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$dest" "$@"
}

require_clean() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "The git tree is not clean." >&2
    exit 2
  fi
}

subscription_secrets() {
  nix eval --json ".#nixosConfigurations.${1}.config.janus.proxy.subscriptions" \
    | jq -r 'to_entries[] | select(.value.urlSecret != null) | "\(.key) \(.value.urlSecret)"'
}

fleet_apply() {
  only=0
  host_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --only-overrides) only=1 ;;
      *)
        if [ -n "$host_arg" ]; then
          usage
        fi
        host_arg=$1
        ;;
    esac
    shift
  done
  require_clean
  structural=$(mktemp)
  phase3=$(mktemp)
  plan=$(mktemp)
  unknown_diff=0
  : > "$structural"
  : > "$phase3"
  : > "$plan"
  while IFS= read -r host; do
    if ! addr=$(host_address "$host"); then
      echo "unreachable: ${host}" >> "$plan"
      continue
    fi
    if ! rev=$(ssh_to "$addr" janus version --json | jq -r '.configRevision // "unknown"'); then
      echo "unreachable: ${host}" >> "$plan"
      continue
    fi
    secrets=$(subscription_secrets "$host" || true)
    files=""
    if [ "$rev" = unknown ] || [ -z "$rev" ] || ! git cat-file -e "${rev}^{commit}" 2>/dev/null; then
      if [ "$only" != 1 ]; then
        if [ "$rev" = unknown ] || [ -z "$rev" ]; then
          echo "${host}: the running image has no configRevision. Pass --only-overrides." >&2
        else
          echo "${host}: configRevision ${rev} is not in this repo." >&2
        fi
        exit 2
      fi
      echo "${host}: the structural diff was not computed. Static leases and Wi-Fi passphrases were not applied." >&2
      unknown_diff=1
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        secret=${pair#* }
        file="secrets/${secret}"
        if [ -f "$file" ]; then
          printf '%s %s\n' "$host" "$file" >> "$plan"
        else
          echo "${host}: ${file} is not in this repo, so it was not applied." >&2
        fi
      done <<< "$secrets"
    else
      files=$(git diff --name-only "$rev" HEAD)
    fi
    printf '%s\n' "$files" | while IFS= read -r file; do
      [ -n "$file" ] || continue
      kind=structural
      case "$file" in
        "hosts/${host}/overrides.nix" | secrets/wifi/"${host}"/*)
          kind=phase3
          ;;
        secrets/*)
          while IFS= read -r pair; do
            [ -n "$pair" ] || continue
            secret=${pair#* }
            if [ "$file" = "secrets/${secret}" ]; then
              kind=subscription
            fi
          done <<< "$secrets"
          ;;
      esac
      case "$kind" in
        structural) printf '%s %s\n' "$host" "$file" >> "$structural" ;;
        phase3) printf '%s %s\n' "$host" "$file" >> "$phase3" ;;
        subscription) printf '%s %s\n' "$host" "$file" >> "$plan" ;;
      esac
    done
  done < <(list_hosts "$host_arg")
  if [ -s "$structural" ] && [ "$only" != 1 ]; then
    echo "These paths are outside the hot-override projection:" >&2
    awk '{print $2}' "$structural" | sort -u >&2
    echo "Nothing was applied. Pass --only-overrides to apply the projection only." >&2
    exit 2
  fi
  if [ -s "$structural" ]; then
    echo "These paths still need janus-build deploy:" >&2
    awk '{print $2}' "$structural" | sort -u >&2
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      unreachable:*)
        echo "$row" >&2
        ;;
      *)
        host=${row%% *}
        file=${row#* }
        addr=$(host_address "$host")
        name=$(subscription_secrets "$host" | awk -v path="${file#secrets/}" '$2 == path {print $1}')
        if [ -z "$name" ]; then
          echo "${file} is not a subscription secret for ${host}." >&2
          exit 2
        fi
        ssh_to "$addr" "umask 077; mkdir -p /var/lib/janus/secrets/inbox; cat > /var/lib/janus/secrets/inbox/${name}.age" < "$file"
        ssh_to "$addr" "age -d -i /var/lib/janus/secrets/age.key /var/lib/janus/secrets/inbox/${name}.age | janus override set proxy.subscriptions.${name}.url"
        ;;
    esac
  done < "$plan"
  code=0
  if grep -q '^unreachable:' "$plan"; then
    code=1
  fi
  if [ -s "$phase3" ]; then
    echo "Static leases and Wi-Fi passphrases are phase 3 and were not applied:" >&2
    cat "$phase3" >&2
    code=2
  fi
  if [ "$unknown_diff" = 1 ]; then
    code=2
  fi
  rm -f "$structural" "$phase3" "$plan"
  exit "$code"
}

fleet_pull() {
  with_secrets=0
  host_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-secrets) with_secrets=1 ;;
      *)
        if [ -n "$host_arg" ]; then
          usage
        fi
        host_arg=$1
        ;;
    esac
    shift
  done
  if ! grep -q 'overrides.nix' flake.nix; then
    echo "flake.nix does not import hosts/<name>/overrides.nix." >&2
    exit 2
  fi
  values=$(mktemp)
  reached=$(mktemp)
  refs=$(mktemp)
  : > "$values"
  : > "$reached"
  : > "$refs"
  while IFS= read -r host; do
    if ! addr=$(host_address "$host"); then
      echo "unreachable: ${host}" >&2
      continue
    fi
    if [ "$with_secrets" = 1 ]; then
      remote="janus --json override show --secrets"
    else
      remote="janus --json override show"
    fi
    if ! raw=$(ssh_to "$addr" "$remote"); then
      echo "unreachable: ${host}" >&2
      continue
    fi
    printf '%s\n' "$host" >> "$reached"
    printf '%s\n' "$raw" | jq -r --arg host "$host" '
      to_entries[]
      | select(.key | startswith("proxy.subscriptions."))
      | "\($host) \(.key) \(.value)"
    ' >> "$values"
  done < <(list_hosts "$host_arg")
  if [ "$with_secrets" = 1 ]; then
    echo "The SSH session carried plaintext credentials. No plaintext file was kept." >&2
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    host=${row%% *}
    rest=${row#* }
    key=${rest%% *}
    value=${rest#* }
    name=${key#proxy.subscriptions.}
    name=${name%.url}
    secret=$(subscription_secrets "$host" | awk -v n="$name" '$1 == n {print $2}')
    if [ -z "$secret" ]; then
      echo "${host}: ${key} has no urlSecret in this repo." >&2
      exit 2
    fi
    file="secrets/${secret}"
    if [ "$with_secrets" != 1 ] || [ "$value" = "(redacted)" ]; then
      echo "${host}: ${key} changed. Not fetched."
      continue
    fi
    printf '%s\t%s\t%s\n' "$file" "$host" "$value" >> "${values}.files"
  done < "$values"
  while IFS= read -r host; do
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      secret=${pair#* }
      printf '%s %s\n' "secrets/${secret}" "$host" >> "$refs"
    done <<< "$(subscription_secrets "$host" || true)"
  done < <(list_hosts)
  if [ -f "${values}.files" ]; then
    while IFS= read -r file; do
      distinct=$(awk -F '\t' -v f="$file" '$1 == f {print $3}' "${values}.files" | sort -u | wc -l)
      if [ "$distinct" -gt 1 ]; then
        echo "${file} disagrees between hosts. The file was left unchanged." >&2
        awk -F '\t' -v f="$file" '$1 == f {print $2}' "${values}.files" >&2
        continue
      fi
      if [ ! -f "$file" ]; then
        echo "Missing ${file}." >&2
        exit 2
      fi
      blocked=0
      while IFS= read -r owner; do
        [ -n "$owner" ] || continue
        if ! grep -qx "$owner" "$reached"; then
          echo "${file} is referenced by ${owner}, which was not reached. The file was left unchanged." >&2
          blocked=1
        fi
      done < <(awk -v f="$file" '$1 == f {print $2}' "$refs")
      if [ "$blocked" = 1 ]; then
        continue
      fi
      recipients=()
      while IFS= read -r owner; do
        [ -n "$owner" ] || continue
        pub="secrets/keys/${owner}.pub"
        if [ ! -f "$pub" ]; then
          echo "Missing ${pub}." >&2
          exit 1
        fi
        recipients+=(-R "$pub")
      done < <(awk -v f="$file" '$1 == f {print $2}' "$refs")
      if [ "${#recipients[@]}" -eq 0 ]; then
        echo "No referencing host key for ${file}." >&2
        exit 1
      fi
      awk -F '\t' -v f="$file" '$1 == f {print $3; exit}' "${values}.files" \
        | age -e "${recipients[@]}" -o "${file}.new"
      mv "${file}.new" "$file"
      echo "updated ${file}"
    done < <(cut -f1 "${values}.files" | sort -u)
  fi
  git diff --stat || true
  rm -f "$values" "${values}.files" "$reached" "$refs"
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
  fleet)
    require_repo
    sub=${1:-}
    shift || true
    case "$sub" in
      apply) fleet_apply "$@" ;;
      pull) fleet_pull "$@" ;;
      *) usage ;;
    esac
    ;;
  status)
    require_repo
    fail=0
    while IFS= read -r host; do
      if ! addr=$(host_address "$host"); then
        echo "unreachable: ${host}" >&2
        fail=1
        continue
      fi
      echo "== ${host} =="
      if ! ssh_to "$addr" janus status; then
        echo "unreachable: ${host}" >&2
        fail=1
      fi
    done < <(list_hosts "${1:-}")
    exit "$fail"
    ;;
  backup)
    require_repo
    host=${1:-}
    if [ -z "$host" ]; then
      usage
    fi
    host_ok "$host"
    addr=$(host_address "$host")
    umask 077
    mkdir -p backup
    utc=$(date -u +%Y%m%dT%H%M%SZ)
    path="./backup/${host}-${utc}.tar"
    ssh_to "$addr" janus backup > "$path"
    printf '%s\n' "$path"
    ;;
  deploy)
    later "$cmd"
    ;;
  *)
    usage
    ;;
esac
