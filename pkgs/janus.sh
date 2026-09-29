# docs/14. Proxy, DNS policy, and fleet commands are later phases.
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

case "$cmd" in
  deploy|fleet|proxy|dns|audit)
    later "$cmd${1:+ $1}"
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
    case "$sub" in
      show|diff)
        if [ -f /var/lib/janus/overrides.json ]; then
          cat /var/lib/janus/overrides.json
        else
          echo '{}'
        fi
        ;;
      set|unset)
        later "override $sub"
        ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
