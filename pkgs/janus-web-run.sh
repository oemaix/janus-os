# Privileged command list for the maintenance page. docs/20 §6.
# The page user may sudo only this program. Arguments are checked again
# here; secret values arrive on stdin and are not placed on the command line.
set -eu

reject() {
  echo "rejected" >&2
  exit 2
}

plain_arg() {
  case "${1:-}" in
    ""|-*) reject ;;
  esac
  case "$1" in
    */*) reject ;;
  esac
}

allow_key() {
  case "$1" in
    ""|*[!a-zA-Z0-9._-]*) reject ;;
  esac
  case "$1" in
    proxy.subscriptions.*.url) ;;
    network.lans.*.dhcp.staticLeases.*) ;;
    network.wifi.*.passphrase) ;;
    *) reject ;;
  esac
}

mac_arg() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) reject ;;
  esac
}

bt_mac() {
  mac_arg "${1:-}"
  if [ -n "${2:-}" ]; then
    reject
  fi
}

pin_arg() {
  # Seventeen question marks is one past the 16-character code.
  case "$1" in
    ''|*[!0-9A-Za-z]*|?????????????????*) reject ;;
  esac
}

ip_arg() {
  rest=$1
  i=0
  while [ "$i" -lt 3 ]; do
    case "$rest" in
      *.*) ;;
      *) reject ;;
    esac
    octet=${rest%%.*}
    rest=${rest#*.}
    case "$octet" in
      ""|*[!0-9]*) reject ;;
    esac
    if [ "$((10#$octet))" -gt 255 ]; then
      reject
    fi
    i=$((i + 1))
  done
  octet=$rest
  case "$octet" in
    ""|*[!0-9]*|*.*) reject ;;
  esac
  if [ "$((10#$octet))" -gt 255 ]; then
    reject
  fi
}

janus_bin=${JANUS_BIN:-janus}

op=${1:-}
if [ -z "$op" ]; then
  echo "janus-web-run: missing operation" >&2
  exit 2
fi
shift

case "$op" in
  status)
    exec "$janus_bin" --json status
    ;;
  proxy-nodes)
    exec "$janus_bin" --json proxy nodes
    ;;
  proxy-refresh)
    if [ -n "${1:-}" ]; then
      plain_arg "$1"
      exec "$janus_bin" --json proxy refresh "$1"
    fi
    exec "$janus_bin" --json proxy refresh
    ;;
  proxy-geodata-refresh)
    exec "$janus_bin" --json proxy geodata refresh
    ;;
  proxy-probe)
    exec "$janus_bin" --json proxy probe
    ;;
  wan-restart)
    plain_arg "${1:-}"
    exec "$janus_bin" --json wan restart "$1"
    ;;
  wan-show)
    plain_arg "${1:-}"
    exec "$janus_bin" --json wan show "$1"
    ;;
  lan-leases)
    if [ -n "${1:-}" ]; then
      plain_arg "$1"
      exec "$janus_bin" --json lan leases "$1"
    fi
    exec "$janus_bin" --json lan leases
    ;;
  traffic)
    iface=""
    period=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --daily|--monthly)
          period=$1
          ;;
        *)
          plain_arg "$1"
          iface=$1
          ;;
      esac
      shift
    done
    if [ -n "$iface" ] && [ -n "$period" ]; then
      exec "$janus_bin" --json traffic "$iface" "$period"
    elif [ -n "$iface" ]; then
      exec "$janus_bin" --json traffic "$iface"
    elif [ -n "$period" ]; then
      exec "$janus_bin" --json traffic "$period"
    else
      exec "$janus_bin" --json traffic
    fi
    ;;
  traffic-top)
    exec "$janus_bin" --json traffic top
    ;;
  dns-query)
    plain_arg "${1:-}"
    exec "$janus_bin" --json dns query "$1"
    ;;
  dns-flush)
    exec "$janus_bin" --json dns flush
    ;;
  dns-stats)
    exec "$janus_bin" --json dns stats
    ;;
  dns-check)
    exec "$janus_bin" --json dns check
    ;;
  override-show)
    exec "$janus_bin" --json override show
    ;;
  override-set)
    key=${1:-}
    allow_key "$key"
    case "$key" in
      network.lans.*.dhcp.staticLeases.*)
        mac_arg "${2:-}"
        ip_arg "${3:-}"
        exec "$janus_bin" --json override set "$key" --mac "$2" --ip "$3"
        ;;
      *)
        # URL and passphrase are stdin, so they stay out of the process list.
        exec "$janus_bin" --json override set "$key"
        ;;
    esac
    ;;
  override-unset)
    key=${1:-}
    allow_key "$key"
    exec "$janus_bin" --json override unset "$key"
    ;;
  version)
    exec "$janus_bin" --json version --components
    ;;
  reboot)
    exec "$janus_bin" reboot
    ;;
  audit-status)
    exec "$janus_bin" --json audit status
    ;;
  bluetooth-list)
    exec "$janus_bin" --json bluetooth list
    ;;
  bluetooth-discover)
    if [ -n "${1:-}" ]; then
      reject
    fi
    exec "$janus_bin" --json bluetooth discover
    ;;
  bluetooth-pair)
    mac_arg "${1:-}"
    if [ -n "${2:-}" ]; then
      reject
    fi
    # The code arrives on stdin so it is not a process argument.
    code=
    if [ ! -t 0 ]; then
      IFS= read -r code || true
    fi
    if [ -n "$code" ]; then
      pin_arg "$code"
      printf '%s\n' "$code" | "$janus_bin" --json bluetooth pair "$1"
      exit $?
    fi
    exec "$janus_bin" --json bluetooth pair "$1"
    ;;
  bluetooth-connect)
    bt_mac "$@"
    exec "$janus_bin" --json bluetooth connect "$1"
    ;;
  bluetooth-disconnect)
    bt_mac "$@"
    exec "$janus_bin" --json bluetooth disconnect "$1"
    ;;
  bluetooth-remove)
    bt_mac "$@"
    exec "$janus_bin" --json bluetooth remove "$1"
    ;;
  *)
    echo "janus-web-run: unknown operation" >&2
    exit 2
    ;;
esac
