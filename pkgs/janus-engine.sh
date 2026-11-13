# Runtime helper for the sing-box engine. docs/07, docs/14, ADR-0011, ADR-0016.
# The Nix module sets JANUS_SCRIPT, JANUS_FAIL_MODE, JANUS_INTERCEPT, and JANUS_EGRESS_TABLE.
model=/etc/janus/proxy-model.json
meta=/etc/janus/subscriptions.json
# nodes-manual.json is already inside nodes-built.json.
built=/etc/janus/nodes-built.json
cfg=/var/lib/janus/engine/config.json
labels=/var/lib/janus/engine/node-labels.json
latency=/var/lib/janus/engine/latency.json
probes=/var/lib/janus/engine/probes.json
policy=/etc/janus/dns-policy.json
tags=/etc/janus/geodata-tags.json
sources=/etc/janus/geodata-sources.json
clash=http://127.0.0.1:9090

die() {
  echo "janus: $*" >&2
  exit 1
}

usage() {
  echo "janus-proxy <intercept-up|tun-up|tun-down|render|refresh|geodata-missing|geodata-refresh|nodes|probe|dns-query|dns-flush|dns-stats|dns-check>" >&2
  exit 2
}

ensure_dirs() {
  mkdir -p /var/lib/janus/engine /var/lib/janus/geodata /var/lib/janus/subscriptions /var/lib/janus/secrets
}

tproxy_route() {
  ip rule del fwmark 0x4a02 lookup 2023 priority 109 2>/dev/null || true
  ip -6 rule del fwmark 0x4a02 lookup 2023 priority 109 2>/dev/null || true
  ip rule add fwmark 0x4a02 lookup 2023 priority 109
  ip -6 rule add fwmark 0x4a02 lookup 2023 priority 109
  ip route replace local 0.0.0.0/0 dev lo table 2023
  ip -6 route replace local ::/0 dev lo table 2023
}

rule_add() {
  ip rule del fwmark 0x4a01 lookup 2022 priority 110 2>/dev/null || true
  ip -6 rule del fwmark 0x4a01 lookup 2022 priority 110 2>/dev/null || true
  ip rule add fwmark 0x4a01 lookup 2022 priority 110
  ip -6 rule add fwmark 0x4a01 lookup 2022 priority 110
  if [ -n "${JANUS_EGRESS_TABLE}" ]; then
    ip rule del fwmark 0x4a lookup "${JANUS_EGRESS_TABLE}" priority 100 2>/dev/null || true
    ip rule add fwmark 0x4a lookup "${JANUS_EGRESS_TABLE}" priority 100
  fi
}

blackhole() {
  ip route replace blackhole default table 2022
  ip -6 route replace blackhole default table 2022
}

# xray's closed path is tproxy. That does not rewrite the destination
# port, so the log matches mark 0x4a02 after the mangle hook (D-0069,
# T-0029). The table exists only while the process is down.
closed_log_install() {
  [ "${JANUS_CLOSED_LOG:-0}" = 1 ] || return 0
  [ -n "${JANUS_CLOSED_LOG_NFT:-}" ] || return 0
  [ -f "${JANUS_CLOSED_LOG_NFT}" ] || return 0
  nft delete table inet janus_closed_log 2>/dev/null || true
  nft -f "${JANUS_CLOSED_LOG_NFT}"
}

closed_log_remove() {
  [ "${JANUS_CLOSED_LOG:-0}" = 1 ] || return 0
  nft delete table inet janus_closed_log 2>/dev/null || true
}

intercept_up() {
  if [ "${JANUS_DNS_TPROXY}" = 1 ] || [ "${JANUS_ENGINE}" = xray ]; then
    tproxy_route
  fi
  [ "${JANUS_INTERCEPT}" = 1 ] || return 0
  if [ "${JANUS_ENGINE}" = xray ]; then
    # A restart of this oneshot must not log a live session. tun-up
    # removes the table once the process is active (T-0029).
    if [ "${JANUS_FAIL_MODE}" = closed ] && ! systemctl is-active --quiet janus-engine; then
      closed_log_install
    fi
    return 0
  fi
  rule_add
  if [ "${JANUS_FAIL_MODE}" = closed ]; then
    blackhole
  fi
}

apply_selection() {
  return 0
}

xray_pin_balancers() {
  return 0
}

tun_up() {
  # networkd can flush the fwmark rule between intercept-up and here.
  # DNS tproxy needs it for sing-box and for xray, including a LAN that
  # is not intercepted. xray returns below, so this has to run first.
  if [ "${JANUS_DNS_TPROXY}" = 1 ]; then
    tproxy_route
  fi
  if [ "${JANUS_ENGINE}" = xray ]; then
    closed_log_remove
    if [ "${JANUS_FAIL_MODE}" = open ] && [ -n "${JANUS_XRAY_NFT:-}" ]; then
      nft delete table inet janus_xray 2>/dev/null || true
      nft -f "$JANUS_XRAY_NFT"
    fi
    xray_pin_balancers
    return 0
  fi
  [ "${JANUS_INTERCEPT}" = 1 ] || return 0
  if [ "${JANUS_FAIL_MODE}" = open ]; then
    rule_add
  fi
  i=0
  while [ ! -d /sys/class/net/tun0 ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -d /sys/class/net/tun0 ] || die "tun0 did not appear"
  ip route replace default dev tun0 table 2022
  ip -6 route replace default dev tun0 table 2022
  apply_selection
}

tun_down() {
  if [ "${JANUS_ENGINE}" = xray ]; then
    if [ "${JANUS_FAIL_MODE}" = open ]; then
      nft delete table inet janus_xray 2>/dev/null || true
    else
      closed_log_install
    fi
    return 0
  fi
  [ "${JANUS_INTERCEPT}" = 1 ] || return 0
  if [ "${JANUS_FAIL_MODE}" = open ]; then
    ip rule del fwmark 0x4a01 lookup 2022 priority 110 2>/dev/null || true
    ip -6 rule del fwmark 0x4a01 lookup 2022 priority 110 2>/dev/null || true
    ip route del default table 2022 2>/dev/null || true
    ip -6 route del default table 2022 2>/dev/null || true
    return 0
  fi
  blackhole
}

merge_nodes() {
  ensure_dirs
  out=$(mktemp)
  runtime=$(mktemp)
  echo '[]' > "$runtime"
  # subscriptions.json lists the enabled subscriptions in this image.
  # A cache left on the state partition for a subscription this router
  # dropped is not a node source (D-0044).
  # bashNonInteractive has no compgen. A missing match leaves the literal
  # glob, and [ -f ] skips it (T-0031).
  if [ -f "$meta" ]; then
    picked=$(mktemp -d)
    count=0
    for file in /var/lib/janus/subscriptions/*.json; do
      [ -f "$file" ] || continue
      name=${file##*/}
      name=${name%.json}
      if jq -e --arg name "$name" 'has($name)' "$meta" >/dev/null; then
        cp "$file" "$picked/$count.json"
        count=$((count + 1))
      fi
    done
    if [ "$count" -gt 0 ]; then
      jq -s 'add' "$picked"/*.json > "$runtime"
    fi
    rm -rf "$picked"
  fi
  # nodes-built.json already contains the manual nodes. Adding that file
  # again duplicates every tag, and xray rejects the config.
  jq -s '
    (.[0]) as $base
    | (.[1] | map(select(.name | contains("/")) | .name | split("/")[0]) | unique) as $replaced
    | ($base | map(select(
        ((.name | contains("/")) | not)
        or (((.name | split("/")[0]) as $p | $replaced | index($p)) | not)
      ))) + .[1]
  ' "$built" "$runtime" > "$out"
  rm -f "$runtime"
  printf '%s\n' "$out"
}

carrier_model() {
  src=$1
  dst=$2
  cp "$src" "$dst"
  [ -f "$policy" ] || return 0
  mode=$(jq -r '.carrierResolvers' "$policy")
  enc=$(jq -r '.encryption' "$policy")
  [ "$mode" = never ] && return 0
  if [ "$enc" = require ]; then
    echo "janus: carrier resolvers are plaintext, so encryption = require ignores them" >&2
    return 0
  fi
  ips=$(mktemp)
  # Same missing compgen as merge_nodes (T-0031).
  found=0
  for file in /run/janus/wan/*/dns; do
    if [ -f "$file" ]; then
      found=1
      break
    fi
  done
  if [ "$found" = 1 ]; then
    grep -h . /run/janus/wan/*/dns | awk 'NF && !seen[$0]++' > "$ips" || true
  else
    : > "$ips"
  fi
  if [ ! -s "$ips" ]; then
    rm -f "$ips"
    return 0
  fi
  if [ "$mode" = domestic-only ]; then
    # One DNS rule names one server. The first learned address becomes that
    # server. sing-box has no failover group, and xray 26 does not stably
    # share one name across two servers.
    jq --rawfile ips "$ips" '
      .dns.domestic.resolvers =
        ([$ips | split("\n")[] | select(length > 0) | "udp://" + .] | unique)
        + .dns.domestic.resolvers
    ' "$src" > "$dst"
  elif [ "$mode" = fallback-only ]; then
    echo "janus: fallback-only is not available. sing-box has no DNS failover group, and xray 26 does not stably match one name on two servers. The carrier addresses stay unused." >&2
  fi
  rm -f "$ips"
}

# A board file is the password. A sops node file is the YAML document,
# with a password key, because secret set stores that document whole.
password_from_file() {
  path=$1
  if grep -q '^password:' "$path"; then
    pw=$(sed -n 's/^password:[[:space:]]*//p' "$path" | head -n 1)
    pw=${pw#\"}
    pw=${pw%\"}
    printf '%s' "$pw"
  else
    cat "$path"
  fi
}

apply_passwords() {
  src=$1
  map=/etc/janus/password-files.json
  [ -f "$map" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path=$(jq -r --arg n "$name" '.[$n]' "$map")
    if [ ! -f "$path" ]; then
      die "password file ${path} for ${name} is missing"
    fi
    pw=$(password_from_file "$path")
    next=$(mktemp)
    if [ "${JANUS_ENGINE}" = xray ]; then
      jq --arg tag "$name" --arg pw "$pw" \
        '.outbounds |= map(if .tag == $tag then
          if .protocol == "trojan" or .protocol == "shadowsocks" then .settings.servers[0].password = $pw
          else . end
        else . end)' \
        "$src" > "$next"
    else
      jq --arg tag "$name" --arg pw "$pw" \
        '.outbounds |= map(if .tag == $tag then .password = $pw else . end)' \
        "$src" > "$next"
    fi
    mv "$next" "$src"
  done < <(jq -r 'keys[]' "$map")
}

apply_saved_selection() {
  src=$1
  dst=$2
  cp "$src" "$dst"
}

hold_engine_lock() {
  if [ "${JANUS_ENGINE_LOCK_HELD:-0}" = 1 ]; then
    return 0
  fi
  mkdir -p /var/lib/janus/engine
  exec 9>>/var/lib/janus/engine/render.lock
  flock 9
  JANUS_ENGINE_LOCK_HELD=1
}

wait_for_node_dns() {
  [ -n "${JANUS_DIG:-}" ] || return 0
  nodes=$(merge_nodes)
  host=$(jq -r '[.[] | .server // empty | select(test("^[0-9.]+$") | not) | select(contains(":") | not)] | .[0] // empty' "$nodes")
  rm -f "$nodes"
  [ -n "$host" ] || return 0
  i=0
  while [ "$i" -lt 6 ]; do
    if "$JANUS_DIG" +time=2 +tries=1 +short "$host" A | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
      return 0
    fi
    if "$JANUS_DIG" +time=2 +tries=1 +short "$host" AAAA | grep -q ':'; then
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done
}

# One name and its engine delay per line. sing-box reads the Clash API.
# xray leastPing is the observatory's lowest alive delay inside each balancer.
picked_nodes() {
  out=$1
  : > "$out"
  if [ "${JANUS_ENGINE:-}" = xray ]; then
    ois=$(mktemp)
    if [ -n "${JANUS_OIS_JSON:-}" ]; then
      cp "$JANUS_OIS_JSON" "$ois"
    elif ! xray api ois -s 127.0.0.1:8080 > "$ois" 2>/dev/null; then
      rm -f "$ois"
      return 0
    fi
    engine_cfg=${JANUS_ENGINE_CONFIG:-$cfg}
    if ! jq -r --slurpfile ois "$ois" '
      def rows:
        if ((.status // null) | type) == "object" then (.status.status // [])
        elif ((.status // null) | type) == "array" then .status
        else [] end;
      ($ois[0] | rows) as $rows
      | [ .routing.balancers[]?
          | select(.strategy.type == "leastPing")
          | . as $bal
          | [ $rows[]
              | select(.alive == true)
              | (.outboundTag // .outbound_tag // "") as $t
              | select($t != "" and (($bal.selector // []) | index($t)))
              | {name: $t, delay: (.delay // 0)} ]
          | sort_by(.delay)
          | .[0]
          | select(. != null) ]
      | group_by(.name)
      | .[]
      | "\(.[0].name)\t\([.[].delay] | min)"
    ' "$engine_cfg" > "$out"; then
      : > "$out"
    fi
    rm -f "$ois"
    return 0
  fi
  api=$(mktemp)
  if [ -n "${JANUS_PROXIES:-}" ]; then
    cp "$JANUS_PROXIES" "$api"
  elif ! curl -fsS --max-time 2 "${clash}/proxies" -o "$api"; then
    echo '{}' > "$api"
  fi
  if ! jq -r '
    .proxies as $p
    | [ $p // {} | to_entries[]
        | select(.key | startswith("sel-"))
        | .value.now
        | select(. != null and . != "") ] | unique[]
    | . as $n
    | ($p[$n].history[-1].delay // 0) as $d
    | if ($d | type) == "number" and $d > 0 then "\($n)\t\($d)" else "\($n)\t" end
  ' "$api" > "$out"; then
    : > "$out"
  fi
  rm -f "$api"
}

# A node that left the subscription drops its latency sample and HTTP mark.
# A failed probe still keeps the previous value of a node that is still present.
prune_label_state() {
  list=$1
  names=$(mktemp)
  jq -c '[.[].name | select(. != null)]' "$list" > "$names"
  for state in "$latency" "$probes"; do
    [ -f "$state" ] || continue
    next=$(mktemp)
    if [ "$state" = "$latency" ]; then
      jq --slurpfile names "$names" '
        ($names[0]) as $names
        | with_entries(select(.key as $k | $names | index($k)))
      ' "$state" > "$next"
    else
      jq --slurpfile names "$names" '
        ($names[0]) as $names
        | with_entries(
            if (.value | type) == "object"
            then .value |= with_entries(select(.key as $k | $names | index($k)))
            else empty
            end)
      ' "$state" > "$next"
    fi
    mv "$next" "$state"
    chmod 0600 "$state"
  done
  rm -f "$names"
}

render_config() {
  hold_engine_lock
  ensure_dirs
  nodes=$(merge_nodes)
  prune_label_state "$nodes"
  work=$(mktemp)
  selected=$(mktemp)
  # Xray reads the format from the suffix. A bare mktemp name fails the
  # test and the config is never installed (T-0030).
  out=$(mktemp --suffix=.json)
  carrier_model "$model" "$work"
  apply_saved_selection "$work" "$selected"
  args=(janet "$JANUS_SCRIPT" render --model "$selected" --nodes "$nodes" --rule-set local --engine "${JANUS_ENGINE}" --latency "$latency" --probes "$probes" --labels "$labels")
  if [ -f /etc/janus/geoip.dat ]; then
    args+=(--geoip /etc/janus/geoip.dat --resolve)
  fi
  args+=(--output "$out")
  "${args[@]}"
  apply_passwords "$out"
  if [ "${JANUS_ENGINE}" = xray ]; then
    xray run -test -c "$out"
  else
    sing-box check -c "$out"
  fi
  if [ -f "$cfg" ]; then
    cp -a "$cfg" "${cfg}.prev"
  fi
  mv "$out" "$cfg"
  if grep -q '^janus-engine:' /etc/group 2>/dev/null; then
    chgrp janus-engine "$cfg"
    chmod 0640 "$cfg"
  else
    chmod 0600 "$cfg"
  fi
  rm -f "$nodes" "$work" "$selected"
}

# A function called from `if` ignores set -e, and so does a subshell it starts.
# A new bash does not, and die() exits only that bash, so the caller can record it.
# $BASH is this interpreter. The service PATH has no bash.
render_or_fail() {
  "$BASH" "$0" render-internal
}

geo_base() {
  tag=$1
  if printf '%s' "$tag" | grep -q '^geoip-'; then
    jq -r '.geoip' "$sources"
  else
    jq -r '.geosite' "$sources"
  fi
}

geo_url() {
  tag=$1
  specific=$(jq -r --arg t "$tag" '.tags[$t] // empty' "$sources")
  if [ -n "$specific" ]; then
    printf '%s\n' "$specific"
    return
  fi
  printf '%s/%s.srs\n' "$(geo_base "$tag")" "$tag"
}

download_tag() {
  tag=$1
  dest="/var/lib/janus/geodata/${tag}.srs"
  url=$(geo_url "$tag")
  curl_args=(-fsSL --retry 2 --max-time 60 -o "${dest}.partial")
  if [ -d /sys/class/net/tun0 ]; then
    curl_args+=(--socks5-hostname 127.0.0.1:2080)
  fi
  if ! curl "${curl_args[@]}" -- "$url"; then
    rm -f "${dest}.partial"
    echo "janus: geo download failed for ${tag}" >&2
    return 1
  fi
  if [ ! -s "${dest}.partial" ]; then
    rm -f "${dest}.partial"
    echo "janus: geo file for ${tag} was empty" >&2
    return 1
  fi
  mv "${dest}.partial" "$dest"
}

geodata_missing() {
  ensure_dirs
  fail=0
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if [ -s "/var/lib/janus/geodata/${tag}.srs" ]; then
      continue
    fi
    if [ -s "/etc/janus/geodata/${tag}.srs" ]; then
      cp -a "/etc/janus/geodata/${tag}.srs" "/var/lib/janus/geodata/${tag}.srs"
      continue
    fi
    download_tag "$tag" || fail=1
  done < <(jq -r '.[]' "$tags")
  [ "$fail" = 0 ]
}

geodata_refresh() {
  ensure_dirs
  fail=0
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    download_tag "$tag" || fail=1
  done < <(jq -r '.[]' "$tags")
  if [ "$fail" != 0 ]; then
    printf '%s\n' "geo refresh failed" > /var/lib/janus/geodata/refresh.error
    die "geo refresh failed"
  fi
  if ! render_or_fail; then
    printf '%s\n' "render after geo refresh failed" > /var/lib/janus/geodata/refresh.error
    die "render after geo refresh failed"
  fi
  if ! systemctl restart janus-engine.service; then
    printf '%s\n' "engine did not reload after geo refresh" > /var/lib/janus/geodata/refresh.error
    die "engine did not reload after geo refresh"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/janus/geodata/refresh.stamp
  rm -f /var/lib/janus/geodata/refresh.error
}

subscription_url() {
  name=$1
  key="proxy.subscriptions.${name}.url"
  url=""
  # Tests point these at a temp dir. On the router the defaults are the live paths.
  overrides=${JANUS_OVERRIDES:-/var/lib/janus/overrides.json}
  secrets_run=${JANUS_SECRETS_RUN:-/run/secrets}
  saved_dir=${JANUS_SUBSCRIPTION_URLS:-/var/lib/janus/subscription-urls}
  if [ -f "$overrides" ]; then
    url=$(jq -r --arg k "$key" '.[$k] // empty' "$overrides")
  fi
  if [ -z "$url" ]; then
    secret=$(jq -r --arg n "$name" '.[$n].urlSecret // empty' "$meta")
    if [ -n "$secret" ] && [ -s "${secrets_run}/${secret}" ]; then
      case $(head -n 1 "${secrets_run}/${secret}") in
        "age-encryption.org"*|"-----BEGIN AGE ENCRYPTED FILE-----")
          fail_sub "subscription ${name} secret is age armor; rewrite it with janus-build secret set"
          ;;
        *)
          url=$(tr -d '\n' < "${secrets_run}/${secret}")
          ;;
      esac
    elif [ -f "${saved_dir}/${name}" ]; then
      url=$(cat "${saved_dir}/${name}")
    fi
  fi
  printf '%s' "$url"
}

fail_sub() {
  mkdir -p /var/lib/janus/subscriptions
  printf '%s\n' "$*" > "/var/lib/janus/subscriptions/${name}.error"
  die "$*"
}

refresh_one() {
  name=$1
  [ -n "$name" ] || die "subscription name is required"
  jq -e --arg n "$name" 'has($n)' "$meta" >/dev/null || fail_sub "subscription ${name} is not in this image"
  url=$(subscription_url "$name")
  [ -n "$url" ] || fail_sub "subscription ${name} has no url"
  fmt=$(jq -r --arg n "$name" '.[$n].format' "$meta")
  via=$(jq -r --arg n "$name" '.[$n].via' "$meta")
  filt=$(jq -r --arg n "$name" '.[$n].nameFilter // empty' "$meta")
  min=$(jq -r --arg n "$name" '.[$n].minimumNodes' "$meta")
  raw=$(mktemp)
  nodes=$(mktemp)
  args=(-fsSL --retry 2 --max-time 60 -o "$raw")
  ua=$(jq -r --arg n "$name" '.[$n].userAgent // empty' "$meta")
  if [ -n "$ua" ]; then
    args+=(-A "$ua")
  fi
  while IFS= read -r header; do
    [ -n "$header" ] || continue
    args+=(-H "$header")
  done < <(jq -r --arg n "$name" '.[$n].headers // {} | to_entries[] | "\(.key): \(.value)"' "$meta")
  case "$via" in
    direct)
      curl "${args[@]}" -- "$url" || fail_sub "fetch of ${name} failed"
      ;;
    tunnel-then-direct)
      curl "${args[@]}" --socks5-hostname 127.0.0.1:2080 -- "$url" \
        || curl "${args[@]}" -- "$url" \
        || fail_sub "fetch of ${name} failed"
      ;;
    *)
      curl "${args[@]}" --socks5-hostname 127.0.0.1:2080 -- "$url" || fail_sub "fetch of ${name} failed"
      ;;
  esac
  norm=(janet "$JANUS_SCRIPT" normalize --format "$fmt" --prefix "$name" --input "$raw" --output "$nodes")
  if [ -n "$filt" ]; then
    norm+=(--filter-kind regex --filter-pattern "$filt")
  fi
  "${norm[@]}" || fail_sub "normalize of ${name} failed"
  count=$(jq 'length' "$nodes")
  if [ "$count" -lt "$min" ]; then
    rm -f "$raw" "$nodes"
    fail_sub "${name} returned ${count} nodes, minimum is ${min}"
  fi
  dest="/var/lib/janus/subscriptions/${name}.json"
  if [ -f "$dest" ]; then
    cp -a "$dest" "${dest}.prev"
  fi
  mv "$nodes" "$dest"
  chmod 0600 "$dest"
  rm -f "$raw"
  if ! render_or_fail; then
    if [ -f "${dest}.prev" ]; then
      mv "${dest}.prev" "$dest"
    fi
    if [ -f "${cfg}.prev" ]; then
      mv "${cfg}.prev" "$cfg"
    fi
    fail_sub "render after refreshing ${name} failed"
  fi
  if ! systemctl restart janus-engine.service; then
    if [ -f "${dest}.prev" ]; then
      mv "${dest}.prev" "$dest"
    fi
    if [ -f "${cfg}.prev" ]; then
      mv "${cfg}.prev" "$cfg"
    fi
    systemctl restart janus-engine.service || true
    fail_sub "engine did not reload ${name}"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "/var/lib/janus/subscriptions/${name}.stamp"
  rm -f "/var/lib/janus/subscriptions/${name}.error"
}

resolve_name() {
  name=$1
  qtype=$2
  if [ "${JANUS_ENGINE}" = xray ]; then
    mdig @127.0.0.1 -p 5353 +short "$name" -t "$qtype" +timeout=2 +tries=1 || true
  else
    curl -fsS -G "${clash}/dns/query" --data-urlencode "name=${name}" --data-urlencode "type=${qtype}" || true
  fi
}

show_nodes() {
  ensure_dirs
  picked=$(mktemp)
  picked_nodes "$picked"
  src=$labels
  if [ ! -f "$src" ]; then
    src=$(mktemp)
    echo '{}' > "$src"
  fi
  if [ "${JANUS_JSON:-0}" = 1 ]; then
    jq -n --slurpfile labels "$src" --rawfile picked "$picked" '
      ($picked | split("\n") | map(select(. != "") | split("\t")[0])) as $on
      | ($labels[0] // {})
      | to_entries
      | sort_by(.key)
      | map({name: .key, picked: (.key as $n | $on | index($n) != null), labels: .value})
      | {nodes: .}
    '
  else
    jq -r --rawfile picked "$picked" '
      ($picked | split("\n") | map(select(. != "") | split("\t")[0])) as $on
      | to_entries
      | sort_by(.key)
      | .[]
      | .key as $n
      | (if ($on | index($n) != null) then "* " else "  " end) as $mark
      | (.value | to_entries | sort_by(.key) | map("\(.key)=\(.value|tostring)") | join(" ")) as $text
      | $mark + $n + "  " + $text
    ' "$src"
  fi
  if [ "$src" != "$labels" ]; then
    rm -f "$src"
  fi
  rm -f "$picked"
}

probe_labels() {
  hold_engine_lock
  ensure_dirs
  nodes=$(merge_nodes)
  work=$(mktemp)
  selected=$(mktemp)
  carrier_model "$model" "$work"
  cp "$work" "$selected"
  janet "$JANUS_SCRIPT" probe --model "$selected" --nodes "$nodes" --engine "${JANUS_ENGINE}" --latency "$latency" --probes "$probes"
  rm -f "$nodes" "$work" "$selected"
  before=""
  if [ -f "$cfg" ]; then
    before=$(sha256sum "$cfg" | awk '{print $1}')
  fi
  render_config
  after=$(sha256sum "$cfg" | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    systemctl restart janus-engine.service
  fi
}

resolve_labels() {
  hold_engine_lock
  wait_for_node_dns
  before=""
  if [ -f "$cfg" ]; then
    before=$(sha256sum "$cfg" | awk '{print $1}')
  fi
  render_config
  after=$(sha256sum "$cfg" | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    systemctl restart janus-engine.service
  fi
}

report() {
  printf '%s %s\n' "$1" "$2"
  if [ "$1" = fail ]; then
    check_fail=1
  fi
}

is_bogus() {
  answer=$1
  bogus=0
  while IFS= read -r bad; do
    [ -n "$bad" ] || continue
    if printf '%s' "$answer" | grep -q "$bad"; then
      bogus=1
    fi
  done < <(jq -r '.bogusAnswers[]?' "$policy")
  [ "$bogus" = 1 ]
}

is_fake_v4() {
  printf '%s' "$1" | grep -q '198\.1[89]\.'
}

is_global_aaaa() {
  printf '%s' "$1" | grep -Eq ':[0-9a-fA-F]' || return 1
  printf '%s' "$1" | grep -Eq '(^|[^0-9a-fA-F:])fc0[0-3]:' && return 1
  return 0
}

ask_lan() {
  address=$1
  name=$2
  qtype=$3
  if [ -n "$address" ] && [ -n "${JANUS_DIG:-}" ]; then
    "$JANUS_DIG" +short +time=2 +tries=1 "@${address}" "$name" "$qtype" || true
  else
    resolve_name "$name" "$qtype"
  fi
}

check_one_lan() {
  name=$1
  address=$2
  mode=$3
  recursive=$4
  fake=$5
  strip=$6
  probe=$(jq -r '.domesticProbe // "www.baidu.com"' "$policy")
  foreign=$(ask_lan "$address" example.com A)
  domestic=$(ask_lan "$address" "$probe" A)
  if [ "$recursive" = false ]; then
    if [ -n "$foreign" ] || [ -n "$domestic" ]; then
      report fail "${name} resolved a name while dns.recursive is false"
    else
      report pass "${name} answers only local names"
    fi
    return
  fi
  if [ "$mode" = bypass ] || [ "$fake" = false ]; then
    if [ -z "$foreign" ]; then
      report fail "${name} foreign name example.com was not answered"
    elif is_fake_v4 "$foreign"; then
      report fail "${name} foreign name example.com was a fake-IP"
    elif is_bogus "$foreign"; then
      report fail "${name} foreign name example.com matched a bogus answer"
    else
      report pass "${name} foreign name example.com was a real answer"
    fi
    if [ -z "$domestic" ]; then
      report fail "${name} domestic name ${probe} was not answered"
    elif is_fake_v4 "$domestic"; then
      report fail "${name} domestic name ${probe} was a fake-IP"
    else
      report pass "${name} domestic name ${probe} was a real answer"
    fi
  else
    if is_fake_v4 "$foreign"; then
      report pass "${name} foreign name example.com answered from the fake-IP range"
    elif [ -z "$foreign" ]; then
      report fail "${name} foreign name example.com was not answered"
    elif is_bogus "$foreign"; then
      report fail "${name} foreign name example.com matched a bogus answer"
    else
      report fail "${name} foreign name example.com was not a fake-IP"
    fi
    if [ -z "$domestic" ]; then
      report fail "${name} domestic name ${probe} was not answered"
    elif is_fake_v4 "$domestic"; then
      report fail "${name} domestic name ${probe} was a fake-IP"
    elif is_bogus "$domestic"; then
      report fail "${name} domestic name ${probe} matched a bogus answer"
    else
      report pass "${name} domestic name ${probe} was a real answer"
    fi
  fi
  if [ "$strip" = strip-all ] || [ "$strip" = strip-for-proxied ]; then
    aaaa=$(ask_lan "$address" example.com AAAA)
    if is_global_aaaa "$aaaa"; then
      report fail "${name} AAAA for example.com was globally routable"
    else
      report pass "${name} AAAA for example.com was not globally routable"
    fi
  fi
}

dns_check() {
  check_fail=0
  if jq -e '.interceptPlaintext' "$policy" >/dev/null; then
    if nft list table inet janus | grep -q 'redirect to :5353'; then
      report pass "plaintext DNS is redirected to the engine"
    else
      report fail "plaintext DNS is not redirected to the engine"
    fi
  else
    report pass "plaintext interception is disabled in the policy"
  fi
  count=$(jq '.lans | length' "$policy")
  if [ "$count" = 0 ]; then
    check_one_lan router "" "$(jq -r '.mode // "rule-based"' "$policy")" true "$(jq -r '.fakeIp // false' "$policy")" "$(jq -r '.ipv6Answers' "$policy")"
  else
    while IFS= read -r row; do
      check_one_lan \
        "$(printf '%s' "$row" | jq -r '.name')" \
        "$(printf '%s' "$row" | jq -r '.address')" \
        "$(printf '%s' "$row" | jq -r '.mode')" \
        "$(printf '%s' "$row" | jq -r '.recursive')" \
        "$(printf '%s' "$row" | jq -r '.fakeIp')" \
        "$(printf '%s' "$row" | jq -r '.ipv6Answers')"
    done < <(jq -c '.lans[]' "$policy")
  fi
  [ "$check_fail" = 0 ]
}

cmd=${1:-}
if [ -z "$cmd" ]; then
  usage
fi
shift

case "$cmd" in
  intercept-up) intercept_up ;;
  tun-up) tun_up ;;
  tun-down) tun_down ;;
  render) render_config ;;
  render-internal) render_config ;;
  refresh)
    if [ -n "${1:-}" ]; then
      refresh_one "$1"
    else
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        refresh_one "$name"
      done < <(jq -r 'keys[]' "$meta")
    fi
    ;;
  geodata-missing) geodata_missing ;;
  geodata-refresh) geodata_refresh ;;
  nodes) show_nodes ;;
  picked)
    picked=$(mktemp)
    picked_nodes "$picked"
    cat "$picked"
    rm -f "$picked"
    ;;
  probe) probe_labels ;;
  resolve-labels) resolve_labels ;;
  dns-query)
    name=${1:-}
    if [ -z "$name" ]; then
      usage
    fi
    resolve_name "$name" A
    ;;
  dns-flush)
    if [ "${JANUS_ENGINE}" = xray ]; then
      systemctl restart janus-engine.service
    else
      curl -fsS -X POST "${clash}/dns/flush"
    fi
    ;;
  dns-stats)
    if [ -f /var/lib/janus/engine/cache.db ]; then
      echo "cache-bytes $(wc -c < /var/lib/janus/engine/cache.db)"
    else
      echo "cache-bytes 0"
    fi
    if [ "${JANUS_ENGINE}" != xray ]; then
      curl -fsS "${clash}/connections" || true
    fi
    ;;
  dns-check) dns_check ;;
  *) usage ;;
esac
