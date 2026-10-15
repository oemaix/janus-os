# IPFIX or NetFlow v9 from each named interface. FR-MON-003.
# One softflowd stays in the foreground per interface (-d). The ring is -m.
if [ "$#" -eq 0 ]; then
  echo "janus-flow-export: no interfaces" >&2
  exit 1
fi
: "${JANUS_COLLECTOR:?}"
: "${JANUS_FLOW_VERSION:?}"
max=${JANUS_FLOW_MAX:-8192}
pids=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
stop() {
  if [ "${#pids[@]}" -gt 0 ]; then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
}
trap stop EXIT
for iface in "$@"; do
  softflowd -d -i "$iface" -n "$JANUS_COLLECTOR" -v "$JANUS_FLOW_VERSION" -m "$max" &
  pids+=("$!")
done
wait -n
exit 1
