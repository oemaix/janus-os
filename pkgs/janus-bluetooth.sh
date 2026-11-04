# janus bluetooth. docs/14. A2DP source and AVRCP. D-0059, D-0061.
# The image installs this when janus.audio.playback.output is bluetooth. Soloist is not required.
# Just Works pairing needs --agent NoInputNoOutput. A scan that ends before
# pair drops the speaker (T-0013). A pairing code starts janus-bt-agent for
# that address only, after the scan is up, and stops it before connect.
# pair by name uses devices seen in this scan, not the BlueZ cache (T-0015).
# wpctl looks for the
# system socket in PIPEWIRE_RUNTIME_DIR, which is /run/pipewire-0 (T-0014).
set -eu
set -o pipefail

json=0
if [ "${1:-}" = "--json" ]; then
  json=1
  shift
fi

export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run}"

state_dir=${JANUS_BT_STATE:-/var/lib/janus/bluetooth}
run_dir=${JANUS_BT_RUN:-/run/janus/bluetooth}

usage() {
  echo "janus bluetooth list" >&2
  echo "janus bluetooth discover" >&2
  echo "janus bluetooth pair <address-or-name> [code]" >&2
  echo "janus bluetooth connect <address-or-name>" >&2
  echo "janus bluetooth disconnect <address-or-name>" >&2
  echo "janus bluetooth remove <address-or-name>" >&2
  exit 2
}

is_mac() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
      return 0
      ;;
  esac
  return 1
}

pin_ok() {
  # Seventeen question marks is one past the 16-character code.
  case "$1" in
    ''|*[!0-9A-Za-z]*|?????????????????*)
      echo "janus bluetooth: code must be 1 to 16 letters or digits." >&2
      exit 2
      ;;
  esac
}

last_mac() {
  if [ -f "$state_dir/last" ]; then
    tr -d '[:space:]' < "$state_dir/last"
  fi
}

remember() {
  install -d -m 0755 "$state_dir"
  printf '%s\n' "$1" > "$state_dir/last"
  chmod 0644 "$state_dir/last"
  rm -f "$run_dir/hold"
  bluetoothctl trust "$1" >/dev/null 2>&1 || true
}

hold() {
  install -d -m 0755 "$run_dir"
  printf '%s\n' "$1" > "$run_dir/hold"
}

held() {
  [ -f "$run_dir/hold" ] || return 1
  [ "$(tr -d '[:space:]' < "$run_dir/hold")" = "$1" ]
}

stop_scan() {
  if [ -n "${scan_pid:-}" ]; then
    kill "$scan_pid" >/dev/null 2>&1 || true
    wait "$scan_pid" >/dev/null 2>&1 || true
    scan_pid=
  fi
  bluetoothctl scan off >/dev/null 2>&1 || true
}

stop_agent() {
  if [ -n "${agent_pid:-}" ]; then
    kill "$agent_pid" >/dev/null 2>&1 || true
    wait "$agent_pid" >/dev/null 2>&1 || true
    agent_pid=
  fi
}

on_signal() {
  stop_agent
  stop_scan
  exit 1
}
trap on_signal INT TERM

start_scan() {
  # Inquiry has to stay up while pair runs. A finished scan forgets
  # a speaker that is only discoverable for a short time (T-0013).
  install -d -m 0755 "$run_dir"
  : > "$run_dir/scan"
  bluetoothctl --agent NoInputNoOutput --timeout 40 scan on >"$run_dir/scan" 2>&1 &
  scan_pid=$!
}

start_code_agent() {
  mac=$1
  pin=$2
  if ! command -v janus-bt-agent >/dev/null 2>&1; then
    echo "janus bluetooth: janus-bt-agent is not in this image." >&2
    return 1
  fi
  # The code is stdin, not an argument. The agent becomes the default
  # after the scan's Just Works agent, and only for this address (T-0013).
  janus-bt-agent "$mac" >/dev/null 2>&1 <<EOF &
$pin
EOF
  agent_pid=$!
  sleep 0.3
  if ! kill -0 "$agent_pid" 2>/dev/null; then
    agent_pid=
    echo "janus bluetooth: pairing agent did not start." >&2
    return 1
  fi
}

connected() {
  bluetoothctl info "$1" 2>/dev/null | grep -q 'Connected: yes'
}

set_default_sink() {
  if ! command -v wpctl >/dev/null 2>&1; then
    return 0
  fi
  sink=$(wpctl status 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\)\. bluez_output.*/\1/p' | head -n 1 || true)
  if [ -n "${sink:-}" ]; then
    wpctl set-default "$sink" >/dev/null 2>&1 || true
  fi
}

ack() {
  if [ "$json" = 1 ]; then
    printf '%s\n' '{"ok":true}'
  else
    echo ok
  fi
}

# $raw is the bluetoothctl devices text. Sets match_mac, match_count, match_list.
collect_name() {
  name=$1
  match_mac=
  match_count=0
  match_list=
  while IFS= read -r line; do
    case "$line" in
      Device\ *) ;;
      *) continue ;;
    esac
    rest=${line#Device }
    mac=${rest%% *}
    devname=${rest#"$mac"}
    devname=${devname# }
    devname=${devname%$'\r'}
    if [ "$devname" = "$name" ]; then
      match_count=$((match_count + 1))
      match_mac=$mac
      match_list="${match_list}${mac}
"
    fi
  done <<EOF
$raw
EOF
}

name_miss() {
  if [ "$match_count" -gt 1 ]; then
    echo "janus bluetooth: \"$1\" matches more than one device. Pass the address." >&2
    printf '%s' "$match_list" >&2
    return 2
  fi
  echo "janus bluetooth: no device named \"$1\"." >&2
  return 2
}

resolve_known() {
  token=$1
  resolved=
  if is_mac "$token"; then
    resolved=$token
    return 0
  fi
  raw=$(bluetoothctl devices 2>/dev/null || true)
  collect_name "$token"
  if [ "$match_count" -eq 1 ]; then
    resolved=$match_mac
    return 0
  fi
  name_miss "$token" || true
  return 2
}

line_mac() {
  printf '%s\n' "$1" | grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -n 1 || true
}

mac_key() {
  printf '%s' "$1" | tr 'a-f' 'A-F'
}

# A scan line's tail is a name, or a property such as "RSSI: -70".
is_property() {
  case "$1" in
    RSSI:*|TxPower:*|Class:*|Icon:*|Alias:*|UUIDs:*|Appearance:*|Paired:*|Connected:*|Trusted:*|Blocked:*|LegacyPairing:*|ManufacturerData:*|ServiceData:*|ServicesResolved:*|Adapter:*|Address:*|Modalias:*|WakeAllowed:*|Bonded:*)
      return 0
      ;;
  esac
  return 1
}

# Rebuild $run_dir/seen from one scan log. One file per address seen
# in this inquiry. The file text is the name, when the log has one.
parse_scan() {
  log=$1
  rm -rf "$run_dir/seen"
  mkdir -p "$run_dir/seen"
  [ -f "$log" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *Device\ *) ;;
      *) continue ;;
    esac
    mac=$(line_mac "$line")
    if [ -z "${mac:-}" ]; then
      continue
    fi
    key=$(mac_key "$mac")
    rest=${line#*Device }
    rest=${rest#"$mac"}
    rest=${rest# }
    rest=${rest%$'\r'}
    if [ ! -f "$run_dir/seen/$key" ]; then
      : > "$run_dir/seen/$key"
    fi
    case "$rest" in
      *'Name: '*)
        seen_name=${rest#*Name: }
        seen_name=${seen_name%$'\r'}
        if ! is_property "$seen_name"; then
          printf '%s' "$seen_name" > "$run_dir/seen/$key"
        fi
        ;;
      *)
        if [ -n "$rest" ] && ! is_property "$rest"; then
          printf '%s' "$rest" > "$run_dir/seen/$key"
        fi
        ;;
    esac
  done < "$log"
}

# Print the display name: BlueZ Name when info has one, otherwise the
# name kept from this scan. Never an RSSI line.
display_name() {
  mac=$1
  key=$(mac_key "$mac")
  info=$(bluetoothctl info "$mac" 2>/dev/null || true)
  name=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Name: //p' | head -n 1 || true)
  if [ -z "$name" ] && [ -s "$run_dir/seen/$key" ]; then
    name=$(cat "$run_dir/seen/$key")
  fi
  printf '%s' "$name"
}

# Names from this scan only. A cached device that did not advertise
# during this inquiry is not a match (T-0015).
match_scan_name() {
  want=$1
  match_mac=
  match_count=0
  match_list=
  for file in "$run_dir/seen"/*; do
    [ -e "$file" ] || continue
    mac=$(basename "$file")
    devname=$(display_name "$mac")
    if [ -n "$devname" ] && [ "$devname" = "$want" ]; then
      match_count=$((match_count + 1))
      match_mac=$mac
      match_list="${match_list}${mac}
"
    fi
  done
}

find_name() {
  name=$1
  resolved=
  tries=0
  while :; do
    parse_scan "$run_dir/scan"
    match_scan_name "$name"
    if [ "$match_count" -gt 1 ]; then
      name_miss "$name" || true
      return 2
    fi
    if ! kill -0 "$scan_pid" 2>/dev/null; then
      break
    fi
    if [ "$tries" -ge 8 ]; then
      break
    fi
    tries=$((tries + 1))
    sleep 1
  done
  parse_scan "$run_dir/scan"
  match_scan_name "$name"
  if [ "$match_count" -eq 1 ]; then
    resolved=$match_mac
    return 0
  fi
  if [ "$match_count" -gt 1 ]; then
    name_miss "$name" || true
    return 2
  fi
  name_miss "$name" || true
  return 2
}

list_devices() {
  raw=$(bluetoothctl devices 2>/dev/null || true)
  last=$(last_mac || true)
  rows='[]'
  while IFS= read -r line; do
    case "$line" in
      Device\ *) ;;
      *) continue ;;
    esac
    rest=${line#Device }
    mac=${rest%% *}
    name=${rest#"$mac"}
    name=${name# }
    info=$(bluetoothctl info "$mac" 2>/dev/null || true)
    paired=false
    trusted=false
    is_connected=false
    is_last=false
    printf '%s\n' "$info" | grep -q 'Paired: yes' && paired=true
    printf '%s\n' "$info" | grep -q 'Trusted: yes' && trusted=true
    printf '%s\n' "$info" | grep -q 'Connected: yes' && is_connected=true
    if [ -n "$last" ] && [ "$mac" = "$last" ]; then
      is_last=true
    fi
    if [ -z "$name" ]; then
      name=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Name: //p' | head -n 1 || true)
    fi
    rows=$(printf '%s\n' "$rows" | jq -c \
      --arg address "$mac" \
      --arg name "$name" \
      --argjson paired "$paired" \
      --argjson trusted "$trusted" \
      --argjson connected "$is_connected" \
      --argjson last "$is_last" \
      '. + [{address:$address, name:$name, paired:$paired, trusted:$trusted, connected:$connected, last:$last}]')
  done <<EOF
$raw
EOF
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows" | jq -c '{devices:.}'
  else
    printf '%s\n' "$rows" | jq -r '.[] | [.address, .name, (if .paired then "paired" else empty end), (if .connected then "connected" else empty end), (if .trusted then "trusted" else empty end), (if .last then "last" else empty end)] | join(" ")'
  fi
}

discover_devices() {
  install -d -m 0755 "$run_dir"
  bluetoothctl --agent NoInputNoOutput --timeout 8 scan on >"$run_dir/discover" 2>&1 || true
  parse_scan "$run_dir/discover"
  rows='[]'
  for file in "$run_dir/seen"/*; do
    [ -e "$file" ] || continue
    mac=$(basename "$file")
    info=$(bluetoothctl info "$mac" 2>/dev/null || true)
    name=$(display_name "$mac")
    paired=false
    printf '%s\n' "$info" | grep -q 'Paired: yes' && paired=true
    rows=$(printf '%s\n' "$rows" | jq -c \
      --arg address "$mac" \
      --arg name "$name" \
      --argjson paired "$paired" \
      '. + [{address:$address, name:$name, paired:$paired}]')
  done
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows" | jq -c '{devices:.}'
  else
    printf '%s\n' "$rows" | jq -r '.[] | [.address, .name, (if .paired then "paired" else empty end)] | join(" ")'
  fi
}

cmd=${1:-}
case "$cmd" in
  list)
    shift
    if [ $# -ne 0 ]; then
      usage
    fi
    list_devices
    ;;
  discover)
    shift
    if [ $# -ne 0 ]; then
      usage
    fi
    discover_devices
    ;;
  pair)
    shift
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      usage
    fi
    token=$1
    pin=${2:-}
    if [ -z "$pin" ] && [ ! -t 0 ]; then
      IFS= read -r pin || true
    fi
    if [ -n "$pin" ]; then
      pin_ok "$pin"
    fi
    start_scan
    sleep 1
    if is_mac "$token"; then
      mac=$token
    else
      if ! find_name "$token"; then
        stop_scan
        exit 2
      fi
      mac=$resolved
    fi
    if [ -n "$pin" ]; then
      if ! start_code_agent "$mac" "$pin"; then
        stop_scan
        exit 1
      fi
      if ! bluetoothctl --timeout 45 pair "$mac"; then
        stop_agent
        stop_scan
        exit 1
      fi
      # Drop the code agent before connect so Just Works owns the default again.
      stop_agent
    else
      if ! bluetoothctl --agent NoInputNoOutput --timeout 45 pair "$mac"; then
        stop_scan
        exit 1
      fi
    fi
    remember "$mac"
    bluetoothctl --agent NoInputNoOutput --timeout 25 connect "$mac" >/dev/null 2>&1 || true
    stop_scan
    set_default_sink
    ack
    ;;
  connect)
    shift
    if [ $# -ne 1 ]; then
      usage
    fi
    if ! resolve_known "$1"; then
      exit 2
    fi
    mac=$resolved
    if ! bluetoothctl --agent NoInputNoOutput --timeout 25 connect "$mac"; then
      exit 1
    fi
    remember "$mac"
    set_default_sink
    ack
    ;;
  disconnect)
    shift
    if [ $# -ne 1 ]; then
      usage
    fi
    if ! resolve_known "$1"; then
      exit 2
    fi
    mac=$resolved
    if ! bluetoothctl disconnect "$mac"; then
      exit 1
    fi
    hold "$mac"
    ack
    ;;
  remove)
    shift
    if [ $# -ne 1 ]; then
      usage
    fi
    if ! resolve_known "$1"; then
      exit 2
    fi
    mac=$resolved
    if ! bluetoothctl remove "$mac"; then
      exit 1
    fi
    if [ "$(last_mac || true)" = "$mac" ]; then
      rm -f "$state_dir/last"
    fi
    ack
    ;;
  reconnect)
    # Started by systemd. Not a janus subcommand.
    while true; do
      mac=$(last_mac || true)
      if [ -n "$mac" ] && ! held "$mac" && ! connected "$mac"; then
        bluetoothctl --agent NoInputNoOutput --timeout 20 connect "$mac" >/dev/null 2>&1 || true
        set_default_sink
      fi
      sleep 15
    done
    ;;
  *)
    usage
    ;;
esac
