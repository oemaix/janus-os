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

# Write stdin to $1 as a sops document for the age public-key files in
# the remaining arguments. A PPPoE file stays YAML with username and
# password. A manual node file is that YAML document too. Every other
# credential is one value under the key `value`. The module sets the key
# for an option that names the secret. WireGuard is still a path, so the
# fleet sets `key = "value"`. A node file has no secret-name option, so
# the fleet sets `key = ""`. ADR-0014, ADR-0022.
sops_encrypt() {
  out=$1
  shift
  if [ "$#" -eq 0 ]; then
    echo "No age recipients for ${out}." >&2
    exit 1
  fi
  keys=""
  for pub in "$@"; do
    if [ ! -f "$pub" ]; then
      echo "Missing ${pub}." >&2
      exit 1
    fi
    key=$(tr -d '[:space:]' < "$pub")
    if [ -z "$key" ]; then
      echo "Empty age recipient ${pub}." >&2
      exit 1
    fi
    if [ -n "$keys" ]; then
      keys="${keys},${key}"
    else
      keys=$key
    fi
  done
  work=$(mktemp -d)
  # RETURN runs on every exit from this function, including `set -e`.
  # The plaintext stays in the temp dir and never enters argv.
  trap 'rm -rf "$work"' RETURN
  cat > "${work}/plain"
  case "$out" in
    secrets/pppoe/*|secrets/nodes/*)
      if [ ! -s "${work}/plain" ]; then
        echo "Refusing an empty secret for ${out}." >&2
        exit 1
      fi
      cp "${work}/plain" "${work}/in"
      intype=yaml
      ;;
    *)
      # Drop trailing newlines. jq reads the file; the secret is not an argument.
      jq -Rs 'sub("\n+$"; "") | {value: .}' < "${work}/plain" > "${work}/in"
      if ! jq -e '.value | length > 0' "${work}/in" >/dev/null; then
        echo "Refusing an empty secret for ${out}." >&2
        exit 1
      fi
      intype=json
      ;;
  esac
  if ! sops encrypt --age "$keys" --input-type "$intype" --output-type yaml "${work}/in" > "${out}.new"; then
    rm -f "${out}.new"
    exit 1
  fi
  mv "${out}.new" "$out"
}

host_nix_system() {
  case "$(uname -m)" in
    x86_64) printf '%s\n' x86_64-linux ;;
    aarch64) printf '%s\n' aarch64-linux ;;
    armv7l) printf '%s\n' armv7l-linux ;;
    riscv64) printf '%s\n' riscv64-linux ;;
    *)
      echo "janus-build: this machine ($(uname -m)) is not a supported build host." >&2
      return 1
      ;;
  esac
}

# Pure flake evaluation has no currentSystem. A fleet flake that writes
# `builtins.currentSystem or "x86_64-linux"` would then cross-compile a
# Tier 3 image for x86_64. On any other machine, --impure makes
# currentSystem this machine. x86_64 stays pure, which is that fallback.
nix_fleet() {
  mine=$(host_nix_system) || return 1
  if [ "$mine" = x86_64-linux ]; then
    nix "$@"
  else
    nix --impure "$@"
  fi
}

refuse_build_host() {
  mine=$1
  host=$2
  bp=$3
  echo "janus-build: this machine is ${mine}, and host '${host}' is set to build on ${bp}." >&2
  echo "Pass buildSystem = \"${mine}\" to lib.mkRouter. Pure evaluation has no currentSystem and otherwise uses x86_64-linux." >&2
  return 1
}

require_build_host() {
  host=$1
  mine=$(host_nix_system) || exit 1
  # buildPlatform defaults to hostPlatform. That is an emulated or native
  # build, including an aarch64 image built on x86_64. Refuse only a real
  # cross build aimed at some other machine.
  bp=$(nix_fleet eval --raw ".#nixosConfigurations.${host}.config.nixpkgs.buildPlatform.system" 2>/dev/null) || return 0
  hp=$(nix_fleet eval --raw ".#nixosConfigurations.${host}.config.nixpkgs.hostPlatform.system" 2>/dev/null) || return 0
  if [ "$bp" != "$hp" ] && [ "$bp" != "$mine" ]; then
    refuse_build_host "$mine" "$host" "$bp" || exit 1
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
  nix_fleet eval --raw ".#nixosConfigurations.${1}.config.janus.access.deploy.address"
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

slot_fits() {
  addr=$1
  uuid=$2
  img=$3
  part=$(ssh_to "$addr" "blockdev --getsize64 /dev/disk/by-partuuid/${uuid}")
  part=$(printf '%s' "$part" | tr -d '[:space:]')
  bytes=$(wc -c < "$img")
  bytes=$(printf '%s' "$bytes" | tr -d '[:space:]')
  if [ "$bytes" -gt "$part" ]; then
    echo "janus-build: the new slot image does not fit the partition. Flash a larger image." >&2
    exit 1
  fi
}

deploy_slots() {
  host=$1
  addr=$2
  meta=$(nix_fleet eval --raw ".#nixosConfigurations.${host}.config.environment.etc.\"janus/slots.json\".text")
  imgs=$(nix_fleet build --print-out-paths ".#nixosConfigurations.${host}.config.system.build.janusSlotImages")
  closure=$(tr -d '[:space:]' < "$imgs/toplevel")
  active=$(ssh_to "$addr" "if [ -f /boot/slot ]; then tr -d '[:space:]' < /boot/slot; else printf a; fi")
  if [ "$active" = b ]; then
    next=a
    root_uuid=$(printf '%s\n' "$meta" | jq -r .rootA)
    nix_uuid=$(printf '%s\n' "$meta" | jq -r .nixA)
    root_img="$imgs/root-a.img"
    nix_img="$imgs/nix-a.img"
  else
    next=b
    root_uuid=$(printf '%s\n' "$meta" | jq -r .rootB)
    nix_uuid=$(printf '%s\n' "$meta" | jq -r .nixB)
    root_img="$imgs/root-b.img"
    nix_img="$imgs/nix-b.img"
  fi
  if ! ssh_to "$addr" "test -b /dev/disk/by-partuuid/${root_uuid}"; then
    echo "janus-build: this disk has no inactive slot. Flash an image built with janus.storage.slots.enable." >&2
    exit 1
  fi
  slot_fits "$addr" "$root_uuid" "$root_img"
  slot_fits "$addr" "$nix_uuid" "$nix_img"
  ssh_to "$addr" "mount -o remount,rw /boot || true"
  ssh_to "$addr" "dd of=/dev/disk/by-partuuid/${root_uuid} bs=1M conv=fsync status=none" < "$root_img"
  ssh_to "$addr" "dd of=/dev/disk/by-partuuid/${nix_uuid} bs=1M conv=fsync status=none" < "$nix_img"
  if ! ssh_to "$addr" "mkdir -p /mnt/janus-slot-nix && mount -o ro /dev/disk/by-partuuid/${nix_uuid} /mnt/janus-slot-nix && JANUS_SLOT_STORE=/mnt/janus-slot-nix bash -s -- install-slot ${closure} ${next}" < "$JANUS_BOOT_INSTALL"; then
    ssh_to "$addr" "umount /mnt/janus-slot-nix" || true
    exit 1
  fi
  ssh_to "$addr" "umount /mnt/janus-slot-nix || true; install -d -m 0755 /var/lib/janus && : > /var/lib/janus/deploy-pending && rm -f /var/lib/janus/deploy-confirmed /var/lib/janus/deploy-booted && mount -o remount,ro /boot || true; systemctl reboot"
}

require_clean() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "The git tree is not clean." >&2
    exit 2
  fi
}

subscription_secrets() {
  nix_fleet eval --json ".#nixosConfigurations.${1}.config.janus.proxy.subscriptions" \
    | jq -r 'to_entries[] | select(.value.urlSecret != null) | "\(.key) \(.value.urlSecret)"'
}

wifi_secrets() {
  nix_fleet eval --json ".#nixosConfigurations.${1}.config.janus.network.wifi" \
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
      pubs=()
      while IFS= read -r owner; do
        [ -n "$owner" ] || continue
        pub="secrets/keys/${owner}.pub"
        if [ ! -f "$pub" ]; then
          echo "Missing ${pub}." >&2
          exit 1
        fi
        pubs+=("$pub")
      done < <(awk -v f="$file" '$1 == f {print $2}' "$refs")
      if [ "${#pubs[@]}" -eq 0 ]; then
        echo "No referencing host key for ${file}." >&2
        exit 1
      fi
      awk -F '\t' -v f="$file" '$1 == f {print $3; exit}' "${values}.files" \
        | sops_encrypt "$file" "${pubs[@]}"
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

# ADR-0024. A train is main or MAJOR.MINOR. A tag, a patch, and a topic
# branch are not trains.
train_ok() {
  name=$1
  case "$name" in
    main) return 0 ;;
  esac
  major=${name%%.*}
  minor=${name#*.}
  if [ "$major" = "$name" ] || [ -z "$major" ] || [ -z "$minor" ] || [ "$minor" != "${minor%%.*}" ]; then
    return 1
  fi
  case "$major$minor" in
    *[!0-9]*) return 1 ;;
  esac
  case "$major" in
    0 | [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$minor" in
    0 | [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$major" in
    0?*) return 1 ;;
  esac
  case "$minor" in
    0?*) return 1 ;;
  esac
  return 0
}

set_janus_url() {
  url=$1
  if [ ! -f flake.nix ]; then
    echo "flake.nix is missing." >&2
    exit 1
  fi
  if ! grep -q 'inputs\.janus\.url' flake.nix; then
    echo "flake.nix has no inputs.janus.url." >&2
    exit 1
  fi
  sed -i -E "s|(inputs\\.janus\\.url[[:space:]]*=[[:space:]]*\")[^\"]*(\";)|\\1${url}\\2|" flake.nix
}

# Lock the commit this janus-build came from. original names the branch
# and has no rev, so a later `nix flake update janus` can move.
write_janus_lock() {
  ref=${JANUS_URL#github:oemaix/janus-os/}
  jq --arg ref "$ref" \
    --arg rev "$JANUS_REV" \
    --arg nar "$JANUS_NAR" \
    --argjson modified "$JANUS_MODIFIED" \
    '
      def prefix_follows($rootInputs):
        if (type == "object") and has("inputs") then
          .inputs |= with_entries(
            .value as $v
            | if ($v | type) == "array" and (($rootInputs | index($v[0])) != null)
              then .value = (["janus"] + $v)
              else .
              end
          )
        else .
        end;
      . as $up
      | ($up.nodes.root.inputs | keys_unsorted) as $rootInputs
      | ($up.nodes | del(.root) | with_entries(.value |= prefix_follows($rootInputs)))
      | . + {
          janus: {
            inputs: $up.nodes.root.inputs,
            locked: {
              lastModified: $modified,
              narHash: $nar,
              owner: "oemaix",
              repo: "janus-os",
              rev: $rev,
              type: "github"
            },
            original: {
              owner: "oemaix",
              ref: $ref,
              repo: "janus-os",
              type: "github"
            }
          },
          root: {
            inputs: {
              janus: "janus",
              nixpkgs: ["janus", "nixpkgs"]
            }
          }
        }
      | {nodes: ., root: "root", version: 7}
    ' "$JANUS_UPSTREAM_LOCK" > flake.lock
}

if [ "${JANUS_BUILD_LIB:-}" = 1 ]; then
  # `return` leaves a sourced test. It fails when this file is executed, and then we stop.
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

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
    hosts=""
    while [ "${1:-}" = "--host" ]; do
      shift
      hosts="$hosts ${1:-}"
      shift || usage
    done
    (
      cd "$dir"
      set_janus_url "$JANUS_URL"
      if [ -n "$JANUS_REV" ]; then
        write_janus_lock
      fi
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
          secrets/tailscale/*|secrets/web/*)
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
        pubs=()
        if [ -n "$host" ]; then
          if [ ! -f "secrets/keys/${host}.pub" ]; then
            echo "Missing secrets/keys/${host}.pub." >&2
            exit 1
          fi
          pubs+=("secrets/keys/${host}.pub")
        else
          for pub in secrets/keys/*.pub; do
            if [ -f "$pub" ]; then
              pubs+=("$pub")
            fi
          done
          if [ "${#pubs[@]}" -eq 0 ]; then
            echo "No host public keys to encrypt $path." >&2
            exit 1
          fi
        fi
        mkdir -p "$(dirname "$path")"
        sops_encrypt "$path" "${pubs[@]}"
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
      require_build_host "$host"
      nix_fleet eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel.drvPath"
      echo
    else
      found=0
      for dir in hosts/*; do
        if [ -d "$dir" ]; then
          found=1
          name=$(basename "$dir")
          require_build_host "$name"
          nix_fleet eval --raw ".#nixosConfigurations.${name}.config.system.build.toplevel.drvPath"
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
      require_build_host "$host"
      nix_fleet build --print-out-paths ".#nixosConfigurations.${host}.config.system.build.janusImage"
    else
      found=0
      for dir in hosts/*; do
        if [ -d "$dir" ]; then
          found=1
          name=$(basename "$dir")
          require_build_host "$name"
          nix_fleet build --print-out-paths ".#nixosConfigurations.${name}.config.system.build.janusImage"
        fi
      done
      if [ "$found" = 0 ]; then
        echo "No hosts."
      fi
    fi
    ;;
  update)
    require_repo
    if [ $# -eq 0 ]; then
      nix flake update janus
    elif [ $# -eq 2 ] && [ "$1" = "--train" ]; then
      if ! train_ok "$2"; then
        echo "Train '$2' must be main or MAJOR.MINOR." >&2
        exit 2
      fi
      set_janus_url "github:oemaix/janus-os/$2"
      nix flake update janus
    else
      usage
    fi
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
    require_build_host "$host"
    if [ "$(nix_fleet eval --json ".#nixosConfigurations.${host}.config.janus.storage.slots.enable")" = true ]; then
      deploy_slots "$host" "$addr"
      exit 0
    fi
    closure=$(nix_fleet build --print-out-paths ".#nixosConfigurations.${host}.config.system.build.toplevel")
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
