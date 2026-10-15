# Prometheus text for node exporter's textfile collector. FR-MON-004.
# collect writes /var/lib/janus/monitoring/textfile/janus.prom.
# render writes the same text to stdout from the files named by the environment.
out_dir=${JANUS_METRICS_DIR:-/var/lib/janus/monitoring/textfile}
selection=${JANUS_SELECTION:-/var/lib/janus/engine/selection.json}
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
  local sec err name group node delay
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

  declare -A chosen=()
  if [ -n "$proxies" ] && [ -f "$proxies" ]; then
    while IFS= read -r row; do
      group=$(printf '%s' "$row" | jq -r '.g')
      node=$(printf '%s' "$row" | jq -r '.n')
      [ -n "$group" ] && [ -n "$node" ] || continue
      chosen["$group"]=$node
    done < <(jq -c '.proxies // {} | to_entries[] | select(.value.now != null and .value.now != "") | {g:.key,n:.value.now}' "$proxies")
  fi
  if [ -f "$selection" ]; then
    while IFS= read -r row; do
      group=$(printf '%s' "$row" | jq -r '.g')
      node=$(printf '%s' "$row" | jq -r '.n')
      [ -n "$group" ] && [ -n "$node" ] || continue
      if [ -z "${chosen[$group]+x}" ]; then
        chosen["$group"]=$node
      fi
    done < <(jq -c 'to_entries[] | select(.value.node != null and .value.node != "") | {g:.key,n:.value.node}' "$selection")
  fi

  printf '%s\n' \
    '# HELP janus_proxy_selected 1 for the node selected in a group.' \
    '# TYPE janus_proxy_selected gauge'
  if [ "${#chosen[@]}" -gt 0 ]; then
    for group in "${!chosen[@]}"; do
      printf 'janus_proxy_selected{group=%s,node=%s} 1\n' "$(quote "$group")" "$(quote "${chosen[$group]}")"
    done
  fi

  printf '%s\n' \
    '# HELP janus_proxy_group_latency_milliseconds Last delay recorded for the node selected in a group.' \
    '# TYPE janus_proxy_group_latency_milliseconds gauge'
  if [ -n "$proxies" ] && [ -f "$proxies" ]; then
    while IFS= read -r row; do
      group=$(printf '%s' "$row" | jq -r '.g')
      node=$(printf '%s' "$row" | jq -r '.n')
      delay=$(printf '%s' "$row" | jq -r '.d')
      [ -n "$group" ] && [ -n "$node" ] && [ -n "$delay" ] || continue
      printf 'janus_proxy_group_latency_milliseconds{group=%s,node=%s} %s\n' "$(quote "$group")" "$(quote "$node")" "$delay"
    done < <(jq -c '
      .proxies as $p
      | ($p // {})
      | to_entries[]
      | select(.value.now != null and .value.now != "")
      | .key as $g
      | .value.now as $n
      | ($p[$n].history[-1].delay // null) as $d
      | select($d != null and $d > 0)
      | {g:$g,n:$n,d:$d}
    ' "$proxies")
  fi
}

collect() {
  local up=0 tmp=""
  mkdir -p "$out_dir"
  up=0
  if systemctl is-active --quiet janus-engine.service; then
    up=1
  fi
  tmp=$(mktemp)
  if ! curl -fsS --max-time 2 http://127.0.0.1:9090/proxies -o "$tmp"; then
    rm -f "$tmp"
    tmp=""
  fi
  JANUS_ENGINE_UP=$up JANUS_PROXIES=$tmp render > "$out_dir/janus.prom.new"
  mv "$out_dir/janus.prom.new" "$out_dir/janus.prom"
  rm -f "$tmp"
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
