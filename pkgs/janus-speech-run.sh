# Speech engines for janus.edge.api and `janus edge speech`. docs/08 §1d, docs/14 §8.
# The bearer token is checked by the Janet listener, not here.
# Audio and text are not stored and are not written to the log.
set -eu

json=${JANUS_SPEECH_JSON:-/etc/janus/speech.json}
# Not the runtime directory. install -d -m on that path makes it world-traversable. T-0021.
lockdir=${JANUS_SPEECH_LOCKDIR:-/run/janus-http/lock}
# 30 seconds of 16 kHz mono. docs/08 §1d.
max_samples=480000

usage() {
  echo "janus-speech-run recognize|synthesize --body FILE --ctype TYPE --out FILE --meta FILE" >&2
  exit 2
}

field() {
  jq -r "$1" "$json"
}

need() {
  if [ ! -f "$json" ]; then
    echo "janus edge speech is not in this image." >&2
    exit 2
  fi
}

fail_bad() {
  echo "unavailable" >&2
  exit 4
}

fail_channel() {
  echo "unavailable" >&2
  exit 6
}

hold_lock() {
  name=$1
  fd=$2
  install -d -m 0700 "$lockdir"
  eval "exec ${fd}>\"\$lockdir/\$name\""
  # Root creates the file. The listener user still has to open it. T-0021.
  chmod 0660 "$lockdir/$name" 2>/dev/null || true
  chgrp janus-http "$lockdir/$name" 2>/dev/null || true
  if ! flock -n "$fd"; then
    echo "busy" >&2
    exit 5
  fi
}

# Signed 16-bit PCM states its rate. WAV carries its own header. *08* §1d.
need_pcm() {
  case "$rate" in
    ''|*[!0-9]*) fail_bad ;;
  esac
  # 10# keeps a leading zero in decimal. A longer value is above 48000.
  if [ "${#rate}" -gt 5 ] || [ "$((10#$rate))" -lt 8000 ] || [ "$((10#$rate))" -gt 48000 ]; then
    fail_bad
  fi
  case "$channels" in
    1|2) ;;
    *) fail_bad ;;
  esac
}

resample() {
  body=$1
  ctype=$2
  rate=$3
  channels=$4
  wav=$5
  kind=$ctype
  case "$kind" in
    audio/wav|audio/x-wav|audio/wave) kind=wav ;;
    audio/L16|audio/pcm|audio/raw) kind=raw ;;
    *)
      sig=$(dd if="$body" bs=4 count=1 2>/dev/null || true)
      case "$sig" in
        RIFF) kind=wav ;;
        *) kind=raw ;;
      esac
      ;;
  esac
  case "$kind" in
    wav)
      sox "$body" -r 16000 -c 1 -b 16 -e signed-integer "$wav" || fail_bad
      ;;
    raw)
      need_pcm
      sox -t raw -r "$rate" -c "$channels" -b 16 -e signed-integer "$body" \
        -r 16000 -c 1 -b 16 -e signed-integer "$wav" || fail_bad
      ;;
  esac
  frames=$(soxi -s "$wav")
  if [ "$frames" -gt "$max_samples" ]; then
    fail_bad
  fi
}

cmd=${1:-}
shift || usage
body=""
ctype=""
rate=""
channels=""
out=""
meta=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body=${2:-}; shift 2 ;;
    --ctype) ctype=${2:-}; shift 2 ;;
    --rate) rate=${2:-}; shift 2 ;;
    --channels) channels=${2:-}; shift 2 ;;
    --out) out=${2:-}; shift 2 ;;
    --meta) meta=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
if [ -z "$body" ] || [ -z "$out" ] || [ -z "$meta" ]; then
  usage
fi
need
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$cmd" in
  recognize)
    if [ "$(field '.asr')" != true ]; then
      echo "janus edge speech asr is not in this image. Set janus.edge.speech.asr.enable and rebuild." >&2
      exit 2
    fi
    input=network
    case "$ctype" in
      application/json|application/json\;*)
        input=$(jq -r '.input // empty' "$body" 2>/dev/null) || fail_bad
        ;;
    esac
    case "$input" in
      network|microphone) ;;
      *) fail_channel ;;
    esac
    wav=$work/in.wav
    if [ "$input" = microphone ]; then
      rec=$(field '.recording.input')
      if [ -z "$rec" ] || [ "$rec" = null ]; then
        fail_channel
      fi
      seconds=$(jq -r '.seconds // empty' "$body" 2>/dev/null) || fail_bad
      case "$seconds" in
        ''|*[!0-9]*) fail_bad ;;
      esac
      if [ "${#seconds}" -gt 2 ] || [ "$((10#$seconds))" -lt 1 ] || [ "$((10#$seconds))" -gt 30 ]; then
        fail_bad
      fi
      samples=$((10#$seconds * 16000))
      hold_lock microphone 9
      node=$(field '.recording.node')
      pw=$(field '.recordBin')
      if [ -n "$node" ] && [ "$node" != null ]; then
        "$pw" --rate 16000 --channels 1 --format s16 --sample-count "$samples" --target "$node" "$wav" || fail_bad
      else
        "$pw" --rate 16000 --channels 1 --format s16 --sample-count "$samples" "$wav" || fail_bad
      fi
    else
      case "$ctype" in
        application/json|application/json\;*) fail_bad ;;
      esac
      resample "$body" "$ctype" "$rate" "$channels" "$wav"
    fi
    lang=$(field '.language')
    if [ -z "$lang" ] || [ "$lang" = null ]; then
      lang=auto
    fi
    whisper=$(field '.whisper')
    model=$(field '.model')
    if ! "$whisper" -m "$model" -f "$wav" -l "$lang" -nt -np > "$work/text" 2>"$work/err"; then
      "$whisper" -m "$model" -f "$wav" -l "$lang" -nt > "$work/text" 2>"$work/err" || fail_bad
    fi
    raw=$(cat "$work/text")
    text=$(printf '%s\n' "$raw" | sed -E 's/^\[[0-9:.]+ --> [0-9:.]+\][[:space:]]*//' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    jq -n --arg text "$text" '{text:$text}' > "$out"
    printf '%s\n' 'application/json' > "$meta"
    ;;
  synthesize)
    if [ "$(field '.tts')" != true ]; then
      echo "janus edge speech tts is not in this image. Set janus.edge.speech.tts.enable and rebuild." >&2
      exit 2
    fi
    output=$(jq -r '.output // empty' "$body" 2>/dev/null) || fail_bad
    text=$(jq -r '.text // empty' "$body" 2>/dev/null) || fail_bad
    case "$output" in
      network|playback) ;;
      *) fail_channel ;;
    esac
    if [ -z "$text" ] || [ "${#text}" -gt 4000 ]; then
      fail_bad
    fi
    voice=$(field '.voice')
    voices=$(field '.voices')
    model=$voices/$voice.onnx
    config=$voices/$voice.onnx.json
    if [ ! -f "$model" ] || [ ! -f "$config" ]; then
      fail_bad
    fi
    wav=$work/out.wav
    if [ "$output" = playback ]; then
      play=$(field '.playback.output')
      if [ -z "$play" ] || [ "$play" = null ]; then
        fail_channel
      fi
      hold_lock playback 8
    fi
    piper=$(field '.piper')
    printf '%s\n' "$text" | "$piper" -m "$model" -c "$config" -f "$wav" >/dev/null || fail_bad
    if [ "$output" = playback ]; then
      node=$(field '.playback.node')
      pw=$(field '.playBin')
      export PIPEWIRE_RUNTIME_DIR=${PIPEWIRE_RUNTIME_DIR:-/run}
      if [ -n "$node" ] && [ "$node" != null ]; then
        "$pw" --target "$node" "$wav" >/dev/null
      else
        "$pw" "$wav" >/dev/null
      fi
      printf '%s\n' played > "$out"
      printf '%s\n' 'text/plain' > "$meta"
    else
      cp "$wav" "$out"
      printf '%s\n' 'audio/wav' > "$meta"
    fi
    ;;
  *)
    usage
    ;;
esac
