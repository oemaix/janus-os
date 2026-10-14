# docs/14. deploy and fleet name janus-build.
usage() {
  echo "janus [--json] <command> [<args>]" >&2
  echo "See docs/14-cli.md." >&2
  exit 2
}

json=0
if [ "${1:-}" = "--json" ]; then
  json=1
  shift
fi
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
  install -d -m 0700 /var/lib/janus
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
  [ -f /etc/janus/lans.json ] && jq -e --arg n "$1" 'index($n) != null' /etc/janus/lans.json >/dev/null
}

wifi_exists() {
  [ -f /etc/janus/wifi.json ] && jq -e --arg n "$1" 'has($n)' /etc/janus/wifi.json >/dev/null
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
        if [ "$json" = 1 ]; then
          printf '{"name":"%s","dns":"%s"}\n' "$name" "$(tr '\n' ' ' < "/run/janus/wan/${name}/dns" 2>/dev/null || true)"
        else
          ip -4 addr show
          echo "DNS:"
          cat "/run/janus/wan/${name}/dns" 2>/dev/null || true
        fi
        ;;
      *) usage ;;
    esac
    ;;
  lan)
    if [ "${1:-}" != "leases" ]; then
      usage
    fi
    cat /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || true
    ;;
  traffic)
    if [ "${1:-}" = "top" ]; then
      echo "janus traffic top needs janus.monitoring.scope = per-host, which is not collected yet." >&2
      exit 2
    fi
    vnstat ${1:+-i "$1"} || true
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
    find /var -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
    sync || true
    systemctl reboot
    ;;
  secrets)
    sub=${1:-}
    case "$sub" in
      install-age-key)
        install -d -m 0700 /var/lib/janus/secrets
        cat > /var/lib/janus/secrets/age.key
        chmod 0600 /var/lib/janus/secrets/age.key
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
