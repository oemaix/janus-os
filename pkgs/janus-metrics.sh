# Prometheus text for node exporter's textfile collector. FR-MON-004.
# collect writes /var/lib/janus/monitoring/textfile/janus.prom.
# render writes the same text to stdout from the files named by the environment.
out_dir=${JANUS_METRICS_DIR:-/var/lib/janus/monitoring/textfile}
sub_dir=${JANUS_SUBSCRIPTION_DIR:-/var/lib/janus/subscriptions}
geo_stamp=${JANUS_GEODATA_STAMP:-/var/lib/janus/geodata/refresh.stamp}
geo_error=${JANUS_GEODATA_ERROR:-/var/lib/janus/geodata/refresh.error}

quote() {
  jq -nr --arg s "$1" '$s | @json'
}

stamp_seconds() {
  local file=$1
  local text
  [ -f "$file" ] || return 1
  text=$(tr -d '[:space:]' < "$file")
  [ -n "$text" ] || return 1
  date -u -d "$text" +%s
}

render() {
  local up=${JANUS_ENGINE_UP:-0}
  local proxies=${JANUS_PROXIES:-}
  local picked=${JANUS_PICKED:-}
  local sec err name node delay
  case "$up" in
    0 | 1) ;;
    *) up=0 ;;
  esac
  printf '%s\n' \
    '# HELP janus_engine_up 1 when the proxy engine service is active.' \
    '# TYPE janus_engine_up gauge' \
    "janus_engine_up ${up}" \
    '# HELP janus_subscription_refresh_timestamp_seconds Unix time of the last successful subscription refresh.' \
    '# TYPE janus_subscription_refresh_timestamp_seconds gauge' \
    '# HELP janus_subscription_refresh_error 1 when the last subscription refresh failed.' \
    '# TYPE janus_subscription_refresh_error gauge'

  if [ -d "$sub_dir" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      sec=$(stamp_seconds "$sub_dir/$name.stamp" || true)
      if [ -n "$sec" ]; then
        printf 'janus_subscription_refresh_timestamp_seconds{subscription=%s} %s\n' "$(quote "$name")" "$sec"
      fi
      err=0
      if [ -s "$sub_dir/$name.error" ]; then
        err=1
      fi
      printf 'janus_subscription_refresh_error{subscription=%s} %s\n' "$(quote "$name")" "$err"
    done < <(
      if [ -d "$sub_dir" ]; then
        for f in "$sub_dir"/*.stamp "$sub_dir"/*.error; do
          [ -e "$f" ] || continue
          base=$(basename "$f")
          base=${base%.stamp}
          base=${base%.error}
          printf '%s\n' "$base"
        done | sort -u
      fi
    )
  fi

  printf '%s\n' \
    '# HELP janus_geodata_refresh_timestamp_seconds Unix time of the last successful Geo refresh.' \
    '# TYPE janus_geodata_refresh_timestamp_seconds gauge'
  sec=$(stamp_seconds "$geo_stamp" || true)
  if [ -n "$sec" ]; then
    printf 'janus_geodata_refresh_timestamp_seconds %s\n' "$sec"
  fi
  printf '%s\n' \
    '# HELP janus_geodata_refresh_error 1 when the last Geo refresh failed.' \
    '# TYPE janus_geodata_refresh_error gauge'
  err=0
  if [ -s "$geo_error" ]; then
    err=1
  fi
  printf 'janus_geodata_refresh_error %s\n' "$err"

  printf '%s\n' \
    '# HELP janus_proxy_selected 1 for a node the engine picked.' \
    '# TYPE janus_proxy_selected gauge'
  if [ -n "$picked" ] && [ -s "$picked" ]; then
    while IFS=$'\t' read -r node delay; do
      [ -n "$node" ] || continue
      printf 'janus_proxy_selected{node=%s} 1\n' "$(quote "$node")"
    done < "$picked"
  elif [ -n "$proxies" ] && [ -f "$proxies" ]; then
    while IFS= read -r node; do
      [ -n "$node" ] || continue
      printf 'janus_proxy_selected{node=%s} 1\n' "$(quote "$node")"
    done < <(jq -r '
      .proxies // {}
      | to_entries[]
      | select(.key | startswith("sel-"))
      | .value.now
      | select(. != null and . != "")
    ' "$proxies" | sort -u)
  fi

  printf '%s\n' \
    '# HELP janus_proxy_latency_milliseconds Last delay recorded for a node the engine picked.' \
    '# TYPE janus_proxy_latency_milliseconds gauge'
  if [ -n "$picked" ] && [ -s "$picked" ]; then
    while IFS=$'\t' read -r node delay; do
      [ -n "$node" ] || continue
      case "$delay" in
        ''|*[!0-9]*) continue ;;
      esac
      [ "$delay" -gt 0 ] || continue
      printf 'janus_proxy_latency_milliseconds{node=%s} %s\n' "$(quote "$node")" "$delay"
    done < "$picked"
  elif [ -n "$proxies" ] && [ -f "$proxies" ]; then
    while IFS= read -r row; do
      node=$(printf '%s' "$row" | jq -r '.n')
      delay=$(printf '%s' "$row" | jq -r '.d')
      [ -n "$node" ] && [ -n "$delay" ] || continue
      printf 'janus_proxy_latency_milliseconds{node=%s} %s\n' "$(quote "$node")" "$delay"
    done < <(jq -c '
      .proxies as $p
      | [ $p // {} | to_entries[] | select(.key | startswith("sel-")) | .value.now | select(. != null and . != "") ] | unique[]
      | . as $n
      | ($p[$n].history[-1].delay // null) as $d
      | select($d != null and $d > 0)
      | {n:$n,d:$d}
    ' "$proxies")
  fi
}

collect() {
  local up=0 tmp="" picked=""
  mkdir -p "$out_dir"
  up=0
  if systemctl is-active --quiet janus-engine.service; then
    up=1
  fi
  tmp=$(mktemp)
  picked=$(mktemp)
  : > "$picked"
  if ! curl -fsS --max-time 2 http://127.0.0.1:9090/proxies -o "$tmp"; then
    rm -f "$tmp"
    tmp=""
    if [ -x /etc/janus/bin/janus-proxy ]; then
      /etc/janus/bin/janus-proxy picked > "$picked" || : > "$picked"
    fi
  fi
  JANUS_ENGINE_UP=$up JANUS_PROXIES=$tmp JANUS_PICKED=$picked render > "$out_dir/janus.prom.new"
  mv "$out_dir/janus.prom.new" "$out_dir/janus.prom"
  rm -f "$tmp" "$picked"
}

cmd=${1:-collect}
case "$cmd" in
  render) render ;;
  collect) collect ;;
  *)
    echo "janus-metrics <render|collect>" >&2
    exit 2
    ;;
esac
