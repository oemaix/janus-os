# docs/14. deploy and fleet name janus-build.
usage() {
  echo "janus [--json] <command> [<args>]" >&2
  echo "Run 'janus --help' for the command list." >&2
  exit 2
}

help() {
  cat <<'EOF'
janus [--json] <command> [<args>]
janus --help
janus --usage

--help and --usage print this text on stdout and exit 0.
--json prints one JSON object on stdout and keeps logs on stderr.
Exit 0 is success. Exit 2 is a usage or validation error. Exit 1 is a runtime failure.

  status
  proxy refresh [name]
  proxy geodata refresh
  proxy select <group> <node>
  proxy groups
  proxy test <group>
  wan restart <name>
  wan show <name>
  lan leases [lan]
  traffic [iface] [--daily|--monthly]
  traffic top
  dns query <name>
  dns flush
  dns stats
  dns check
  logs [unit] [-f]
  fw list
  version [--components]
  reboot
  reset --state --yes
  override show [--secrets]
  override diff
  override set proxy.subscriptions.<name>.url [<url>]
  override set network.lans.<name>.dhcp.staticLeases.<host> --mac <mac> --ip <ip>
  override set network.wifi.<name>.passphrase
  override unset <key>
  secrets install-age-key
  secrets put <name>
  backup
  restore --yes
  audit start|stop|status|export
  web start|stop|status|fingerprint

deploy and fleet are build-host commands. On the board they exit 2 and name janus-build.
EOF
}

json=0
if [ "${1:-}" = "--json" ]; then
  json=1
  shift
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

later() {
  echo "janus $* is not implemented yet. See docs/13-roadmap.md and docs/14-cli.md." >&2
  exit 2
}

proxy_bin() {
  if [ ! -x /etc/janus/bin/janus-proxy ]; then
    echo "janus $1 needs janus.proxy.enable. See docs/13-roadmap.md." >&2
    exit 2
  fi
  /etc/janus/bin/janus-proxy "$@"
}

overrides_file=/var/lib/janus/overrides.json

read_overrides() {
  if [ -f "$overrides_file" ]; then
    cat "$overrides_file"
  else
    echo '{}'
  fi
}

write_overrides() {
  install -d -m 0755 /var/lib/janus
  printf '%s\n' "$1" > "${overrides_file}.new"
  mv "${overrides_file}.new" "$overrides_file"
  chmod 0600 "$overrides_file"
}

restore_overrides() {
  printf '%s\n' "$1" > "$overrides_file"
  chmod 0600 "$overrides_file"
}

merged_overrides() {
  data=$(read_overrides)
  extra='{}'
  for secret in /var/lib/janus/secrets/wifi-*; do
    if [ ! -f "$secret" ]; then
      continue
    fi
    name=${secret##*/}
    name=${name#wifi-}
    key="network.wifi.${name}.passphrase"
    if [ "$1" = 1 ]; then
      value=$(tr -d '\n' < "$secret")
    else
      value='(redacted)'
    fi
    extra=$(printf '%s\n' "$extra" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
  done
  printf '%s\n' "$data" | jq --argjson extra "$extra" --argjson secrets "$1" '
    . * $extra
    | with_entries(
        if $secrets == 0 and (.key | test("^(proxy\\.subscriptions\\.|network\\.wifi\\.)"))
        then .value = "(redacted)"
        else . end)
  '
}

reload_dhcp() {
  if [ ! -x /etc/janus/bin/janus-dhcp-hosts ]; then
    echo "janus: this image has no DHCP host file." >&2
    return 1
  fi
  /etc/janus/bin/janus-dhcp-hosts
  if systemctl is-active --quiet dnsmasq; then
    systemctl reload dnsmasq
  fi
}

lan_exists() {
  [ -f "${JANUS_ETC:-/etc/janus}/lans.json" ] && jq -e --arg n "$1" 'index($n) != null' "${JANUS_ETC:-/etc/janus}/lans.json" >/dev/null
}

wifi_exists() {
  [ -f "${JANUS_ETC:-/etc/janus}/wifi.json" ] && jq -e --arg n "$1" 'has($n)' "${JANUS_ETC:-/etc/janus}/wifi.json" >/dev/null
}

ip_int() {
  case "$1" in
    *.*.*.*) ;;
    *) return 1 ;;
  esac
  o1=${1%%.*}
  rest=${1#*.}
  o2=${rest%%.*}
  rest=${rest#*.}
  o3=${rest%%.*}
  o4=${rest#*.}
  case "$o4" in
    *.*) return 1 ;;
  esac
  for o in "$o1" "$o2" "$o3" "$o4"; do
    case "$o" in
      ""|*[!0-9]*) return 1 ;;
    esac
    if [ "$((10#$o))" -gt 255 ]; then
      return 1
    fi
  done
  printf '%s\n' $(( (10#$o1 << 24) | (10#$o2 << 16) | (10#$o3 << 8) | 10#$o4 ))
}

ip_in_prefix() {
  ip=$(ip_int "$1") || return 1
  base=$(ip_int "$2") || return 1
  prefix=$3
  case "$prefix" in
    ""|*[!0-9]*) return 1 ;;
  esac
  if [ "$prefix" -gt 32 ]; then
    return 1
  fi
  if [ "$prefix" -eq 0 ]; then
    return 0
  fi
  shift_bits=$((32 - prefix))
  mask=$(( ((1 << prefix) - 1) << shift_bits ))
  [ "$(( (ip & mask) == (base & mask) ))" -eq 1 ]
}

wan_show() {
  name=$1
  wan_dir="/run/janus/wan/$name"
  if [ ! -d "$wan_dir" ]; then
    echo "janus: unknown WAN '${name}'." >&2
    if [ -d /run/janus/wan ]; then
      echo "Known WANs:" >&2
      ls /run/janus/wan >&2 || true
    fi
    exit 2
  fi
  if [ -s "$wan_dir/iface" ]; then
    iface=$(head -1 "$wan_dir/iface")
  else
    iface=$(sed -n 's/^Name=//p' \
      "/etc/systemd/network/40-wan-${name}.network" \
      "/etc/systemd/network/40-wan-parent-${name}.network" 2>/dev/null || true)
    iface=${iface%%$'\n'*}
  fi
  if [ -z "$iface" ]; then
    echo "janus: cannot resolve the link for WAN '${name}'." >&2
    exit 1
  fi
  state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || true)
  carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || true)
  v4=$(ip -4 -o addr show dev "$iface" 2>/dev/null || true)
  v6=$(ip -6 -o addr show dev "$iface" 2>/dev/null || true)
  # A point-to-point route has no "via". The third field is then the device.
  gw=$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "via" && $(i + 1) != "") { print $(i + 1); exit }
  }' || true)
  health=$(head -1 "$wan_dir/health" 2>/dev/null || true)
  if [ -z "$health" ]; then
    health=unknown
  fi
  if [ -f "$wan_dir/dns" ]; then
    dns_file=$wan_dir/dns
  else
    dns_file=/dev/null
  fi
  addr_json=$(printf '%s\n%s\n' "$v4" "$v6" | awk 'NF {print $4}' | jq -R . | jq -s .)
  dns_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$dns_file")
  vlt=$(printf '%s\n' "$v4" | awk 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "valid_lft") {print $(i + 1); exit}}')
  lease_json=null
  case "$vlt" in
    *sec)
      secs=${vlt%sec}
      case "$secs" in
        ''|*[!0-9]*) ;;
        *) lease_json=$secs ;;
      esac
      ;;
  esac
  uptime_json=null
  uptime_text=unknown
  if [ -s "$wan_dir/up-since" ]; then
    since=$(head -1 "$wan_dir/up-since")
    now=$(date +%s)
    case "$since" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$now" -ge "$since" ]; then
          uptime_json=$((now - since))
          uptime_text=$(printf '%s\n' "$uptime_json" | awk '{
            s = $1
            if (s < 60) { printf "%ss", s; exit }
            if (s < 3600) { printf "%sm", int(s / 60); exit }
            printf "%sh %sm", int(s / 3600), int((s % 3600) / 60)
          }')
        fi
        ;;
    esac
  fi
  if [ "${json:-0}" = 1 ]; then
    jq -n \
      --arg name "$name" \
      --arg link "$iface" \
      --arg state "$state" \
      --arg carrier "$carrier" \
      --arg gateway "$gw" \
      --arg health "$health" \
      --argjson addresses "$addr_json" \
      --argjson dns "$dns_json" \
      --argjson lease "$lease_json" \
      --argjson uptime "$uptime_json" \
      '{name:$name, link:$link, state:$state, carrier:$carrier, addresses:$addresses, gateway:(if $gateway == "" then null else $gateway end), dns:$dns, leaseSeconds:$lease, uptimeSeconds:$uptime, health:$health}'
    return 0
  fi
  echo "WAN ${name} (link ${iface})"
  echo "Link:     operstate=${state:-unknown} carrier=${carrier:-unknown}"
  echo "Addresses:"
  printf '%s\n%s\n' "$v4" "$v6" | awk 'NF {printf "  %s\n", $4}'
  echo "Gateway:  ${gw:-none}"
  dns_text=$(tr '\n' ' ' < "$dns_file" | sed 's/ *$//')
  echo "DNS:      ${dns_text:-none}"
  case "$vlt" in
    ''|forever) ;;
    *sec)
      secs=${vlt%sec}
      case "$secs" in
        ''|*[!0-9]*) echo "Lease:    ${vlt} remaining" ;;
        *)
          if [ "$secs" -lt 60 ]; then
            echo "Lease:    ${secs}s remaining"
          else
            echo "Lease:    $((secs / 3600))h $(((secs % 3600) / 60))m remaining"
          fi
          ;;
      esac
      ;;
    *) echo "Lease:    ${vlt} remaining" ;;
  esac
  echo "Uptime:   ${uptime_text}"
  echo "Health:   ${health}"
}

case "$cmd" in
  deploy|fleet)
    echo "janus ${cmd} runs on the build host as janus-build. See docs/16-build-host-cli.md." >&2
    exit 2
    ;;
  audit)
    if [ ! -x /etc/janus/bin/janus-audit ]; then
      echo "janus audit is not in this image. Set janus.monitoring.audit.enable and rebuild." >&2
      exit 2
    fi
    /etc/janus/bin/janus-audit "${1:-}"
    ;;
  web)
    if [ ! -x /etc/janus/bin/janus-web ]; then
      echo "janus web is not in this image. Set janus.access.web.enable and rebuild." >&2
      exit 2
    fi
    /etc/janus/bin/janus-web "$@"
    ;;
  proxy)
    sub=${1:-}
    shift || true
    case "$sub" in
      refresh) proxy_bin refresh "${1:-}" ;;
      geodata)
        if [ "${1:-}" != refresh ]; then
          usage
        fi
        proxy_bin geodata-refresh
        ;;
      select) proxy_bin select "${1:-}" "${2:-}" ;;
      groups) proxy_bin groups ;;
      test) proxy_bin test "${1:-}" ;;
      *) usage ;;
    esac
    ;;
  dns)
    sub=${1:-}
    shift || true
    case "$sub" in
      query) proxy_bin dns-query "${1:-}" ;;
      flush) proxy_bin dns-flush ;;
      stats) proxy_bin dns-stats ;;
      check) proxy_bin dns-check ;;
      *) usage ;;
    esac
    ;;
  backup)
    list=$(mktemp)
    {
      [ -f /var/lib/janus/secrets/age.key ] && printf '%s\n' var/lib/janus/secrets/age.key
      for secret in /var/lib/janus/secrets/wifi-*; do
        if [ -f "$secret" ]; then
          printf '%s\n' "var/lib/janus/secrets/${secret##*/}"
        fi
      done
      [ -f /var/lib/janus/overrides.json ] && printf '%s\n' var/lib/janus/overrides.json
      [ -f /var/lib/janus/engine/selection.json ] && printf '%s\n' var/lib/janus/engine/selection.json
      [ -d /var/lib/vnstat ] && printf '%s\n' var/lib/vnstat
    } > "$list"
    if [ ! -s "$list" ]; then
      rm -f "$list"
      echo "janus backup: no age key, overrides, selection, or traffic data." >&2
      exit 1
    fi
    tar -C / -cf - -T "$list"
    rm -f "$list"
    ;;
  restore)
    if [ "${1:-}" != "--yes" ]; then
      echo "janus restore reads an archive on stdin and requires --yes." >&2
      exit 2
    fi
    archive=$(mktemp)
    list=$(mktemp)
    cat > "$archive"
    tar -tf "$archive" > "$list"
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      case "$member" in
        *..* | /*)
          echo "janus restore: rejected ${member}" >&2
          exit 2
          ;;
        var/lib/janus/secrets/age.key | var/lib/janus/secrets/wifi-* | var/lib/janus/overrides.json | var/lib/janus/engine/selection.json)
          ;;
        var/lib/vnstat | var/lib/vnstat/ | var/lib/vnstat/*)
          ;;
        *)
          echo "janus restore: rejected ${member}" >&2
          exit 2
          ;;
      esac
    done < "$list"
    tar -C / -xf "$archive"
    rm -f "$archive" "$list"
    ;;
  status)
    power_bin=""
    if [ -f /etc/janus/power.conf ]; then
      while IFS=$'\t' read -r key val; do
        if [ "$key" = bin ]; then
          power_bin=$val
        fi
      done < /etc/janus/power.conf
    fi
    if [ "$json" = 1 ]; then
      power_json=""
      if [ -n "$power_bin" ]; then
        power_json=$("$power_bin" status /etc/janus/power.conf --json 2>/dev/null || true)
      fi
      if [ -n "$power_json" ]; then
        printf '{"wans":"%s","leases":%s,"var":"%s","power":%s}\n' \
          "$(networkctl list --no-legend 2>/dev/null | wc -l)" \
          "$(wc -l < /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || echo 0)" \
          "$(findmnt -n -b -o SIZE /var 2>/dev/null || echo 0)" \
          "$power_json"
      else
        printf '{"wans":"%s","leases":%s,"var":"%s"}\n' \
          "$(networkctl list --no-legend 2>/dev/null | wc -l)" \
          "$(wc -l < /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || echo 0)" \
          "$(findmnt -n -b -o SIZE /var 2>/dev/null || echo 0)"
      fi
    else
      echo "WANs:"
      networkctl list 2>/dev/null || true
      echo "Leases:"
      wc -l /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || echo 0
      echo "State:"
      findmnt -n /var || true
      if [ -n "$power_bin" ]; then
        "$power_bin" status /etc/janus/power.conf || true
      fi
      if [ -d /var/lib/janus/subscriptions ]; then
        echo "Subscriptions:"
        for stamp in /var/lib/janus/subscriptions/*.stamp; do
          [ -f "$stamp" ] || continue
          echo "$(basename "$stamp" .stamp) $(cat "$stamp")"
        done
        for err in /var/lib/janus/subscriptions/*.error; do
          [ -s "$err" ] || continue
          echo "$(basename "$err" .error) error: $(cat "$err")"
        done
      fi
      if [ -f /var/lib/janus/geodata/refresh.stamp ]; then
        echo "Geo: $(cat /var/lib/janus/geodata/refresh.stamp)"
      fi
      if [ -s /var/lib/janus/geodata/refresh.error ]; then
        echo "Geo error: $(cat /var/lib/janus/geodata/refresh.error)"
      fi
      if systemctl is-active --quiet janus-engine.service 2>/dev/null; then
        echo "Engine: active"
      else
        echo "Engine: inactive"
      fi
    fi
    ;;
  wan)
    sub=${1:-}
    name=${2:-}
    if [ -z "$sub" ] || [ -z "$name" ]; then
      usage
    fi
    case "$sub" in
      restart)
        systemctl restart "janus-pppoe-${name}.service" 2>/dev/null || networkctl renew "$name" || networkctl reconfigure "$name"
        ;;
      show)
        wan_show "$name"
        ;;
      *) usage ;;
    esac
    ;;
  lan)
    if [ "${1:-}" != "leases" ]; then
      usage
    fi
    leases=${JANUS_LEASES:-/var/lib/janus/leases/dnsmasq.leases}
    if [ ! -f "$leases" ]; then
      exit 0
    fi
    lan_name=${2:-}
    if [ -z "$lan_name" ]; then
      cat "$leases"
      exit 0
    fi
    if ! lan_exists "$lan_name"; then
      echo "LAN ${lan_name} is not in this image." >&2
      exit 2
    fi
    nets="${JANUS_ETC:-/etc/janus}/lan-nets.json"
    if [ ! -f "$nets" ]; then
      echo "janus lan leases: this image has no LAN network table." >&2
      exit 1
    fi
    addr=$(jq -r --arg n "$lan_name" '.[$n].address // empty' "$nets")
    prefix=$(jq -r --arg n "$lan_name" '.[$n].prefixLength // empty' "$nets")
    if [ -z "$addr" ] || [ -z "$prefix" ]; then
      echo "LAN ${lan_name} has no IPv4 network in this image." >&2
      exit 2
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      rest=${line#* }
      rest=${rest#* }
      ip=${rest%% *}
      if ip_in_prefix "$ip" "$addr" "$prefix"; then
        printf '%s\n' "$line"
      fi
    done < "$leases"
    ;;
  traffic)
    if [ "${1:-}" = "top" ]; then
      echo "janus traffic top needs janus.monitoring.scope = per-host, which is not collected yet." >&2
      exit 2
    fi
    iface=""
    period=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --daily) period=d ;;
        --monthly) period=m ;;
        *) iface=$1 ;;
      esac
      shift
    done
    if [ -n "$period" ]; then
      vnstat ${iface:+-i "$iface"} "-${period}" || true
    else
      vnstat ${iface:+-i "$iface"} || true
    fi
    ;;
  fw)
    if [ "${1:-}" != "list" ]; then
      usage
    fi
    nft list table inet janus
    ;;
  version)
    if [ "$json" = 1 ]; then
      cat /etc/janus/build.json
    else
      cat /etc/janus/build.json
    fi
    ;;
  logs)
    journalctl -u "${1:-janus-wan-policy.service}" ${2:+"$2"}
    ;;
  reboot)
    systemctl reboot
    ;;
  reset)
    if [ "${1:-}" != "--state" ] || [ "${2:-}" != "--yes" ]; then
      echo "janus reset --state requires --yes." >&2
      exit 2
    fi
    if ! findmnt -n /var >/dev/null 2>&1; then
      echo "janus reset: /var is not a mounted state partition." >&2
      exit 1
    fi
    if ! find /var -mindepth 1 -maxdepth 1 -exec rm -rf {} +; then
      echo "janus reset: could not wipe /var." >&2
      exit 1
    fi
    sync || true
    systemctl reboot
    ;;
  secrets)
    sub=${1:-}
    case "$sub" in
      install-age-key)
        # JANUS_SECRETS_DIR overrides the directory in tests. On the router it is /var/lib/janus/secrets.
        # The previous key stays until stdin contains an AGE-SECRET-KEY-1 line.
        secrets_dir=${JANUS_SECRETS_DIR:-/var/lib/janus/secrets}
        if [ -t 0 ]; then
          echo "Paste the age private key, then press Enter and Ctrl-D." >&2
        fi
        work=$(mktemp)
        cat > "$work"
        if ! grep -q '^AGE-SECRET-KEY-1' "$work"; then
          rm -f "$work"
          echo "Refusing an age key that has no AGE-SECRET-KEY-1 line." >&2
          exit 1
        fi
        install -d -m 0700 "$secrets_dir"
        install -m 0600 "$work" "${secrets_dir}/age.key"
        rm -f "$work"
        if systemctl cat sops-install-secrets.service >/dev/null 2>&1; then
          systemctl restart sops-install-secrets.service
          failed=$(systemctl list-units --failed --no-legend --plain --type=service)
          printf '%s\n' "$failed" | while read -r unit _extra; do
            case "$unit" in
              janus-pppoe-*.service)
                systemctl restart "$unit" || true
                ;;
              janus-wireguard-secret-*.service)
                if systemctl restart "$unit"; then
                  iface=${unit#janus-wireguard-secret-}
                  iface=wg-${iface%.service}
                  if command -v networkctl >/dev/null 2>&1; then
                    # One device. Reload only when that device is not there yet.
                    networkctl reconfigure "$iface" || networkctl reload || true
                  fi
                fi
                ;;
              janus-hostapd-*.service)
                secret_unit=janus-wifi-secret-${unit#janus-hostapd-}
                if systemctl cat "$secret_unit" >/dev/null 2>&1; then
                  systemctl restart "$secret_unit" || true
                fi
                systemctl restart "$unit" || true
                ;;
            esac
          done
          case "$failed" in
            *janus-tailscale-auth.service*|*tailscaled.service*)
              systemctl restart janus-tailscale-auth.service || true
              systemctl restart tailscaled.service || true
              ;;
          esac
          # The listener is janus-web-tls and it stops when janus-web restarts, so the page unit comes last.
          # The passphrase oneshot stays failed when the file was empty, even if the page unit never started.
          case "$failed" in
            *janus-web-secret.service*|*janus-web.service*|*janus-web-tls.service*)
              if systemctl cat janus-web-secret.service >/dev/null 2>&1; then
                systemctl restart janus-web-secret.service || true
              fi
              systemctl restart janus-web.service || true
              systemctl restart janus-web-tls.service || true
              ;;
          esac
        fi
        ;;
      put)
        name=${2:-}
        if [ -z "$name" ]; then
          usage
        fi
        install -d -m 0700 /var/lib/janus/secrets
        cat > "/var/lib/janus/secrets/${name}"
        chmod 0600 "/var/lib/janus/secrets/${name}"
        ;;
      *) usage ;;
    esac
    ;;
  override)
    sub=${1:-}
    shift || true
    show_secrets=0
    if [ "${1:-}" = "--secrets" ]; then
      show_secrets=1
      shift
    fi
    case "$sub" in
      show|diff)
        data=$(merged_overrides "$show_secrets")
        if [ "$json" = 1 ]; then
          printf '%s\n' "$data"
        else
          printf '%s\n' "$data" | jq -r '
            to_entries[]
            | if (.value | type) == "object" then "\(.key) \(.value | tojson)" else "\(.key) \(.value)" end
          '
        fi
        ;;
      set)
        key=${1:-}
        shift || true
        mac=""
        ip=""
        value=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --mac)
              mac=${2:-}
              shift 2
              ;;
            --ip)
              ip=${2:-}
              shift 2
              ;;
            *)
              value=$1
              shift
              ;;
          esac
        done
        case "$key" in
          proxy.subscriptions.*.url)
            name=${key#proxy.subscriptions.}
            name=${name%.url}
            if [ ! -f /etc/janus/subscriptions.json ] || ! jq -e --arg n "$name" 'has($n)' /etc/janus/subscriptions.json >/dev/null; then
              echo "subscription ${name} is not in this image." >&2
              exit 2
            fi
            if [ -z "$value" ]; then
              value=$(cat)
            fi
            if [ -z "$value" ]; then
              usage
            fi
            current=$(read_overrides)
            next=$(printf '%s\n' "$current" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
            write_overrides "$next"
            if ! /etc/janus/bin/janus-proxy refresh "$name"; then
              restore_overrides "$current"
              exit 1
            fi
            ;;
          network.lans.*.dhcp.staticLeases.*)
            rest=${key#network.lans.}
            lan=${rest%%.dhcp.staticLeases.*}
            if ! lan_exists "$lan"; then
              echo "LAN ${lan} is not in this image. A new LAN is a rebuild." >&2
              exit 2
            fi
            if [ -z "$mac" ] || [ -z "$ip" ]; then
              echo "janus override set ${key} needs --mac and --ip." >&2
              exit 2
            fi
            current=$(read_overrides)
            next=$(printf '%s\n' "$current" | jq --arg k "$key" --arg mac "$mac" --arg ip "$ip" '.[$k] = {mac: $mac, ip: $ip}')
            write_overrides "$next"
            if ! reload_dhcp; then
              restore_overrides "$current"
              reload_dhcp || true
              exit 1
            fi
            ;;
          network.wifi.*.passphrase)
            ap=${key#network.wifi.}
            ap=${ap%.passphrase}
            if ! wifi_exists "$ap"; then
              echo "Wi-Fi AP ${ap} is not in this image. A new AP is a rebuild." >&2
              exit 2
            fi
            if [ -z "$value" ]; then
              value=$(cat)
            fi
            if [ -z "$value" ]; then
              usage
            fi
            install -d -m 0700 /var/lib/janus/secrets
            dest="/var/lib/janus/secrets/wifi-${ap}"
            previous=$(mktemp)
            had=0
            if [ -f "$dest" ]; then
              cp "$dest" "$previous"
              had=1
            fi
            umask 077
            printf '%s\n' "$value" > "$dest"
            chmod 0600 "$dest"
            if ! systemctl restart "janus-hostapd-${ap}"; then
              if [ "$had" = 1 ]; then
                cp "$previous" "$dest"
                chmod 0600 "$dest"
              else
                rm -f "$dest"
              fi
              rm -f "$previous"
              exit 1
            fi
            rm -f "$previous"
            ;;
          *)
            echo "janus override set ${key} is not on the allowlist. Rebuild on the build host." >&2
            exit 2
            ;;
        esac
        ;;
      unset)
        key=${1:-}
        if [ -z "$key" ]; then
          usage
        fi
        case "$key" in
          proxy.subscriptions.*.url)
            name=${key#proxy.subscriptions.}
            name=${name%.url}
            current=$(read_overrides)
            next=$(printf '%s\n' "$current" | jq --arg k "$key" 'del(.[$k])')
            write_overrides "$next"
            if [ -x /etc/janus/bin/janus-proxy ]; then
              /etc/janus/bin/janus-proxy refresh "$name" || true
            fi
            ;;
          network.lans.*.dhcp.staticLeases.*)
            current=$(read_overrides)
            next=$(printf '%s\n' "$current" | jq --arg k "$key" 'del(.[$k])')
            write_overrides "$next"
            if ! reload_dhcp; then
              restore_overrides "$current"
              reload_dhcp || true
              exit 1
            fi
            ;;
          network.wifi.*.passphrase)
            ap=${key#network.wifi.}
            ap=${ap%.passphrase}
            rm -f "/var/lib/janus/secrets/wifi-${ap}"
            systemctl restart "janus-hostapd-${ap}" || true
            ;;
          *)
            echo "janus override unset ${key} is not on the allowlist." >&2
            exit 2
            ;;
        esac
        ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
