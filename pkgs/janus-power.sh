# SPDX-License-Identifier: Apache-2.0
# Cell cutoff. docs/10 §4.5. A missing sensor, a charge, or a current
# within 5 mA of zero never powers the router off.
set -eu

conf=${2:-/etc/janus/power.conf}
sign=-
armed=0
warn=3.60
shutdown_v=3.50
critical_v=3.30
boot_mv=3550
sample_mv=""
sample_ma=""

mv_of() {
  awk -v v="$1" 'BEGIN { printf "%d", (v * 1000) + 0.5 }'
}

direction_of() {
  local which=$1 ma=$2
  if [ "$which" = negative ]; then
    if [ "$ma" -lt -5 ]; then
      printf '%s\n' discharge
    elif [ "$ma" -gt 5 ]; then
      printf '%s\n' charge
    else
      printf '%s\n' idle
    fi
  elif [ "$which" = positive ]; then
    if [ "$ma" -gt 5 ]; then
      printf '%s\n' discharge
    elif [ "$ma" -lt -5 ]; then
      printf '%s\n' charge
    else
      printf '%s\n' idle
    fi
  else
    printf '%s\n' idle
  fi
}

load_conf() {
  [ -r "$conf" ] || return 0
  while IFS=$'\t' read -r key val; do
    case "$key" in
      sign) sign=$val ;;
      armed) armed=$val ;;
      warn) warn=$val ;;
      shutdown) shutdown_v=$val ;;
      critical) critical_v=$val ;;
    esac
  done < "$conf"
}

read_hwmon() {
  local root=${JANUS_POWER_SYS:-/sys/class/hwmon} hw name
  sample_mv=""
  sample_ma=""
  for hw in "$root"/hwmon*; do
    [ -r "$hw/name" ] || continue
    name=$(cat "$hw/name")
    case "$name" in
      ina219*)
        sample_mv=$(cat "$hw/in1_input" 2>/dev/null || true)
        sample_ma=$(cat "$hw/curr1_input" 2>/dev/null || true)
        ;;
    esac
  done
  case "$sample_mv" in
    "" | *[!0-9-]*) return 1 ;;
  esac
  case "$sample_ma" in
    "" | *[!0-9-]*) return 1 ;;
  esac
  return 0
}

now_s() {
  if [ -n "${JANUS_POWER_NOW:-}" ]; then
    # The test harness replaces the clock.
    # shellcheck disable=SC2086
    $JANUS_POWER_NOW
  else
    date +%s
  fi
}

pause() {
  if [ -n "${JANUS_POWER_PAUSE:-}" ]; then
    # The test harness replaces the one-second wait.
    # shellcheck disable=SC2086
    $JANUS_POWER_PAUSE
  else
    sleep 1
  fi
}

power_off() {
  echo "janus-power: $1" >&2
  if [ -n "${JANUS_POWER_OFF:-}" ]; then
    # The test harness replaces the poweroff command.
    # shellcheck disable=SC2086
    $JANUS_POWER_OFF
  else
    systemctl --no-block poweroff
  fi
}

# A queued poweroff must not finish this oneshot. Before=network-pre
# stays open while the process is still starting.
hold_boot() {
  trap 'exit 0' TERM INT
  while true; do
    sleep 3600 || true
  done
}

require_sample() {
  : "${VOLTS:?}" "${MA:?}" "${SIGN:?}" "${ARMED:?}"
}

cmd=${1:-}
case "$cmd" in
  step)
    require_sample
    : "${WARN:?}" "${SHUTDOWN:?}" "${CRITICAL:?}" "${LOW_MS:?}" "${CRITICAL_MS:?}" "${DT_MS:?}"
    direction=$(direction_of "$SIGN" "$MA")
    sample=$(mv_of "$VOLTS")
    warn_mv=$(mv_of "$WARN")
    shut_mv=$(mv_of "$SHUTDOWN")
    crit_mv=$(mv_of "$CRITICAL")
    low=$LOW_MS
    crit=$CRITICAL_MS
    warning=0
    action=none
    if [ "$direction" = discharge ]; then
      if [ "$sample" -le "$warn_mv" ]; then
        warning=1
      fi
      if [ "$sample" -le "$shut_mv" ]; then
        low=$((low + DT_MS))
      else
        low=0
      fi
      if [ "$sample" -le "$crit_mv" ]; then
        crit=$((crit + DT_MS))
      else
        crit=0
      fi
      if [ "$ARMED" = 1 ] && { [ "$crit" -ge 10000 ] || [ "$low" -ge 60000 ]; }; then
        action=poweroff
      fi
    else
      low=0
      crit=0
    fi
    printf 'action\t%s\nlow-ms\t%s\ncritical-ms\t%s\nwarning\t%s\ndirection\t%s\n' \
      "$action" "$low" "$crit" "$warning" "$direction"
    ;;
  boot-step)
    require_sample
    direction=$(direction_of "$SIGN" "$MA")
    sample=$(mv_of "$VOLTS")
    action=none
    if [ "$ARMED" = 1 ] && [ "$direction" = discharge ] && [ "$sample" -lt "$boot_mv" ]; then
      action=poweroff
    fi
    printf 'action\t%s\ndirection\t%s\n' "$action" "$direction"
    ;;
  status)
    load_conf
    if read_hwmon; then
      direction=$(direction_of "$sign" "$sample_ma")
      volts=$(awk -v mv="$sample_mv" 'BEGIN { printf "%.2f", mv / 1000 }')
      if [ "$armed" = 1 ]; then
        shut=armed
      else
        shut=off
      fi
      if [ "${3:-}" = --json ]; then
        printf '{"voltage":"%s","current_mA":"%s","direction":"%s","shutdown":"%s"}\n' \
          "$volts" "$sample_ma" "$direction" "$shut"
      else
        printf 'Power: %s V, %s mA, %s, shutdown %s\n' "$volts" "$sample_ma" "$direction" "$shut"
      fi
    else
      if [ "${3:-}" = --json ]; then
        if [ "$armed" = 1 ]; then
          shut=armed
        else
          shut=off
        fi
        printf '{"voltage":null,"current_mA":null,"direction":null,"shutdown":"%s"}\n' "$shut"
      else
        echo "Power: no reading"
      fi
    fi
    ;;
  guard)
    load_conf
    if [ "$armed" != 1 ]; then
      exit 0
    fi
    found=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if read_hwmon; then
        found=1
        break
      fi
      pause
    done
    if [ "$found" != 1 ]; then
      echo "janus-power: no INA219 reading; leaving the router up" >&2
      exit 0
    fi
    direction=$(direction_of "$sign" "$sample_ma")
    if [ "$direction" = discharge ] && [ "$sample_mv" -lt "$boot_mv" ]; then
      volts=$(awk -v mv="$sample_mv" 'BEGIN { printf "%.2f", mv / 1000 }')
      power_off "cell ${volts} V is already discharging below 3.55 V"
      hold_boot
    fi
    ;;
  watch)
    load_conf
    low=0
    crit=0
    prev=""
    last_warn=0
    warn_mv=$(mv_of "$warn")
    shut_mv=$(mv_of "$shutdown_v")
    crit_mv=$(mv_of "$critical_v")
    while true; do
      now=$(now_s)
      if [ -n "$prev" ]; then
        dt=$(((now - prev) * 1000))
        if [ "$dt" -lt 1 ] || [ "$dt" -gt 5000 ]; then
          dt=1000
        fi
      else
        dt=0
      fi
      prev=$now
      if ! read_hwmon; then
        low=0
        crit=0
        pause
        continue
      fi
      direction=$(direction_of "$sign" "$sample_ma")
      if [ "$direction" != discharge ]; then
        low=0
        crit=0
        pause
        continue
      fi
      if [ "$sample_mv" -le "$warn_mv" ]; then
        if [ $((now - last_warn)) -ge 60 ]; then
          volts=$(awk -v mv="$sample_mv" 'BEGIN { printf "%.2f", mv / 1000 }')
          echo "janus-power: cell ${volts} V while discharging" >&2
          last_warn=$now
        fi
      fi
      if [ "$sample_mv" -le "$shut_mv" ]; then
        low=$((low + dt))
      else
        low=0
      fi
      if [ "$sample_mv" -le "$crit_mv" ]; then
        crit=$((crit + dt))
      else
        crit=0
      fi
      if [ "$armed" = 1 ] && { [ "$crit" -ge 10000 ] || [ "$low" -ge 60000 ]; }; then
        volts=$(awk -v mv="$sample_mv" 'BEGIN { printf "%.2f", mv / 1000 }')
        if [ "$crit" -ge 10000 ]; then
          power_off "cell ${volts} V stayed at or below ${critical_v} V for 10 s while discharging"
        else
          power_off "cell ${volts} V stayed at or below ${shutdown_v} V for 60 s while discharging"
        fi
        exit 0
      fi
      pause
    done
    ;;
  *)
    echo "janus-power {step|boot-step|status|guard|watch}" >&2
    exit 2
    ;;
esac
