# docs/14. deploy, fleet, and audit stay later phases.
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

case "$cmd" in
  deploy|fleet|audit)
    later "$cmd${1:+ $1}"
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
        var/lib/janus/secrets/age.key | var/lib/janus/overrides.json | var/lib/janus/engine/selection.json)
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
    if [ "$json" = 1 ]; then
      printf '{"wans":"%s","leases":%s,"var":"%s"}\n' \
        "$(networkctl list --no-legend 2>/dev/null | wc -l)" \
        "$(wc -l < /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || echo 0)" \
        "$(findmnt -n -b -o SIZE /var 2>/dev/null || echo 0)"
    else
      echo "WANs:"
      networkctl list 2>/dev/null || true
      echo "Leases:"
      wc -l /var/lib/janus/leases/dnsmasq.leases 2>/dev/null || echo 0
      echo "State:"
      findmnt -n /var || true
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
    later "reset"
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
        data=$(read_overrides)
        if [ "$json" = 1 ] && [ "$show_secrets" = 1 ]; then
          printf '%s\n' "$data"
        elif [ "$json" = 1 ]; then
          printf '%s\n' "$data" | jq 'with_entries(.value = "(redacted)")'
        else
          printf '%s\n' "$data" | jq -r --argjson secrets "$show_secrets" '
            to_entries[]
            | if $secrets == 1 then "\(.key) \(.value)" else "\(.key) (redacted)" end
          '
        fi
        ;;
      set)
        key=${1:-}
        value=${2:-}
        case "$key" in
          proxy.subscriptions.*.url) ;;
          network.lans.*.dhcp.staticLeases.*|network.wifi.*.passphrase)
            echo "janus override set ${key} is phase 3. See docs/13-roadmap.md." >&2
            exit 2
            ;;
          *)
            echo "janus override set ${key} is not on the allowlist. Rebuild on the build host." >&2
            exit 2
            ;;
        esac
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
        install -d -m 0700 /var/lib/janus
        current=$(read_overrides)
        printf '%s\n' "$current" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' > "${overrides_file}.new"
        mv "${overrides_file}.new" "$overrides_file"
        chmod 0600 "$overrides_file"
        if ! /etc/janus/bin/janus-proxy refresh "$name"; then
          printf '%s\n' "$current" > "$overrides_file"
          chmod 0600 "$overrides_file"
          exit 1
        fi
        ;;
      unset)
        key=${1:-}
        if [ -z "$key" ]; then
          usage
        fi
        case "$key" in
          proxy.subscriptions.*.url) ;;
          *)
            echo "janus override unset ${key} is not a phase 2 subscription url." >&2
            exit 2
            ;;
        esac
        name=${key#proxy.subscriptions.}
        name=${name%.url}
        current=$(read_overrides)
        printf '%s\n' "$current" | jq --arg k "$key" 'del(.[$k])' > "${overrides_file}.new"
        mv "${overrides_file}.new" "$overrides_file"
        chmod 0600 "$overrides_file"
        if [ -x /etc/janus/bin/janus-proxy ]; then
          /etc/janus/bin/janus-proxy refresh "$name" || true
        fi
        ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
