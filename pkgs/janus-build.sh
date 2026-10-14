# docs/16.
usage() {
  echo "janus-build <init|host|secret|check|build|update|fleet|status|backup|deploy> [<args>]" >&2
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

wifi_secrets() {
  nix eval --json ".#nixosConfigurations.${1}.config.janus.network.wifi" \
    | jq -r 'to_entries[] | select(.value.passphraseSecret != null) | "\(.key) \(.value.passphraseSecret)"'
}

apply_leases() {
  host=$1
  addr=$(host_address "$host")
  file="hosts/${host}/overrides.nix"
  if [ ! -f "$file" ]; then
    return 0
  fi
  nix eval --json --impure --expr "import ./hosts/${host}/overrides.nix {}" \
    | jq -r '
      (.janus.network.lans // {})
      | to_entries[]
      | .key as $lan
      | (.value.dhcp.staticLeases // {})
      | to_entries[]
      | "\($lan) \(.key) \(.value.mac) \(.value.ip)"
    ' | while IFS= read -r lease; do
      [ -n "$lease" ] || continue
      lan=${lease%% *}
      rest=${lease#* }
      name=${rest%% *}
      rest=${rest#* }
      mac=${rest%% *}
      ip=${rest#* }
      ssh_to "$addr" janus override set "network.lans.${lan}.dhcp.staticLeases.${name}" --mac "$mac" --ip "$ip"
    done
}

ssh_dest() {
  case "$1" in
    *@*) printf '%s\n' "$1" ;;
    *) printf 'root@%s\n' "$1" ;;
  esac
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
  plan=$(mktemp)
  unknown_diff=0
  : > "$structural"
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
    radios=$(wifi_secrets "$host" || true)
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
      echo "${host}: the structural diff was not computed." >&2
      unknown_diff=1
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        secret=${pair#* }
        file="secrets/${secret}"
        if [ -f "$file" ]; then
          printf 'subscription %s %s\n' "$host" "$file" >> "$plan"
        else
          echo "${host}: ${file} is not in this repo, so it was not applied." >&2
        fi
      done <<< "$secrets"
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        secret=${pair#* }
        file="secrets/${secret}"
        if [ -f "$file" ]; then
          printf 'wifi %s %s\n' "$host" "$file" >> "$plan"
        else
          echo "${host}: ${file} is not in this repo, so it was not applied." >&2
        fi
      done <<< "$radios"
      if [ -f "hosts/${host}/overrides.nix" ]; then
        printf 'leases %s -\n' "$host" >> "$plan"
      fi
    else
      files=$(git diff --name-only "$rev" HEAD)
    fi
    printf '%s\n' "$files" | while IFS= read -r file; do
      [ -n "$file" ] || continue
      kind=structural
      case "$file" in
        "hosts/${host}/overrides.nix")
          kind=leases
          ;;
        secrets/wifi/"${host}"/*)
          kind=wifi
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
        leases) printf 'leases %s -\n' "$host" >> "$plan" ;;
        wifi) printf 'wifi %s %s\n' "$host" "$file" >> "$plan" ;;
        subscription) printf 'subscription %s %s\n' "$host" "$file" >> "$plan" ;;
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
        kind=${row%% *}
        rest=${row#* }
        host=${rest%% *}
        file=${rest#* }
        addr=$(host_address "$host")
        case "$kind" in
          subscription)
            name=$(subscription_secrets "$host" | awk -v path="${file#secrets/}" '$2 == path {print $1}')
            if [ -z "$name" ]; then
              echo "${file} is not a subscription secret for ${host}." >&2
              exit 2
            fi
            ssh_to "$addr" "umask 077; mkdir -p /var/lib/janus/secrets/inbox; cat > /var/lib/janus/secrets/inbox/${name}.age" < "$file"
            ssh_to "$addr" "age -d -i /var/lib/janus/secrets/age.key /var/lib/janus/secrets/inbox/${name}.age | janus override set proxy.subscriptions.${name}.url"
            ;;
          wifi)
            ap=$(basename "$file" .yaml)
            ssh_to "$addr" "umask 077; mkdir -p /var/lib/janus/secrets/inbox; cat > /var/lib/janus/secrets/inbox/${ap}.age" < "$file"
            ssh_to "$addr" "age -d -i /var/lib/janus/secrets/age.key /var/lib/janus/secrets/inbox/${ap}.age | janus override set network.wifi.${ap}.passphrase"
            ;;
          leases)
            apply_leases "$host"
            ;;
          *)
            echo "janus-build fleet apply: unknown plan row ${row}" >&2
            exit 2
            ;;
        esac
        ;;
    esac
  done < "$plan"
  code=0
  if grep -q '^unreachable:' "$plan"; then
    code=1
  fi
  if [ "$unknown_diff" = 1 ]; then
    code=2
  fi
  rm -f "$structural" "$plan"
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
  radios=$(mktemp)
  leases=$(mktemp)
  reached=$(mktemp)
  refs=$(mktemp)
  : > "$values"
  : > "$radios"
  : > "$leases"
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
    printf '%s\n' "$raw" | jq -r --arg host "$host" '
      to_entries[]
      | select(.key | startswith("network.wifi."))
      | "\($host) \(.key) \(.value)"
    ' >> "$radios"
    printf '%s\n' "$raw" | jq -c --arg host "$host" '
      {host: $host, leases: [to_entries[] | select(.key | startswith("network.lans."))]}
    ' >> "$leases"
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
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    host=${row%% *}
    rest=${row#* }
    key=${rest%% *}
    value=${rest#* }
    ap=${key#network.wifi.}
    ap=${ap%.passphrase}
    secret=$(wifi_secrets "$host" | awk -v n="$ap" '$1 == n {print $2}')
    if [ -z "$secret" ]; then
      echo "${host}: ${key} has no passphraseSecret in this repo." >&2
      exit 2
    fi
    file="secrets/${secret}"
    if [ "$with_secrets" != 1 ] || [ "$value" = "(redacted)" ]; then
      echo "${host}: ${key} changed. Not fetched."
      continue
    fi
    printf '%s\t%s\t%s\n' "$file" "$host" "$value" >> "${values}.files"
  done < "$radios"
  while IFS= read -r host; do
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      secret=${pair#* }
      printf '%s %s\n' "secrets/${secret}" "$host" >> "$refs"
    done <<< "$(subscription_secrets "$host" || true)"
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      secret=${pair#* }
      printf '%s %s\n' "secrets/${secret}" "$host" >> "$refs"
    done <<< "$(wifi_secrets "$host" || true)"
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
  while IFS= read -r host; do
    if ! grep -qx "$host" "$reached"; then
      continue
    fi
    target="hosts/${host}/overrides.nix"
    blob=$(jq -c --arg h "$host" 'select(.host == $h) | .leases' "$leases" | head -n 1)
    if [ -z "$blob" ]; then
      blob='[]'
    fi
    generated=0
    if [ -f "$target" ] && grep -q 'generated by janus-build fleet pull' "$target"; then
      generated=1
    fi
    if [ "$blob" = "[]" ] && [ "$generated" != 1 ]; then
      continue
    fi
    if [ -f "$target" ] && [ "$generated" != 1 ] && grep -q 'janus\.' "$target"; then
      echo "${host}: ${target} was not generated by fleet pull and already sets janus options. Left unchanged."
      continue
    fi
    {
      printf '%s\n' "# generated by janus-build fleet pull"
      printf '%s\n' "{ ... }: {"
      printf '%s\n' "$blob" | jq -r '.[] | select(.value | type == "object") | "  janus.\(.key) = { mac = \(.value.mac | @json); ip = \(.value.ip | @json); };"'
      printf '%s\n' "}"
    } > "${target}.new"
    mv "${target}.new" "$target"
  done < <(list_hosts "$host_arg")
  git diff --stat || true
  rm -f "$values" "${values}.files" "$radios" "$leases" "$reached" "$refs"
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
    require_repo
    preserve=0
    confirm=0
    age_key=0
    host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --preserve-state) preserve=1 ;;
        --confirm) confirm=1 ;;
        --age-key) age_key=1 ;;
        *)
          if [ -n "$host" ]; then
            usage
          fi
          host=$1
          ;;
      esac
      shift
    done
    if [ -z "$host" ] || [ $((preserve + confirm + age_key)) -gt 1 ]; then
      usage
    fi
    host_ok "$host"
    addr=$(host_address "$host")
    if [ "$age_key" = 1 ]; then
      ssh_to "$addr" janus secrets install-age-key
      exit 0
    fi
    if [ "$confirm" = 1 ]; then
      ssh_to "$addr" "install -d -m 0755 /var/lib/janus && : > /var/lib/janus/deploy-confirmed"
      exit 0
    fi
    if [ "$preserve" = 1 ]; then
      umask 077
      mkdir -p backup
      utc=$(date -u +%Y%m%dT%H%M%SZ)
      path="./backup/${host}-state-${utc}.tar"
      ssh_to "$addr" "list=\$(mktemp); for p in var/lib/janus/etc var/lib/janus/secrets var/lib/janus/subscriptions var/lib/janus/geodata var/lib/janus/overrides.json var/lib/janus/engine/selection.json; do if [ -e \"/\$p\" ]; then printf '%s\n' \"\$p\" >> \"\$list\"; fi; done; if [ ! -s \"\$list\" ]; then rm -f \"\$list\"; exit 1; fi; tar -C / -cf - -T \"\$list\"; rm -f \"\$list\"" > "$path"
      printf '%s\n' "$path"
      exit 0
    fi
    closure=$(nix build --print-out-paths ".#nixosConfigurations.${host}.config.system.build.toplevel")
    dest=$(ssh_dest "$addr")
    ssh_to "$addr" "mount -o remount,rw /nix; mount -o remount,rw /boot || true"
    if ! NIX_SSHOPTS="-o BatchMode=yes -o ConnectTimeout=8" nix copy --to "ssh://${dest}" "$closure"; then
      nix-store -qR "$closure" | nix-store --export | ssh_to "$addr" "NIX_CONFIG=\$(printf '%s\n' 'max-jobs = 0' 'substituters = ') nix-store --import"
    fi
    ssh_to "$addr" "NIX_CONFIG=\$(printf '%s\n' 'max-jobs = 0' 'substituters = ') nix-env -p /nix/var/nix/profiles/system --set ${closure}"
    if ! ssh_to "$addr" "bash -s -- install ${closure}" < "$JANUS_BOOT_INSTALL"; then
      ssh_to "$addr" "bash -s -- restore" < "$JANUS_BOOT_INSTALL" || true
      ssh_to "$addr" "nix-env -p /nix/var/nix/profiles/system --rollback" || true
      exit 1
    fi
    ssh_to "$addr" "install -d -m 0755 /var/lib/janus && : > /var/lib/janus/deploy-pending && rm -f /var/lib/janus/deploy-confirmed /var/lib/janus/deploy-booted && mount -o remount,ro /nix || true; mount -o remount,ro /boot || true; systemctl reboot"
    ;;
  *)
    usage
    ;;
esac
