# Connection audit. docs/14 §5, FR-MON-007.
# One JSON object per line: 5-tuple, bytes, times, and a domain when the
# router already has one. Payloads are not recorded.
set -eu
audit_json=${JANUS_AUDIT_JSON:-/etc/janus/audit.json}
paused=/var/lib/janus/audit/paused
names=/run/janus/audit/names
names_at=0

log_path() {
  jq -r '.path // "/var/lib/janus/audit/connections.jsonl"' "$audit_json"
}

retention_seconds() {
  raw=$(jq -r '.retention // "7d"' "$audit_json")
  case "$raw" in
    *d)
      n=${raw%d}
      echo $((n * 86400))
      ;;
    *h)
      n=${raw%h}
      echo $((n * 3600))
      ;;
    *m)
      n=${raw%m}
      echo $((n * 60))
      ;;
    *s)
      n=${raw%s}
      echo "$n"
      ;;
    *)
      echo "janus-audit: retention ${raw} is not a duration" >&2
      exit 1
      ;;
  esac
}

parse_line() {
  line=$1
  case "$line" in
    *'[DESTROY]'*) ;;
    *) return 1 ;;
  esac
  proto=""
  src=""
  dst=""
  sport=""
  dport=""
  bytes=0
  end_unix=$(date +%s)
  delta=""
  # shellcheck disable=SC2086
  for word in $line; do
    case "$word" in
      src=*)
        if [ -z "$src" ]; then
          src=${word#src=}
        fi
        ;;
      dst=*)
        if [ -z "$dst" ]; then
          dst=${word#dst=}
        fi
        ;;
      sport=*)
        if [ -z "$sport" ]; then
          sport=${word#sport=}
        fi
        ;;
      dport=*)
        if [ -z "$dport" ]; then
          dport=${word#dport=}
        fi
        ;;
      bytes=*)
        bytes=$((bytes + ${word#bytes=}))
        ;;
      delta-time=*)
        delta=${word#delta-time=}
        ;;
      tcp | udp | icmp | icmpv6 | sctp | dccp)
        if [ -z "$proto" ]; then
          proto=$word
        fi
        ;;
      \[*.*\])
        inner=${word#[}
        inner=${inner%]}
        end_unix=${inner%%.*}
        ;;
    esac
  done
  case "$sport" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$dport" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ -z "$proto" ] || [ -z "$src" ] || [ -z "$dst" ]; then
    return 1
  fi
  if [ -n "$delta" ]; then
    start_unix=$((end_unix - delta))
  else
    start_unix=$end_unix
  fi
  start=$(date -u -d "@${start_unix}" +%Y-%m-%dT%H:%M:%SZ)
  end=$(date -u -d "@${end_unix}" +%Y-%m-%dT%H:%M:%SZ)
  # shellcheck disable=SC2016
  jq -nc \
    --arg proto "$proto" \
    --arg src "$src" \
    --arg dst "$dst" \
    --argjson sport "$sport" \
    --argjson dport "$dport" \
    --argjson bytes "$bytes" \
    --arg start "$start" \
    --arg end "$end" \
    --argjson end_unix "$end_unix" \
    '{proto:$proto, src:$src, dst:$dst, sport:$sport, dport:$dport, bytes:$bytes, start:$start, end:$end, domain:null, end_unix:$end_unix}'
}

in_cidr() {
  ip=$1
  cidrs=$(jq -r '.cidrs[]?' "$audit_json")
  [ -n "$cidrs" ] || return 1
  # shellcheck disable=SC2016
  printf '%s\n' "$ip" | CIDRS="$cidrs" awk '
    function ip4(s, a, n) {
      n = split(s, a, ".")
      if (n != 4) return -1
      return a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4]
    }
    BEGIN {
      n = split(ENVIRON["CIDRS"], cs, "\n")
    }
    {
      ip = ip4($0)
      if (ip < 0) exit 1
      for (i = 1; i <= n; i++) {
        if (cs[i] == "") continue
        split(cs[i], p, "/")
        base = ip4(p[1])
        bits = p[2] + 0
        if (base < 0 || bits < 0 || bits > 32) continue
        if (bits == 0) mask = 0
        else mask = int(2 ^ 32 - 2 ^ (32 - bits))
        if (and(int(ip), mask) == and(int(base), mask)) exit 0
      }
      exit 1
    }
  '
}

append_log() {
  log=$1
  text=$2
  mkdir -p "$(dirname "$log")"
  touch "$log" "${log}.lock"
  {
    flock 9
    printf '%s\n' "$text" >> "$log"
  } 9>>"${log}.lock"
}

prune_log() {
  log=$1
  keep=$2
  [ -s "$log" ] || return 0
  cutoff=$(($(date +%s) - keep))
  tmp=$(mktemp)
  touch "${log}.lock"
  {
    flock 9
    # shellcheck disable=SC2016
    jq -c --argjson cut "$cutoff" 'select((.end_unix // 0) >= $cut)' "$log" > "$tmp"
    mv "$tmp" "$log"
  } 9>>"${log}.lock"
}

refresh_names() {
  now=$(date +%s)
  if [ $((now - names_at)) -lt 2 ]; then
    return 0
  fi
  names_at=$now
  mkdir -p "$(dirname "$names")"
  tmp=$(mktemp)
  if curl -fsS --max-time 1 http://127.0.0.1:9090/connections -o "$tmp" 2>/dev/null; then
    jq -r '.connections[]? | select(.metadata.host != null and .metadata.host != "") | "\(.metadata.destinationIP):\(.metadata.destinationPort) \(.metadata.host)"' "$tmp" > "$names" || true
  fi
  rm -f "$tmp"
}

domain_for() {
  dst=$1
  dport=$2
  [ -f "$names" ] || return 0
  # shellcheck disable=SC2016
  awk -v key="${dst}:${dport}" '$1 == key { print $2; exit }' "$names" || true
}

require_enabled() {
  if [ ! -f "$audit_json" ] || [ "$(jq -r '.enable // false' "$audit_json")" != true ]; then
    echo "janus audit is not in this image. Set janus.monitoring.audit.enable and rebuild." >&2
    exit 2
  fi
}

record() {
  require_enabled
  log=$(log_path)
  keep=$(retention_seconds)
  mkdir -p "$(dirname "$log")"
  if [ "${JANUS_AUDIT_FEED:-}" != 1 ]; then
    mkdir -p "$(dirname "$names")"
  fi
  prune_log "$log" "$keep"
  n=0
  if [ "${JANUS_AUDIT_FEED:-}" = 1 ]; then
    feed() { cat; }
  else
    feed() { conntrack -E -e DESTROY -o timestamp,extended; }
  fi
  feed | while IFS= read -r line; do
    json=$(parse_line "$line") || continue
    src=$(printf '%s\n' "$json" | jq -r .src)
    in_cidr "$src" || continue
    if [ "${JANUS_AUDIT_FEED:-}" != 1 ]; then
      refresh_names || true
    fi
    dst=$(printf '%s\n' "$json" | jq -r .dst)
    dport=$(printf '%s\n' "$json" | jq -r .dport)
    host=$(domain_for "$dst" "$dport" || true)
    if [ -n "$host" ]; then
      # shellcheck disable=SC2016
      json=$(printf '%s\n' "$json" | jq -c --arg d "$host" '.domain = $d')
    fi
    append_log "$log" "$json"
    n=$((n + 1))
    if [ $((n % 200)) -eq 0 ]; then
      prune_log "$log" "$keep"
    fi
  done
}

cmd=${1:-}
case "$cmd" in
  start)
    require_enabled
    rm -f "$paused"
    systemctl start janus-audit.service
    ;;
  stop)
    require_enabled
    mkdir -p "$(dirname "$paused")"
    touch "$paused"
    systemctl stop janus-audit.service || true
    ;;
  status)
    require_enabled
    log=$(log_path)
    if systemctl is-active --quiet janus-audit.service; then
      echo "recording: on"
    else
      echo "recording: off"
    fi
    echo "path: ${log}"
    if [ -f "$log" ]; then
      echo "size: $(wc -c < "$log" | tr -d '[:space:]')"
      oldest=$(head -n 1 "$log" | jq -r '.start // .end // empty' 2>/dev/null || true)
    else
      echo "size: 0"
      oldest=""
    fi
    if [ -n "$oldest" ]; then
      echo "oldest: ${oldest}"
    else
      echo "oldest:"
    fi
    ;;
  export)
    require_enabled
    log=$(log_path)
    if [ -f "$log" ]; then
      cat "$log"
    fi
    ;;
  record) record ;;
  parse)
    IFS= read -r line || true
    parse_line "$line"
    ;;
  *)
    echo "janus-audit start|stop|status|export" >&2
    exit 2
    ;;
esac
