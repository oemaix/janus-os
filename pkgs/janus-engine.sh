# Runtime helper for the sing-box engine. docs/07, docs/14, ADR-0011, ADR-0016.
# The Nix module sets JANUS_SCRIPT, JANUS_FAIL_MODE, JANUS_INTERCEPT, and JANUS_EGRESS_TABLE.
model=/etc/janus/proxy-model.json
meta=/etc/janus/subscriptions.json
manual=/etc/janus/nodes-manual.json
built=/etc/janus/nodes-built.json
cfg=/var/lib/janus/engine/config.json
sel=/var/lib/janus/engine/selection.json
defs=/etc/janus/group-defaults.json
policy=/etc/janus/dns-policy.json
tags=/etc/janus/geodata-tags.json
sources=/etc/janus/geodata-sources.json
clash=http://127.0.0.1:9090

die() {
  echo "janus: $*" >&2
  exit 1
}

usage() {
  echo "janus-proxy <intercept-up|tun-up|tun-down|render|refresh|geodata-missing|geodata-refresh|groups|select|test|dns-query|dns-flush|dns-stats|dns-check>" >&2
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

intercept_up() {
  if [ "${JANUS_DNS_TPROXY}" = 1 ] || [ "${JANUS_ENGINE}" = xray ]; then
    tproxy_route
  fi
  [ "${JANUS_INTERCEPT}" = 1 ] || return 0
  if [ "${JANUS_ENGINE}" = xray ]; then
    return 0
  fi
  rule_add
  if [ "${JANUS_FAIL_MODE}" = closed ]; then
    blackhole
  fi
}

apply_selection() {
  [ -f "$sel" ] || return 0
  [ -f "$defs" ] || return 0
  while IFS= read -r group; do
    [ -n "$group" ] || continue
    image=$(jq -c --arg g "$group" '.[$g]' "$defs")
    remembered=$(jq -c --arg g "$group" '.[$g].default' "$sel")
    node=$(jq -r --arg g "$group" '.[$g].node // empty' "$sel")
    if [ "$image" != "$remembered" ] || [ -z "$node" ]; then
      continue
    fi
    curl -fsS -X PUT -H 'content-type: application/json' \
      -d "$(jq -nc --arg n "$node" '{name:$n}')" \
      "${clash}/proxies/${group}" || true
  done < <(jq -r 'keys[]' "$sel")
}

xray_pin_balancers() {
  [ "${JANUS_ENGINE}" = xray ] || return 0
  [ -f "$sel" ] || return 0
  [ -f "$model" ] || return 0
  i=0
  while [ "$i" -lt 20 ]; do
    if xray api bi -s 127.0.0.1:8080 >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
    i=$((i + 1))
  done
  while IFS= read -r group; do
    [ -n "$group" ] || continue
    strategy=$(jq -r --arg g "$group" '.groups[$g].strategy // "url-test"' "$model")
    if [ "$strategy" = manual ]; then
      continue
    fi
    image=$(jq -c --arg g "$group" '.[$g]' "$defs")
    remembered=$(jq -c --arg g "$group" '.[$g].default' "$sel")
    node=$(jq -r --arg g "$group" '.[$g].node // empty' "$sel")
    if [ "$image" != "$remembered" ] || [ -z "$node" ]; then
      continue
    fi
    case "$node" in
      node:*) node=${node#node:} ;;
    esac
    xray api bo -s 127.0.0.1:8080 -b "$group" "$node" || true
  done < <(jq -r 'keys[]' "$sel")
}

tun_up() {
  if [ "${JANUS_ENGINE}" = xray ]; then
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
  if compgen -G '/var/lib/janus/subscriptions/*.json' >/dev/null; then
    jq -s 'add' /var/lib/janus/subscriptions/*.json > "$runtime"
  else
    echo '[]' > "$runtime"
  fi
  jq -s '
    (.[0] + .[1]) as $base
    | (.[2] | map(select(.name | contains("/")) | .name | split("/")[0]) | unique) as $replaced
    | ($base | map(select(
        ((.name | contains("/")) | not)
        or (((.name | split("/")[0]) as $p | $replaced | index($p)) | not)
      ))) + .[2]
  ' "$manual" "$built" "$runtime" > "$out"
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
  if compgen -G '/run/janus/wan/*/dns' >/dev/null; then
    grep -h . /run/janus/wan/*/dns | awk 'NF && !seen[$0]++' > "$ips" || true
  else
    : > "$ips"
  fi
  if [ ! -s "$ips" ]; then
    rm -f "$ips"
    return 0
  fi
  if [ "$mode" = domestic-only ]; then
    jq --rawfile ips "$ips" '
      .dns.domestic.resolvers += ([$ips | split("\n")[] | select(length > 0) | "udp://" + .] | unique)
    ' "$src" > "$dst"
  elif [ "$mode" = fallback-only ]; then
    jq --rawfile ips "$ips" '
      .dns.remote.resolvers += ([$ips | split("\n")[] | select(length > 0) | "udp://" + .] | unique)
    ' "$src" > "$dst"
  fi
  rm -f "$ips"
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
    pw=$(cat "$path")
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
  if [ "${JANUS_ENGINE}" != xray ] || [ ! -f "$sel" ]; then
    cp "$src" "$dst"
    return 0
  fi
  jq --slurpfile sel "$sel" '
    reduce ($sel[0] | to_entries[]) as $e (.;
      if ((.groups[$e.key].strategy // "url-test") == "manual")
         and (.groups[$e.key].default == $e.value.default)
      then .groups[$e.key].default = $e.value.node
      else . end)
  ' "$src" > "$dst"
}

render_config() {
  ensure_dirs
  nodes=$(merge_nodes)
  work=$(mktemp)
  selected=$(mktemp)
  out=$(mktemp)
  carrier_model "$model" "$work"
  apply_saved_selection "$work" "$selected"
  janet "$JANUS_SCRIPT" render --model "$selected" --nodes "$nodes" --rule-set local --engine "${JANUS_ENGINE}" --output "$out"
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
  chmod 0600 "$cfg"
  rm -f "$nodes" "$work" "$selected"
}

# A function called from `if` ignores set -e, and so does a subshell it starts.
# A new bash does not, and die() exits only that bash, so the caller can record it.
render_or_fail() {
  bash "$0" render-internal
}

geo_base() {
  tag=$1
  if printf '%s' "$tag" | grep -q '^geoip-'; then
    jq -r '.geoip' "$sources"
  else
    jq -r '.geosite' "$sources"
  fi
}

download_tag() {
  tag=$1
  dest="/var/lib/janus/geodata/${tag}.srs"
  base=$(geo_base "$tag")
  curl_args=(-fsSL --retry 2 --max-time 60 -o "${dest}.partial")
  if [ -d /sys/class/net/tun0 ]; then
    curl_args+=(--socks5-hostname 127.0.0.1:2080)
  fi
  if ! curl "${curl_args[@]}" -- "${base}/${tag}.srs"; then
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
  if [ -f /var/lib/janus/overrides.json ]; then
    url=$(jq -r --arg k "$key" '.[$k] // empty' /var/lib/janus/overrides.json)
  fi
  if [ -z "$url" ]; then
    secret=$(jq -r --arg n "$name" '.[$n].urlSecret // empty' "$meta")
    if [ -n "$secret" ] && [ -f "/run/secrets/${secret}" ]; then
      first=$(head -n 1 "/run/secrets/${secret}" || true)
      case "$first" in
        age-encryption.org*)
          url=$(age -d -i /var/lib/janus/secrets/age.key "/run/secrets/${secret}")
          ;;
        *)
          url=$(cat "/run/secrets/${secret}")
          ;;
      esac
    elif [ -f "/var/lib/janus/subscription-urls/${name}" ]; then
      url=$(cat "/var/lib/janus/subscription-urls/${name}")
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

write_selection() {
  group=$1
  node=$2
  ensure_dirs
  image=$(jq -c --arg g "$group" '.[$g]' "$defs")
  if [ -f "$sel" ]; then
    current=$sel
  else
    current=$(mktemp)
    echo '{}' > "$current"
  fi
  tmp=$(mktemp)
  jq --arg g "$group" --arg n "$node" --argjson d "$image" '.[$g] = {node:$n, default:$d}' "$current" > "$tmp"
  mv "$tmp" "$sel"
  chmod 0600 "$sel"
}

report() {
  printf '%s %s\n' "$1" "$2"
  if [ "$1" = fail ]; then
    check_fail=1
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
  foreign=$(resolve_name example.com A)
  if [ -z "$foreign" ]; then
    report fail "foreign name example.com was not answered"
  elif printf '%s' "$foreign" | grep -q '198\.18\.'; then
    report pass "foreign name example.com answered from the fake-IP range"
  else
    bogus=0
    while IFS= read -r bad; do
      [ -n "$bad" ] || continue
      if printf '%s' "$foreign" | grep -q "$bad"; then
        bogus=1
      fi
    done < <(jq -r '.bogusAnswers[]?' "$policy")
    if [ "$bogus" = 1 ]; then
      report fail "foreign name example.com matched a bogus answer"
    else
      report pass "foreign name example.com was not a listed bogus answer"
    fi
  fi
  domestic=$(resolve_name www.baidu.com A)
  if [ -z "$domestic" ]; then
    report fail "domestic name www.baidu.com was not answered"
  elif printf '%s' "$domestic" | grep -q '198\.18\.'; then
    report fail "domestic name www.baidu.com was answered with a fake-IP"
  else
    report pass "domestic name www.baidu.com was not a fake-IP"
  fi
  if [ "$(jq -r '.ipv6Answers' "$policy")" = strip-all ]; then
    aaaa=$(resolve_name example.com AAAA)
    if printf '%s' "$aaaa" | grep -Eq ':[0-9a-fA-F]'; then
      report fail "AAAA for example.com was present while ipv6Answers is strip-all"
    else
      report pass "AAAA for example.com is stripped"
    fi
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
  groups)
    if [ "${JANUS_ENGINE}" = xray ]; then
      jq -r '.groups | to_entries[] | "\(.key) \(.value.strategy // "url-test")"' "$model"
      xray api bi -s 127.0.0.1:8080 || true
    else
      curl -fsS "${clash}/proxies"
    fi
    ;;
  select)
    group=${1:-}
    node=${2:-}
    if [ -z "$group" ] || [ -z "$node" ]; then
      usage
    fi
    if [ "${JANUS_ENGINE}" = xray ]; then
      previous=$(mktemp)
      if [ -f "$sel" ]; then
        cp "$sel" "$previous"
      else
        echo '{}' > "$previous"
      fi
      write_selection "$group" "$node"
      if ! render_or_fail; then
        cp "$previous" "$sel"
        chmod 0600 "$sel"
        rm -f "$previous"
        exit 1
      fi
      rm -f "$previous"
      systemctl restart janus-engine.service
      xray_pin_balancers
    else
      curl -fsS -X PUT -H 'content-type: application/json' \
        -d "$(jq -nc --arg n "$node" '{name:$n}')" \
        "${clash}/proxies/${group}"
      write_selection "$group" "$node"
    fi
    ;;
  test)
    group=${1:-}
    if [ -z "$group" ]; then
      usage
    fi
    if [ "${JANUS_ENGINE}" = xray ]; then
      xray api bi -s 127.0.0.1:8080 "$group"
    else
      url=$(jq -r --arg g "$group" '.groups[$g].test.url // "https://www.gstatic.com/generate_204"' "$model")
      curl -fsS -G "${clash}/proxies/${group}/delay" \
        --data-urlencode "url=${url}" \
        --data-urlencode "timeout=5000"
    fi
    ;;
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
