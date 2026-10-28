# docs/16.
usage() {
  echo "janus-build <command> [<args>]" >&2
  echo "Run 'janus-build --help' for the command list." >&2
  exit 2
}

help() {
  cat <<'EOF'
janus-build <command> [<args>]
janus-build --help
janus-build --usage

--help and --usage print this text on stdout and exit 0.
Exit 0 is success. Exit 2 is a usage or refused request. Exit 1 is a runtime failure.

  init <dir> [--host <name>]
  host add <name>
  secret keygen <host>
  secret set <path>
  secret rewrap <path> --from <host>
  check [<host>]
  build [<host>]
  update [--train <train>]
  fleet apply [<host>] [--only-overrides]
  fleet pull [<host>] [--with-secrets]
  status [<host>]
  backup <host>
  deploy <host>
  deploy --preserve-state <host>
  deploy --confirm <host>
  deploy --age-key <host>
EOF
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

# Plaintext and plan files. Armed before the first mktemp. ${name:-}
# keeps an unset name from tripping nounset. A function that exits
# does not run its own RETURN trap, so this is the shell EXIT trap.
sops_work=""
plan_structural=""
plan_file=""
pull_values=""
pull_radios=""
pull_leases=""
pull_reached=""
pull_refs=""
cleanup_temps() {
  [ -n "${sops_work:-}" ] && rm -rf "$sops_work"
  [ -n "${plan_structural:-}" ] && rm -f "$plan_structural"
  [ -n "${plan_file:-}" ] && rm -f "$plan_file"
  [ -n "${pull_values:-}" ] && rm -f "$pull_values" "${pull_values}.files"
  [ -n "${pull_radios:-}" ] && rm -f "$pull_radios"
  [ -n "${pull_leases:-}" ] && rm -f "$pull_leases"
  [ -n "${pull_reached:-}" ] && rm -f "$pull_reached"
  [ -n "${pull_refs:-}" ] && rm -f "$pull_refs"
  # A failed test in `&&` returns 1. Under set -e that becomes the
  # shell's exit status and hides a successful command.
  true
}
trap cleanup_temps EXIT

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
  # The plaintext stays in this directory and never enters argv.
  # cleanup_temps is armed before any mktemp in this file.
  sops_work=$(mktemp -d)
  cat > "${sops_work}/plain"
  case "$out" in
    secrets/pppoe/*|secrets/nodes/*)
      if [ ! -s "${sops_work}/plain" ]; then
        echo "Refusing an empty secret for ${out}." >&2
        exit 1
      fi
      cp "${sops_work}/plain" "${sops_work}/in"
      intype=yaml
      ;;
    *)
      # Drop trailing newlines. jq reads the file; the secret is not an argument.
      jq -Rs 'sub("\n+$"; "") | {value: .}' < "${sops_work}/plain" > "${sops_work}/in"
      if ! jq -e '.value | length > 0' "${sops_work}/in" >/dev/null; then
        echo "Refusing an empty secret for ${out}." >&2
        exit 1
      fi
      intype=json
      ;;
  esac
  if ! sops encrypt --age "$keys" --input-type "$intype" --output-type yaml "${sops_work}/in" > "${out}.new"; then
    rm -f "${out}.new"
    exit 1
  fi
  mv "${out}.new" "$out"
  rm -rf "$sops_work"
  sops_work=""
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
# Tier 3 image for x86_64. On any other machine, eval runs impurely so
# currentSystem is that machine. Nix 2.34 rejects `nix --impure build`,
# so a build stays pure and uses the x86_64 fallback.
nix_fleet() {
  mine=$(host_nix_system) || return 1
  if [ "$mine" = x86_64-linux ] || [ "${1:-}" != eval ]; then
    nix "$@"
  else
    nix eval --impure "${@:2}"
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

# A value that already contains @ is an SSH destination, so an IPv6 form
# there is root@[address]. A bare IPv6 literal is wrapped in brackets.
# ssh://root@[address] is the form nix copy accepts.
ssh_dest() {
  case "$1" in
    *@*) printf '%s\n' "$1" ;;
    \[*\]) printf 'root@%s\n' "$1" ;;
    *:*) printf 'root@[%s]\n' "$1" ;;
    *) printf 'root@%s\n' "$1" ;;
  esac
}

ssh_to() {
  addr=$1
  shift
  dest=$(ssh_dest "$addr")
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$dest" "$@"
}

# The probe uses ssh -n so a piped key stays unread until the router
# answers. The prompt follows that answer. The key is not an argument
# and the temp file is removed on return.
install_age_key_over_ssh() {
  dest=$(ssh_dest "$1")
  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$dest" true; then
    return 1
  fi
  if [ -t 0 ]; then
    echo "Paste the age private key, then press Enter and Ctrl-D." >&2
  fi
  work=$(mktemp)
  trap 'rm -f "$work"' RETURN
  cat > "$work"
  if ! grep -q '^AGE-SECRET-KEY-1' "$work"; then
    echo "Refusing an age key that has no AGE-SECRET-KEY-1 line." >&2
    return 1
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$dest" janus secrets install-age-key < "$work"
}

slot_fits() {
  addr=$1
  uuid=$2
  img=$3
  what=$4
  part=$(ssh_to "$addr" "blockdev --getsize64 /dev/disk/by-partuuid/${uuid}")
  part=$(printf '%s' "$part" | tr -d '[:space:]')
  bytes=$(wc -c < "$img")
  bytes=$(printf '%s' "$bytes" | tr -d '[:space:]')
  if [ "$bytes" -gt "$part" ]; then
    echo "janus-build: the new ${what} slot image does not fit the ${what} partition. Flash a larger image." >&2
    exit 1
  fi
}

deploy_slots() {
  host=$1
  addr=$2
  meta=$(nix_fleet eval --raw ".#nixosConfigurations.${host}.config.environment.etc.\"janus/slots.json\".text")
  # --no-link: ./result is the image-link directory from janus-build build.
  imgs=$(nix_fleet build --no-link --print-out-paths ".#nixosConfigurations.${host}.config.system.build.janusSlotImages")
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
  slot_fits "$addr" "$root_uuid" "$root_img" "root"
  slot_fits "$addr" "$nix_uuid" "$nix_img" "Nix"
  ssh_to "$addr" "mount -o remount,rw /boot || true"
  ssh_to "$addr" "dd of=/dev/disk/by-partuuid/${root_uuid} bs=1M conv=fsync status=none" < "$root_img"
  ssh_to "$addr" "dd of=/dev/disk/by-partuuid/${nix_uuid} bs=1M conv=fsync status=none" < "$nix_img"
  # / is read-only and the slot root has no /mnt. /run is tmpfs.
  if ! ssh_to "$addr" "mkdir -p /run/janus-slot-nix && mount -o ro /dev/disk/by-partuuid/${nix_uuid} /run/janus-slot-nix && JANUS_SLOT_STORE=/run/janus-slot-nix bash -s -- install-slot ${closure} ${next}" < "$JANUS_BOOT_INSTALL"; then
    ssh_to "$addr" "umount /run/janus-slot-nix || true; mount -o remount,ro /boot || true"
    exit 1
  fi
  # Reboot after sshd can finish this session. A reboot in the session hangs the client.
  ssh_to "$addr" "umount /run/janus-slot-nix || true; install -d -m 0755 /var/lib/janus && : > /var/lib/janus/deploy-pending && rm -f /var/lib/janus/deploy-confirmed /var/lib/janus/deploy-booted && mount -o remount,ro /boot || true; nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 & exit 0"
}

require_clean() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "The git tree is not clean." >&2
    exit 2
  fi
}

subscription_secrets() {
  raw=$(nix_fleet eval --json ".#nixosConfigurations.${1}.config.janus.proxy.subscriptions") || return 1
  printf '%s\n' "$raw" | jq -r 'to_entries[] | select(.value.urlSecret != null) | "\(.key)\t\(.value.urlSecret)"'
}

wifi_secrets() {
  raw=$(nix_fleet eval --json ".#nixosConfigurations.${1}.config.janus.network.wifi") || return 1
  printf '%s\n' "$raw" | jq -r 'to_entries[] | select(.value.passphraseSecret != null) | "\(.key)\t\(.value.passphraseSecret)"'
}

# sops secret name, tab, repo-relative file. The fleet ties the name to
# the file with sops.secrets.<name>.sopsFile. The name is not the path.
# Pure evaluation copies the flake into a store path ending in -source.
# Impure evaluation keeps the repo path.
secret_files() {
  raw=$(nix_fleet eval --json --apply \
    'c: builtins.mapAttrs (n: v: if v ? sopsFile && v.sopsFile != null then toString v.sopsFile else "") (c.sops.secrets or {})' \
    ".#nixosConfigurations.${1}.config") || return 1
  lines=$(printf '%s\n' "$raw" | jq -r 'to_entries[] | select(.value != "") | "\(.key)\t\(.value)"') || return 1
  printf '%s\n' "$lines" | while IFS=$'\t' read -r name file; do
    [ -n "$name" ] || continue
    case "$file" in
      "$PWD"/*) printf '%s\t%s\n' "$name" "${file#"$PWD"/}" ;;
      *-source/*) printf '%s\t%s\n' "$name" "${file#*-source/}" ;;
      *)
        echo "janus-build: sopsFile ${file} for ${name} is not a path in this repo; it was skipped." >&2
        ;;
    esac
  done
}

sops_path() {
  printf '%s\n' "$1" | awk -F '\t' -v n="$2" '$1 == n { print $2; exit }'
}

# One tab pair. Sets pair_a and pair_b. A tab, a newline, or a carriage
# return in a field makes a row this cannot represent.
split_pair() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  pair_a=""
  pair_b=""
  pair_extra=""
  IFS=$'\t' read -r pair_a pair_b pair_extra <<< "$1"
  [ -n "$pair_a" ] && [ -n "$pair_b" ] && [ -z "$pair_extra" ]
}

# One plan row: kind, host, file, name. Sets those names. Shared with
# the tests. A field may contain spaces. A tab, a newline, a carriage
# return, a missing name, or a name equal to the file is rejected.
parse_plan_row() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  kind=""
  host=""
  file=""
  name=""
  extra=""
  IFS=$'\t' read -r kind host file name extra <<< "$1"
  [ -n "$kind" ] && [ -n "$host" ] && [ -n "$file" ] && [ -n "$name" ] && [ -z "$extra" ] || return 1
  [ "$name" != "$file" ]
}

# Single-quote one word for a remote command assembled as a string.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

plan_add() {
  saved_kind=${kind:-}
  saved_host=${host:-}
  saved_file=${file:-}
  saved_name=${name:-}
  if ! parse_plan_row "$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")"; then
    echo "janus-build: refusing a plan field that contains a tab, a newline, or a carriage return." >&2
    exit 2
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$plan"
  kind=$saved_kind
  host=$saved_host
  file=$saved_file
  name=$saved_name
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
  plan_structural=$structural
  plan_file=$plan
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
    secrets=$(subscription_secrets "$host") || {
      echo "janus-build: nix eval failed for ${host} (janus.proxy.subscriptions); the configuration does not evaluate" >&2
      exit 2
    }
    radios=$(wifi_secrets "$host") || {
      echo "janus-build: nix eval failed for ${host} (janus.network.wifi); the configuration does not evaluate" >&2
      exit 2
    }
    sopsmap=$(secret_files "$host") || {
      echo "janus-build: nix eval failed for ${host} (sops.secrets); the configuration does not evaluate" >&2
      exit 2
    }
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
        if ! split_pair "$pair"; then
          echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
          exit 2
        fi
        file=$(sops_path "$sopsmap" "$pair_b")
        if [ -n "$file" ] && [ -f "$file" ]; then
          plan_add subscription "$host" "$file" "$pair_a"
        else
          echo "${host}: ${pair_b} resolves to no file in this repo, so it was not applied." >&2
        fi
      done <<< "$secrets"
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        if ! split_pair "$pair"; then
          echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
          exit 2
        fi
        file=$(sops_path "$sopsmap" "$pair_b")
        if [ -n "$file" ] && [ -f "$file" ]; then
          plan_add wifi "$host" "$file" "$pair_a"
        else
          echo "${host}: ${pair_b} resolves to no file in this repo, so it was not applied." >&2
        fi
      done <<< "$radios"
      if [ -f "hosts/${host}/overrides.nix" ]; then
        plan_add leases "$host" "hosts/${host}/overrides.nix" -
      fi
    else
      files=$(git diff --name-only "$rev" HEAD)
    fi
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      case "$file" in
        "hosts/${host}/overrides.nix")
          plan_add leases "$host" "$file" -
          ;;
        secrets/*)
          # One cipher can feed several subscriptions. A deleted cipher
          # still matches the map and has nothing to send, so it stays
          # structural instead of becoming a plan row that cannot apply.
          matched=0
          while IFS= read -r pair; do
            [ -n "$pair" ] || continue
            if ! split_pair "$pair"; then
              echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
              exit 2
            fi
            resolved=$(sops_path "$sopsmap" "$pair_b")
            if [ "$file" = "$resolved" ] && [ -f "$file" ]; then
              plan_add subscription "$host" "$file" "$pair_a"
              matched=1
            fi
          done <<< "$secrets"
          while IFS= read -r pair; do
            [ -n "$pair" ] || continue
            if ! split_pair "$pair"; then
              echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
              exit 2
            fi
            resolved=$(sops_path "$sopsmap" "$pair_b")
            if [ "$file" = "$resolved" ] && [ -f "$file" ]; then
              plan_add wifi "$host" "$file" "$pair_a"
              matched=1
            fi
          done <<< "$radios"
          if [ "$matched" = 0 ]; then
            printf '%s %s\n' "$host" "$file" >> "$structural"
          fi
          ;;
        *)
          printf '%s %s\n' "$host" "$file" >> "$structural"
          ;;
      esac
    # Quoted, so a path that contains $(...) or a backtick stays a path.
    done <<< "$files"
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
        if ! parse_plan_row "$row"; then
          echo "janus-build fleet apply: bad plan row" >&2
          exit 2
        fi
        addr=$(host_address "$host")
        case "$kind" in
          subscription)
            # The inbox file is a sops document. The router decrypts it
            # with its own age key (ADR-0022). age cannot read sops.
            box="/var/lib/janus/secrets/inbox/$(printf '%s' "$name" | tr '/' '_').sops"
            ssh_to "$addr" "umask 077; mkdir -p /var/lib/janus/secrets/inbox; cat > $(shq "$box")" < "$file"
            ssh_to "$addr" "set -o pipefail; SOPS_AGE_KEY_FILE=/var/lib/janus/secrets/age.key sops decrypt --extract '[\"value\"]' $(shq "$box") | janus override set proxy.subscriptions.$(shq "$name").url; rc=\$?; rm -f $(shq "$box"); exit \$rc"
            ;;
          wifi)
            box="/var/lib/janus/secrets/inbox/$(printf '%s' "$name" | tr '/' '_').sops"
            ssh_to "$addr" "umask 077; mkdir -p /var/lib/janus/secrets/inbox; cat > $(shq "$box")" < "$file"
            ssh_to "$addr" "set -o pipefail; SOPS_AGE_KEY_FILE=/var/lib/janus/secrets/age.key sops decrypt --extract '[\"value\"]' $(shq "$box") | janus override set network.wifi.$(shq "$name").passphrase; rc=\$?; rm -f $(shq "$box"); exit \$rc"
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
  plan_structural=""
  plan_file=""
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
  # Plaintext from the routers. /dev/shm is RAM when the host has it.
  # The EXIT trap is already armed. The names start empty so a failure
  # before mktemp does not delete an unrelated path.
  pull_tmp=${TMPDIR:-/tmp}
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    pull_tmp=/dev/shm
  fi
  pull_values=$(mktemp "${pull_tmp}/janus-pull-values.XXXXXX")
  pull_radios=$(mktemp "${pull_tmp}/janus-pull-radios.XXXXXX")
  pull_leases=$(mktemp "${pull_tmp}/janus-pull-leases.XXXXXX")
  pull_reached=$(mktemp "${pull_tmp}/janus-pull-reached.XXXXXX")
  pull_refs=$(mktemp "${pull_tmp}/janus-pull-refs.XXXXXX")
  values=$pull_values
  radios=$pull_radios
  leases=$pull_leases
  reached=$pull_reached
  refs=$pull_refs
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
    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      key=$(printf '%s\n' "$obj" | jq -r '.key')
      value=$(printf '%s\n' "$obj" | jq -r '.value')
      case "${key}${value}" in
        *$'\t'*|*$'\n'*|*$'\r'*)
          echo "janus-build: refusing to pull a value that contains a tab, a newline, or a carriage return." >&2
          exit 2
          ;;
      esac
      printf '%s\t%s\t%s\n' "$host" "$key" "$value" >> "$values"
    done < <(printf '%s\n' "$raw" | jq -c '
      to_entries[]
      | select(.key | startswith("proxy.subscriptions."))
      | {key: .key, value: (.value | tostring)}
    ')
    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      key=$(printf '%s\n' "$obj" | jq -r '.key')
      value=$(printf '%s\n' "$obj" | jq -r '.value')
      case "${key}${value}" in
        *$'\t'*|*$'\n'*|*$'\r'*)
          echo "janus-build: refusing to pull a value that contains a tab, a newline, or a carriage return." >&2
          exit 2
          ;;
      esac
      printf '%s\t%s\t%s\n' "$host" "$key" "$value" >> "$radios"
    done < <(printf '%s\n' "$raw" | jq -c '
      to_entries[]
      | select(.key | startswith("network.wifi."))
      | {key: .key, value: (.value | tostring)}
    ')
    printf '%s\n' "$raw" | jq -c --arg host "$host" '
      {host: $host, leases: [to_entries[] | select(.key | startswith("network.lans."))]}
    ' >> "$leases"
  done < <(list_hosts "$host_arg")
  if [ "$with_secrets" = 1 ]; then
    echo "The SSH session carried plaintext credentials. No plaintext file was kept." >&2
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r host key value extra <<< "$row"
    if [ -n "${extra:-}" ]; then
      echo "janus-build: refusing to pull a value that contains a tab, a newline, or a carriage return." >&2
      exit 2
    fi
    name=${key#proxy.subscriptions.}
    name=${name%.url}
    secret=$(subscription_secrets "$host" | awk -F '\t' -v n="$name" '$1 == n {print $2; exit}')
    if [ -z "$secret" ]; then
      echo "${host}: ${key} has no urlSecret in this repo." >&2
      exit 2
    fi
    file=$(sops_path "$(secret_files "$host")" "$secret")
    if [ -z "$file" ]; then
      echo "${host}: ${secret} resolves to no file in this repo." >&2
      exit 2
    fi
    if [ "$with_secrets" != 1 ] || [ "$value" = "(redacted)" ]; then
      echo "${host}: ${key} changed. Not fetched."
      continue
    fi
    printf '%s\t%s\t%s\n' "$file" "$host" "$value" >> "${values}.files"
  done < "$values"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r host key value extra <<< "$row"
    if [ -n "${extra:-}" ]; then
      echo "janus-build: refusing to pull a value that contains a tab, a newline, or a carriage return." >&2
      exit 2
    fi
    ap=${key#network.wifi.}
    ap=${ap%.passphrase}
    secret=$(wifi_secrets "$host" | awk -F '\t' -v n="$ap" '$1 == n {print $2; exit}')
    if [ -z "$secret" ]; then
      echo "${host}: ${key} has no passphraseSecret in this repo." >&2
      exit 2
    fi
    file=$(sops_path "$(secret_files "$host")" "$secret")
    if [ -z "$file" ]; then
      echo "${host}: ${secret} resolves to no file in this repo." >&2
      exit 2
    fi
    if [ "$with_secrets" != 1 ] || [ "$value" = "(redacted)" ]; then
      echo "${host}: ${key} changed. Not fetched."
      continue
    fi
    printf '%s\t%s\t%s\n' "$file" "$host" "$value" >> "${values}.files"
  done < "$radios"
  while IFS= read -r host; do
    sopsmap=$(secret_files "$host") || {
      echo "janus-build: nix eval failed for ${host} (sops.secrets); the configuration does not evaluate" >&2
      exit 2
    }
    pairs=$(subscription_secrets "$host") || {
      echo "janus-build: nix eval failed for ${host} (janus.proxy.subscriptions); the configuration does not evaluate" >&2
      exit 2
    }
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      if ! split_pair "$pair"; then
        echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
        exit 2
      fi
      file=$(sops_path "$sopsmap" "$pair_b")
      [ -n "$file" ] || continue
      printf '%s\t%s\n' "$file" "$host" >> "$refs"
    done <<< "$pairs"
    pairs=$(wifi_secrets "$host") || {
      echo "janus-build: nix eval failed for ${host} (janus.network.wifi); the configuration does not evaluate" >&2
      exit 2
    }
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      if ! split_pair "$pair"; then
        echo "janus-build: refusing a field that contains a tab, a newline, or a carriage return." >&2
        exit 2
      fi
      file=$(sops_path "$sopsmap" "$pair_b")
      [ -n "$file" ] || continue
      printf '%s\t%s\n' "$file" "$host" >> "$refs"
    done <<< "$pairs"
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
      done < <(awk -F '\t' -v f="$file" '$1 == f {print $2}' "$refs")
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
      done < <(awk -F '\t' -v f="$file" '$1 == f {print $2}' "$refs")
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
  pull_values=""
  pull_radios=""
  pull_leases=""
  pull_reached=""
  pull_refs=""
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

# The store path stays where Nix put it. Nix is told not to link, and this
# command links that path at result/<host>, so a later host does not
# replace an earlier image. An old ./result symlink is removed so result/
# can be a directory.
prepare_image_link() {
  host=$1
  host_ok "$host"
  if [ -L result ]; then
    rm -f result
  fi
  if [ -e result ] && [ ! -d result ]; then
    echo "janus-build: ./result exists and is not a directory." >&2
    exit 1
  fi
  mkdir -p result
}

build_host_image() {
  host=$1
  require_build_host "$host"
  prepare_image_link "$host"
  # --no-link: Nix's own link is ./result. The fleet link is result/<host>.
  out=$(nix_fleet build --no-link --print-out-paths ".#nixosConfigurations.${host}.config.system.build.janusImage")
  ln -sfn "$out" "result/${host}"
  printf '%s\n' "$out"
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

case "${1:-}" in
  --help|--usage)
    help
    exit 0
    ;;
esac
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
      build_host_image "$host"
    else
      found=0
      for dir in hosts/*; do
        if [ -d "$dir" ]; then
          found=1
          name=$(basename "$dir")
          build_host_image "$name"
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
      install_age_key_over_ssh "$addr"
      exit $?
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
    # --no-link: ./result is the image-link directory from janus-build build.
    closure=$(nix_fleet build --no-link --print-out-paths ".#nixosConfigurations.${host}.config.system.build.toplevel")
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
    ssh_to "$addr" "install -d -m 0755 /var/lib/janus && : > /var/lib/janus/deploy-pending && rm -f /var/lib/janus/deploy-confirmed /var/lib/janus/deploy-booted && mount -o remount,ro /nix || true; mount -o remount,ro /boot || true; nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 & exit 0"
    ;;
  *)
    usage
    ;;
esac
