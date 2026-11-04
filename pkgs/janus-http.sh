# Shared HTTP listener. docs/08 §1c, docs/14 §8.
set -eu

json=${JANUS_HTTP_JSON:-/etc/janus/http.json}
systemctl_bin=${JANUS_SYSTEMCTL:-systemctl}

need_image() {
  if [ ! -f "$json" ] || [ "$(jq -r '.enable // false' "$json")" != true ]; then
    echo "janus http is not in this image. Set janus.http.enable and rebuild." >&2
    exit 2
  fi
}

field() {
  jq -r "$1" "$json"
}

cert_path() {
  field '.cert // "/var/lib/janus/http/cert.pem"'
}

key_path() {
  field '.key // "/var/lib/janus/http/key.pem"'
}

paused_path() {
  field '.paused // "/var/lib/janus/http/paused"'
}

token_path() {
  field '.tokenFile // empty'
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
  chown root:janus-http-tls "$key" "$cert" 2>/dev/null || true
}

ensure_token() {
  token=$1
  if "$systemctl_bin" cat janus-http-secret.service >/dev/null 2>&1; then
    if ! "$systemctl_bin" start janus-http-secret.service; then
      echo "janus http could not install the token secret." >&2
      exit 1
    fi
    return 0
  fi
  case "$token" in
    /run/secrets/*)
      if "$systemctl_bin" cat sops-install-secrets.service >/dev/null 2>&1; then
        if ! "$systemctl_bin" start sops-install-secrets.service; then
          echo "janus http could not install the token secret." >&2
          exit 1
        fi
      fi
      ;;
  esac
}

cmd_start() {
  need_image
  token=$(token_path)
  ensure_token "$token"
  if [ -z "$token" ] || [ ! -s "$token" ]; then
    echo "janus http token file is missing or empty." >&2
    exit 1
  fi
  paused=$(paused_path)
  rm -f "$paused"
  "$systemctl_bin" start janus-http-cert.service
  "$systemctl_bin" start janus-http.service
  "$systemctl_bin" start janus-http-tls.service
}

cmd_ready() {
  need_image
  if [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -s "${CREDENTIALS_DIRECTORY}/token" ]; then
    exit 0
  fi
  token=$(token_path)
  if [ -n "$token" ] && [ -s "$token" ]; then
    exit 0
  fi
  echo "janus http token file is missing or empty." >&2
  exit 1
}

cmd_stop() {
  need_image
  paused=$(paused_path)
  install -d -m 0751 "$(dirname "$paused")"
  touch "$paused"
  "$systemctl_bin" stop janus-http-tls.service
  "$systemctl_bin" stop janus-http.service
}

cmd_status() {
  need_image
  if "$systemctl_bin" is-active --quiet janus-http-tls.service; then
    echo "listener: on"
  else
    echo "listener: off"
  fi
  echo "port: $(field '.port')"
  echo "zones: $(field '.zones | join(" ")')"
  echo "recognition: $(field '.asr')"
  echo "synthesis: $(field '.tts')"
  if fp=$(fingerprint_of "$(cert_path)"); then
    echo "fingerprint: ${fp}"
  else
    echo "fingerprint:"
  fi
}

cmd_fingerprint() {
  need_image
  if ! fp=$(fingerprint_of "$(cert_path)"); then
    echo "janus http certificate is not on this router yet." >&2
    exit 1
  fi
  printf '%s\n' "$fp"
}

cmd_serve() {
  need_image
  if [ -z "${JANUS_HTTP_JANET:-}" ]; then
    echo "janus-http: JANUS_HTTP_JANET is unset" >&2
    exit 1
  fi
  # Janet does not parse the document. These fields are not the token.
  export JANUS_HTTP_ASR=$(field '.asr')
  export JANUS_HTTP_TTS=$(field '.tts')
  export JANUS_HTTP_SOCKET=$(field '.socket')
  exec janet "$JANUS_HTTP_JANET" serve
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
    echo "janus-http cert|ready|start|stop|status|fingerprint|serve" >&2
    exit 2
    ;;
esac
