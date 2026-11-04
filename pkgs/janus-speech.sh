# Local speech commands. docs/14 §8. No bearer token.
set -eu

json=${JANUS_SPEECH_JSON:-/etc/janus/speech.json}
run=${JANUS_SPEECH_RUN:-/etc/janus/bin/janus-speech-run}

need() {
  if [ ! -x "$run" ] || [ ! -f "$json" ]; then
    echo "janus edge speech is not in this image. Set janus.edge.api.enable and janus.edge.speech.asr.enable or janus.edge.speech.tts.enable, then rebuild." >&2
    exit 2
  fi
}

# `if ! cmd; then exit $?; fi` exits 0. `!` inverts the status. T-0022.
run_status() {
  set +e
  "$run" "$@"
  rc=$?
  set -e
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
}

field() {
  jq -r "$1" "$json"
}

cmd_asr() {
  need
  if [ "$(field '.asr')" != true ]; then
    echo "janus edge speech asr is not in this image. Set janus.edge.speech.asr.enable and rebuild." >&2
    exit 2
  fi
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat > "$work/in"
  # WAV keeps the header rate. PCM is signed 16-bit, 16 kHz, mono. *14* §8.
  sig=$(dd if="$work/in" bs=4 count=1 2>/dev/null || true)
  if [ "$sig" = RIFF ]; then
    run_status recognize --body "$work/in" --ctype audio/wav --out "$work/out" --meta "$work/meta"
  else
    run_status recognize --body "$work/in" --ctype audio/raw --rate 16000 --channels 1 --out "$work/out" --meta "$work/meta"
  fi
  cat "$work/out"
}

cmd_tts() {
  need
  if [ "$(field '.tts')" != true ]; then
    echo "janus edge speech tts is not in this image. Set janus.edge.speech.tts.enable and rebuild." >&2
    exit 2
  fi
  play=0
  if [ "${1:-}" = --play ]; then
    play=1
    shift
  fi
  text=${1:-}
  if [ -z "$text" ]; then
    echo "janus edge speech tts needs the text." >&2
    exit 2
  fi
  output=network
  if [ "$play" = 1 ]; then
    device=$(field '.playback.output')
    if [ -z "$device" ] || [ "$device" = null ]; then
      echo "janus edge speech tts --play needs janus.audio.playback. Set it and rebuild." >&2
      exit 2
    fi
    output=playback
  fi
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  jq -n --arg text "$text" --arg output "$output" '{text:$text,output:$output}' > "$work/in"
  run_status synthesize --body "$work/in" --ctype application/json --out "$work/out" --meta "$work/meta"
  cat "$work/out"
}

cmd=${1:-}
shift || true
case "$cmd" in
  asr) cmd_asr "$@" ;;
  tts) cmd_tts "$@" ;;
  *)
    echo "janus edge speech asr | janus edge speech tts [--play] <text>" >&2
    exit 2
    ;;
esac
