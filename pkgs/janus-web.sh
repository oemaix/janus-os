# Maintenance page control. docs/20, docs/14 §7.
set -eu

json=${JANUS_WEB_JSON:-/etc/janus/web.json}
systemctl_bin=${JANUS_SYSTEMCTL:-systemctl}

need_image() {
  if [ ! -f "$json" ] || [ "$(jq -r '.enable // false' "$json")" != true ]; then
    echo "janus web is not in this image. Set janus.access.web.enable and rebuild." >&2
    exit 2
  fi
}

field() {
  jq -r "$1" "$json"
}

cert_path() {
  field '.cert // "/var/lib/janus/web/cert.pem"'
}

key_path() {
  field '.key // "/var/lib/janus/web/key.pem"'
}

paused_path() {
  field '.paused // "/var/lib/janus/web/paused"'
}

pass_path() {
  field '.passphraseFile // empty'
}

fingerprint_of() {
  cert=$1
  if [ ! -s "$cert" ]; then
    return 1
  fi
  line=$(openssl x509 -in "$cert" -noout -fingerprint -sha256)
  printf '%s\n' "${line#*=}"
}

cmd_cert() {
  need_image
  cert=$(cert_path)
  key=$(key_path)
  if [ -s "$cert" ] && [ -s "$key" ]; then
    exit 0
  fi
  install -d -m 0755 "$(dirname "$(dirname "$cert")")"
  install -d -m 0751 "$(dirname "$cert")"
  host=$(field '.hostname')
  san=$(field '.san | join(",")')
  umask 077
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$key" -out "$cert" \
    -subj "/CN=${host}" \
    -addext "subjectAltName=${san}"
  chmod 0640 "$key"
  chmod 0644 "$cert"
  chown root:janus-web-tls "$key" "$cert" 2>/dev/null || true
}

cmd_start() {
  need_image
  pass=$(pass_path)
  if [ -z "$pass" ] || [ ! -s "$pass" ]; then
    echo "janus web passphrase file is missing or empty." >&2
    exit 1
  fi
  paused=$(paused_path)
  rm -f "$paused"
  "$systemctl_bin" start janus-web-cert.service
  "$systemctl_bin" start janus-web.service
  "$systemctl_bin" start janus-web-tls.service
}

cmd_ready() {
  need_image
  if [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -s "${CREDENTIALS_DIRECTORY}/passphrase" ]; then
    exit 0
  fi
  pass=$(pass_path)
  if [ -n "$pass" ] && [ -s "$pass" ]; then
    exit 0
  fi
  echo "janus web passphrase file is missing or empty." >&2
  exit 1
}

cmd_stop() {
  need_image
  paused=$(paused_path)
  install -d -m 0751 "$(dirname "$paused")"
  touch "$paused"
  "$systemctl_bin" stop janus-web-tls.service
  "$systemctl_bin" stop janus-web.service
}

cmd_status() {
  need_image
  if "$systemctl_bin" is-active --quiet janus-web-tls.service; then
    echo "listener: on"
  else
    echo "listener: off"
  fi
  echo "port: $(field '.port')"
  echo "zones: $(field '.zones | join(" ")')"
  if fp=$(fingerprint_of "$(cert_path)"); then
    echo "fingerprint: ${fp}"
  else
    echo "fingerprint:"
  fi
}

cmd_fingerprint() {
  need_image
  if ! fp=$(fingerprint_of "$(cert_path)"); then
    echo "janus web certificate is not on this router yet." >&2
    exit 1
  fi
  printf '%s\n' "$fp"
}

cmd_serve() {
  need_image
  if [ -z "${JANUS_WEB_JANET:-}" ]; then
    echo "janus-web: JANUS_WEB_JANET is unset" >&2
    exit 1
  fi
  # Same PID as this shell, so Type=notify can keep NotifyAccess=main.
  # Janet listens, then writes READY=1 itself.
  exec janet "$JANUS_WEB_JANET" serve
}

cmd=${1:-}
case "$cmd" in
  cert) cmd_cert ;;
  ready) cmd_ready ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  fingerprint) cmd_fingerprint ;;
  serve) cmd_serve ;;
  *)
    echo "janus-web cert|ready|start|stop|status|fingerprint|serve" >&2
    exit 2
    ;;
esac
