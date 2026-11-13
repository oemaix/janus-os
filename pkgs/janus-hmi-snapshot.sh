# SPDX-License-Identifier: Apache-2.0
# One status snapshot for the panel. docs/15 §2. Fields are tab-separated.
set -eu
conf=${1:-/etc/janus/hmi.conf}
host_name=janus
mode=-
proxy=0
power_sign=-
power_armed=0
power_warn=3.60
have_power=0
wan_names=()
wan_ifaces=()
lan_names=()
lan_subnets=()

while IFS=$'\t' read -r key a b c || [ -n "${key:-}" ]; do
  case "$key" in
    "" | \#*) ;;
    host) host_name=$a ;;
    mode) mode=$a ;;
    proxy) proxy=$a ;;
    wan)
      wan_names+=("$a")
      wan_ifaces+=("$b")
      ;;
    lan)
      lan_names+=("$a")
      lan_subnets+=("$b")
      ;;
    power)
      have_power=1
      power_sign=$a
      power_armed=$b
      power_warn=$c
      ;;
  esac
done < "$conf"

live=$(hostname 2>/dev/null || true)
if [ -n "$live" ]; then
  host_name=$live
fi
uptime_text=-
if [ -r /proc/uptime ]; then
  secs=$(awk '{print int($1)}' /proc/uptime)
  d=$((secs / 86400))
  h=$(((secs % 86400) / 3600))
  m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then
    uptime_text="${d}d${h}h"
  elif [ "$h" -gt 0 ]; then
    uptime_text="${h}h${m}m"
  elif [ "$m" -gt 0 ]; then
    uptime_text="${m}m"
  else
    uptime_text="${secs}s"
  fi
fi

addr_of() {
  ip "-$1" -o addr show dev "$2" scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1
}

printf 'host\t%s\n' "$host_name"
printf 'uptime\t%s\n' "$uptime_text"
printf 'mode\t%s\n' "$mode"

i=0
while [ "$i" -lt "${#wan_names[@]}" ]; do
  name=${wan_names[$i]}
  iface=${wan_ifaces[$i]}
  v4=$(addr_of 4 "$iface" || true)
  v6=$(addr_of 6 "$iface" || true)
  [ -n "$v4" ] || v4=-
  [ -n "$v6" ] || v6=-
  up=0
  if [ -r "/sys/class/net/${iface}/operstate" ]; then
    st=$(cat "/sys/class/net/${iface}/operstate")
    if [ "$st" = up ] || { [ "$st" = unknown ] && { [ "$v4" != - ] || [ "$v6" != - ]; }; }; then
      up=1
    fi
  fi
  printf 'wan\t%s\t%s\t%s\t%s\t-\n' "$name" "$up" "$v4" "$v6"
  i=$((i + 1))
done

leases=/var/lib/janus/leases/dnsmasq.leases
i=0
while [ "$i" -lt "${#lan_names[@]}" ]; do
  name=${lan_names[$i]}
  subnet=${lan_subnets[$i]}
  count=0
  if [ -r "$leases" ]; then
    count=$(awk -v cidr="$subnet" '
      function num(ip, p, n) {
        n = split(ip, p, ".")
        if (n != 4) return -1
        return p[1] * 16777216 + p[2] * 65536 + p[3] * 256 + p[4]
      }
      BEGIN {
        split(cidr, c, "/")
        base = num(c[1])
        bits = c[2] + 0
        if (bits <= 0) mask = 0
        else mask = (2 ^ bits - 1) * (2 ^ (32 - bits))
        net = and(base, mask)
      }
      {
        ip = num($3)
        if (ip >= 0 && and(ip, mask) == net) n++
      }
      END { print n + 0 }
    ' "$leases")
  fi
  printf 'lan\t%s\t%s\t%s\n' "$name" "$count" "$subnet"
  i=$((i + 1))
done

tunnel=0
refresh=0
if [ "$proxy" = 1 ]; then
  if ! systemctl is-active --quiet janus-engine.service 2>/dev/null; then
    tunnel=1
  fi
  for err in /var/lib/janus/subscriptions/*.error; do
    if [ -f "$err" ]; then
      refresh=1
    fi
  done
fi
printf 'tunnel-error\t%s\n' "$tunnel"
printf 'refresh-error\t%s\n' "$refresh"

picked=$(mktemp)
trap 'rm -f "$picked"' EXIT
: > "$picked"
if [ -n "${JANUS_PICKED:-}" ]; then
  cp "$JANUS_PICKED" "$picked"
elif [ "$proxy" = 1 ] && [ -x /etc/janus/bin/janus-proxy ]; then
  /etc/janus/bin/janus-proxy picked > "$picked" || : > "$picked"
fi

if [ "$proxy" = 1 ] && [ -f /var/lib/janus/engine/node-labels.json ]; then
  jq -r --rawfile picked "$picked" '
    ($picked | split("\n") | map(select(. != "") | split("\t")[0])) as $on
    | to_entries
    | sort_by(.key)
    | .[]
    | .key as $n
    | (if ($on | index($n) != null) then "1" else "0" end) as $mark
    | (.value | to_entries | sort_by(.key) | map("\(.key)=\(.value|tostring)") | join(" ")) as $text
    | "node\t\($n)\t\($mark)\t\($text)"
  ' /var/lib/janus/engine/node-labels.json
fi

if [ "$have_power" = 1 ]; then
  mv=""
  ma=""
  for hw in /sys/class/hwmon/hwmon*; do
    [ -r "$hw/name" ] || continue
    case $(cat "$hw/name") in
      ina219*)
        mv=$(cat "$hw/in1_input" 2>/dev/null || true)
        ma=$(cat "$hw/curr1_input" 2>/dev/null || true)
        ;;
    esac
  done
  voltage=-
  direction=idle
  warning=0
  if [ -n "$mv" ] && [ -n "$ma" ]; then
    voltage=$(awk -v mv="$mv" 'BEGIN { printf "%.2f", mv / 1000 }')
    if [ "$power_sign" = negative ]; then
      if [ "$ma" -lt -5 ]; then direction=discharge
      elif [ "$ma" -gt 5 ]; then direction=charge
      fi
    elif [ "$power_sign" = positive ]; then
      if [ "$ma" -gt 5 ]; then direction=discharge
      elif [ "$ma" -lt -5 ]; then direction=charge
      fi
    fi
    if [ "$direction" = discharge ] && awk -v v="$voltage" -v w="$power_warn" 'BEGIN { exit !(v + 0 <= w + 0) }'; then
      warning=1
    fi
  fi
  printf 'battery\t%s\t%s\t%s\t%s\n' "$voltage" "$direction" "$power_armed" "$warning"
fi
