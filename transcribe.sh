#!/usr/bin/env bash
# Transcribe the speech in a video or audio file, using whisper.cpp.
#
# Writes four files: NAME.txt, a compact "[mm:ss] text" transcript meant to be
# read in one go; NAME.srt, subtitles; NAME.words.json, the start and end of
# every word; and NAME.whisper.json, whisper's raw output. Timestamps are in
# the source file's time, even when only a part of it (-s/-e) is transcribed.
#
# Usage: ./transcribe.sh [options] FILE
#   -l LANG   spoken language code (default: ml); "auto" to detect
#   -t        translate to English instead (outputs get an ".en" suffix); whisper
#             writes Malayalam badly, so this is the usable option for it
#   -m MODEL  large-v3 (default; the only one that copes with Malayalam),
#             large-v3-turbo, medium, small, or a path to a ggml-*.bin file;
#             downloaded on first use
#   -s START  only transcribe from START: SS, MM:SS or HH:MM:SS, decimals ok
#   -e END    only transcribe up to END, same formats
#   -o DIR    output directory (default: out/transcripts next to this script)
#   -n NAME   output basename (default: the input's name, plus the range)
#   -V        voice activity detection: skips music and laughter, which
#             whisper otherwise tends to turn into made-up or repeated text
#   -F        transcribe again even if an up-to-date NAME.whisper.json exists
#   -X ARGS   extra whisper-cli arguments, e.g. -X "-mc 0" to stop repetition
#   -h        show this help
#
# Examples:
#   ./transcribe.sh sources/episode.mp4            whole file, Malayalam
#   ./transcribe.sh -s 5:00 -e 6:30 episode.mp4    just that part
#   ./transcribe.sh -m large-v3-turbo clip.mp4     faster, a little less accurate

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MODELS_DIR="${WHISPER_MODELS:-$HOME/Library/Caches/whisper-cpp}"
MODELS_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
VAD_MODEL="ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_MODEL"

lang=ml
translate=false
model=large-v3
start=""
end=""
out_dir="$HERE/out/transcripts"
name=""
vad=false
force=false
extra=""

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 0
}

# A mistake in how the tool was called: a pointer to -h, then the error, last.
bad_usage() {
  echo "(./$(basename "$0") -h lists the options; they go before the file)" >&2
  echo "Error: $*" >&2
  exit 1
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# "1:02:03.5" -> 3723.500
to_seconds() {
  local re='^([0-9]+:){0,2}[0-9]+(\.[0-9]+)?$'
  [[ "$1" =~ $re ]] || die "bad time '$1' (use SS, MM:SS or HH:MM:SS)"
  awk -v t="$1" 'BEGIN { n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; printf "%.3f", s }'
}

lt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
minus() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a - b }'; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":l:tm:s:e:o:n:VFX:h" opt; do
  case "$opt" in
    l) lang="$OPTARG" ;;
    t) translate=true ;;
    m) model="$OPTARG" ;;
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    o) out_dir="$OPTARG" ;;
    n) name="$OPTARG" ;;
    V) vad=true ;;
    F) force=true ;;
    X) extra="$OPTARG" ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -eq 1 ]] || bad_usage "give exactly one input file"
in="$1"
[[ -f "$in" ]] || die "no such file: $in"

# Install missing dependencies via Homebrew. whisper-cli comes with whisper-cpp.
for dep in whisper-cli ffmpeg; do
  if [[ "$dep" == ffmpeg ]] && pick_ffmpeg >/dev/null; then continue; fi
  if ! command -v "$dep" >/dev/null 2>&1; then
    pkg=$dep
    [[ "$dep" == whisper-cli ]] && pkg=whisper-cpp
    if command -v brew >/dev/null 2>&1; then
      echo "Installing $pkg..."
      brew install "$pkg"
    else
      die "$dep is not installed and Homebrew isn't available to install it."
    fi
  fi
done
FF=$(pick_ffmpeg) || die "ffmpeg not found"
FP="${FF%ffmpeg}ffprobe"

# --- Model ------------------------------------------------------------------

# Fetch URL to FILE, leaving nothing behind if the download fails halfway.
download() {
  local url="$1" file="$2"
  mkdir -p "$(dirname "$file")"
  echo "Downloading $(basename "$file") (first use only)..." >&2
  curl -fL --retry 3 --progress-bar -o "$file.part" "$url" || { rm -f "$file.part"; die "download failed: $url"; }
  mv "$file.part" "$file"
}

if [[ "$model" == */* || "$model" == *.bin ]]; then
  model_file="$model"
  model_name=$(basename "$model" .bin)
  model_name="${model_name#ggml-}"
else
  model_name="$model"
  model_file="$MODELS_DIR/ggml-$model.bin"
fi
[[ -f "$model_file" ]] || download "$MODELS_URL/ggml-$model_name.bin" "$model_file"

# Token-level timestamps are much better with the model's DTW alignment preset.
case "$model_name" in
  large-v3-turbo*) dtw=large.v3.turbo ;;
  large-v3*)       dtw=large.v3 ;;
  large-v2*)       dtw=large.v2 ;;
  large-v1*)       dtw=large.v1 ;;
  tiny|tiny.en|base|base.en|small|small.en|medium|medium.en) dtw="$model_name" ;;
  *)               dtw="" ;;
esac

vad_args=()
if $vad; then
  [[ -f "$MODELS_DIR/$VAD_MODEL" ]] || download "$VAD_URL" "$MODELS_DIR/$VAD_MODEL"
  vad_args=(--vad -vm "$MODELS_DIR/$VAD_MODEL")
fi

# --- Range and output names --------------------------------------------------

duration=$("$FP" -v error -show_entries format=duration -of csv=p=0 "$in" 2>/dev/null || true)
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $in"

s=0
e="$duration"
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi
lt "$s" "$duration" || die "start $start is past the end of the file"
if ! lt "$e" "$duration"; then e="$duration"; fi
lt "$s" "$e" || die "end ($end) must be after start (${start:-0})"
length=$(minus "$e" "$s")

if [[ -z "$name" ]]; then
  name=$(basename "$in")
  name="${name%.*}"
  if [[ -n "$start$end" ]]; then
    name+=$(awk -v a="$s" -v b="$e" 'BEGIN { printf "-%ds-%ds", a, b }')
  fi
fi
$translate && name+=".en"
mkdir -p "$out_dir"
base="$out_dir/$name"

# --- Transcribe --------------------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Reuse the previous run if nothing that affects it has changed.
cached=false
if ! $force && [[ -f "$base.whisper.json" && "$base.whisper.json" -nt "$in" ]]; then
  want_tr=false; $translate && want_tr=true
  if jq -e --arg l "$lang" --arg m "$model_file" --argjson t "$want_tr" \
       '.params.language == $l and .params.translate == $t and .params.model == $m' \
       "$base.whisper.json" >/dev/null 2>&1; then
    cached=true
  fi
fi

if $cached; then
  echo "Reusing $base.whisper.json (pass -F to transcribe again)"
  cp "$base.whisper.json" "$tmp/result.json"
else
  # whisper wants 16 kHz mono; ffmpeg also lets us take just the range.
  "$FF" -hide_banner -loglevel error -nostdin -ss "$s" -t "$length" -i "$in" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le "$tmp/audio.wav"

  threads=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)
  dtw_args=()
  [[ -n "$dtw" ]] && dtw_args=(-dtw "$dtw")
  tr_args=()
  $translate && tr_args=(-tr)
  extra_args=()
  [[ -n "$extra" ]] && read -r -a extra_args <<<"$extra"

  mode=Transcribing; $translate && mode=Translating
  printf '%s %.0f s of audio with %s (%s)...\n' "$mode" "$length" "$model_name" "$lang"
  if [[ "$lang" == ml ]] && ! $translate; then
    echo "Note: whisper writes Malayalam badly (wrong script, loops); -t gives usable English." >&2
  fi
  SECONDS=0
  # -nfa: flash attention makes this build emit garbage, so it stays off
  # -bs 5 -mc 0: beam search without carrying context over, which stops the
  #   repetition loops whisper falls into on laughter and music
  # -ojf: full JSON with per-token timings   -np -pp: only a progress percentage
  # (${arr[@]+"${arr[@]}"} is how macOS's bash 3.2 expands a possibly empty array.)
  whisper-cli -m "$model_file" -f "$tmp/audio.wav" -l "$lang" ${tr_args[@]+"${tr_args[@]}"} \
    -t "$threads" -nfa -bs 5 -mc 0 ${dtw_args[@]+"${dtw_args[@]}"} ${vad_args[@]+"${vad_args[@]}"} \
    -ojf -of "$tmp/result" -np -pp ${extra_args[@]+"${extra_args[@]}"} >"$tmp/whisper.log" 2>&1 &
  wpid=$!
  trap 'kill "$wpid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  # whisper-cli chatters a lot (-np notwithstanding); show just the percentage.
  while kill -0 "$wpid" 2>/dev/null; do
    sleep 2
    pct=$(grep -o 'progress = *[0-9]*%' "$tmp/whisper.log" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
    [[ -n "$pct" && "$pct" -le 100 ]] && printf '\r  %s%%' "$pct" >&2
  done
  if ! wait "$wpid" || [[ ! -f "$tmp/result.json" ]]; then
    echo >&2
    tail -5 "$tmp/whisper.log" >&2
    die "whisper-cli failed"
  fi
  printf '\r      \r' >&2
  took=$SECONDS
  speed=$(awk -v l="$length" -v t="$took" 'BEGIN { if (t < 1) t = 1; printf "%.1f", l / t }')
  echo "Done in ${took} s (${speed}x realtime)"
fi

# Turn whisper's JSON into the .txt / .srt / .words.json files.
summary=$(python3 -I "$HERE/whisper-json.py" --offset "$s" --length "$length" --model "$model_name" "$tmp/result.json" "$base")
$cached || cp "$tmp/result.json" "$base.whisper.json"
echo "$summary"

echo "Saved to: $base.txt"
