#!/usr/bin/env bash
# Check a finished video before it goes out, using ffmpeg.
#
# Looks at the file the way a platform and a viewer would: the right size,
# frame rate and codecs, sound present and as long as the picture, a length
# in range, loudness near -14 LUFS without clipping, and no black, frozen or
# silent stretch at the start or end (a sign of a bad cut). Prints one line
# per check, PASS, WARN or FAIL, and exits 1 if anything failed. Writes
# nothing.
#
# Usage: ./check.sh [options] FILE
#   -p PRESET  shorts (default: 1080x1920), youtube (1920x1080) or whatsapp (720x1280)
#   -d MIN-MAX length in seconds that's right for this video
#              (default: 30-60 for shorts, anything for the others); outside
#              it is a warning, past 180 s a short fails
#   -h         show this help
#
# Examples:
#   ./check.sh out/final/ep465-tea.mp4
#   ./check.sh -p youtube -d 600-1500 out/final/episode-tight.mp4

set -euo pipefail

preset=shorts
range=""

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

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":p:d:h" opt; do
  case "$opt" in
    p) preset="$OPTARG" ;;
    d) range="$OPTARG" ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -eq 1 ]] || bad_usage "give exactly one file"
in="$1"
[[ -f "$in" ]] || die "no such file: $in"

case "$preset" in
  shorts)   want="1080x1920"; [[ -n "$range" ]] || range="30-60" ;;
  youtube)  want="1920x1080" ;;
  whatsapp) want="720x1280" ;;
  *) die "-p must be shorts, youtube or whatsapp" ;;
esac
if [[ -n "$range" ]]; then
  [[ "$range" =~ ^[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)?$ ]] || die "-d expects MIN-MAX in seconds, like 30-60"
  dmin="${range%-*}"; dmax="${range#*-}"
fi

FF=$(pick_ffmpeg) || die "ffmpeg is not installed (brew install ffmpeg-full)"
FP="${FF%ffmpeg}ffprobe"

pass=0; warn=0; fail=0
report() {  # report PASS|WARN|FAIL "what" "detail"
  printf '%-4s  %-10s %s\n' "$1" "$2" "$3"
  case "$1" in PASS) pass=$((pass + 1)) ;; WARN) warn=$((warn + 1)) ;; FAIL) fail=$((fail + 1)) ;; esac
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }

# --- Streams -----------------------------------------------------------------

v() { "$FP" -v error -select_streams v:0 -show_entries "stream=$1" -of csv=p=0 "$in" 2>/dev/null | head -1; }
a() { "$FP" -v error -select_streams a:0 -show_entries "stream=$1" -of csv=p=0 "$in" 2>/dev/null | head -1; }
size=$(v width,height | tr , x)
[[ -n "$size" ]] || die "no video stream found in $in"
fps=$(v avg_frame_rate)
fps=$(awk -F/ -v f="$fps" 'BEGIN { split(f, p, "/"); if (p[2] == 0) p[2] = 1; printf "%.3f", p[1] / p[2] }')
vcodec=$(v codec_name); pix=$(v pix_fmt)
vdur=$(v duration); [[ "$vdur" =~ ^[0-9.]+$ ]] || vdur=$("$FP" -v error -show_entries format=duration -of csv=p=0 "$in")
acodec=$(a codec_name); arate=$(a sample_rate); ach=$(a channels); adur=$(a duration)

echo "$in"
if [[ "$size" == "$want" ]]; then report PASS size "$size"; else report FAIL size "$size, $preset wants $want"; fi
if ge "$fps" 23.9 && le "$fps" 60.01; then report PASS fps "$(awk -v f="$fps" 'BEGIN { printf "%g", f }')"
else report FAIL fps "$fps (expected 24 to 60)"; fi
if [[ "$vcodec" == h264 && "$pix" == yuv420p ]]; then report PASS video "h264 $pix"
else report WARN video "$vcodec $pix (h264 yuv420p plays everywhere)"; fi
if [[ -z "$acodec" ]]; then
  report FAIL audio "no sound"
else
  if [[ "$acodec" == aac && "$arate" == 48000 && "$ach" == 2 ]]; then report PASS audio "aac 48 kHz stereo"
  else report WARN audio "$acodec $arate Hz, $ach channel(s) (aac 48 kHz stereo is the norm)"; fi
  [[ "$adur" =~ ^[0-9.]+$ ]] || adur="$vdur"
  gap=$(awk -v a="$adur" -v b="$vdur" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.3f", d }')
  if le "$gap" 0.1; then report PASS sync "sound and picture both ${vdur%???} s"
  else report WARN sync "sound $adur s, picture $vdur s"; fi
fi
len=$(awk -v d="$vdur" 'BEGIN { printf "%.2f", d }')
if [[ "$preset" == shorts ]] && ! le "$vdur" 180; then
  report FAIL length "$len s (Shorts take at most 180 s)"
elif [[ -n "$range" ]] && ! { ge "$vdur" "$dmin" && le "$vdur" "$dmax"; }; then
  report WARN length "$len s, outside $range s"
else
  report PASS length "$len s"
fi

# --- What it looks and sounds like (one pass) --------------------------------

graph="[0:v]blackdetect=d=0.25:pix_th=0.08,freezedetect=n=-60dB:d=1.5[vo]"
amap=()
if [[ -n "$acodec" ]]; then
  graph+=";[0:a]silencedetect=n=-50dB:d=0.8,ebur128=peak=true[ao]"
  amap=(-map "[ao]")
fi
log=$("$FF" -hide_banner -nostdin -i "$in" -filter_complex "$graph" -map "[vo]" ${amap[@]+"${amap[@]}"} -f null - 2>&1 || true)

edge=0.5  # a problem this close to the start or end counts as being at the edge
end_near=$(awk -v d="$vdur" -v e="$edge" 'BEGIN { printf "%.3f", d - e }')

black=$(awk -F'[: ]+' '/black_start/ { for (i = 1; i <= NF; i++) { if ($i == "black_start") s = $(i+1); if ($i == "black_end") e = $(i+1) } print s, e }' <<<"$log")
bad=""
while read -r s e; do
  [[ -n "${s:-}" ]] || continue
  if le "$s" "$edge" || ge "$e" "$end_near"; then bad+="${bad:+, }$(printf '%.1f-%.1f s' "$s" "$e")"; fi
done <<<"$black"
if [[ -z "$bad" ]]; then report PASS black "none at the start or end"; else report WARN black "black at $bad"; fi

frozen=$(awk '/freeze_start/ { s = $NF } /freeze_end/ { print s, $NF }' <<<"$log")
bad=""
while read -r s e; do
  [[ -n "${s:-}" ]] || continue
  bad+="${bad:+, }$(printf '%.1f-%.1f s' "$s" "$e")"
done <<<"$frozen"
if [[ -z "$bad" ]]; then report PASS frozen "no still stretch over 1.5 s"; else report WARN frozen "picture doesn't move at $bad"; fi

if [[ -n "$acodec" ]]; then
  quiet=$(awk '/silence_start/ { s = $NF } /silence_end/ { split($0, p, "silence_end: "); split(p[2], q, " "); print s, q[1] }' <<<"$log")
  # A silence still running at the end has no silence_end line.
  last_start=$(awk '/silence_start/ { s = $NF } /silence_end/ { s = "" } END { print s }' <<<"$log")
  [[ -n "$last_start" ]] && quiet+=$'\n'"$last_start $vdur"
  bad=""
  while read -r s e; do
    [[ -n "${s:-}" ]] || continue
    if le "$s" "$edge" || ge "$e" "$end_near"; then bad+="${bad:+, }$(printf '%.1f-%.1f s' "$s" "$e")"; fi
  done <<<"$quiet"
  if [[ -z "$bad" ]]; then report PASS silence "none at the start or end"; else report WARN silence "silent at $bad"; fi

  lufs=$(awk '/Integrated loudness:/ { on = 1 } on && /I:/ { print $2; exit }' <<<"$log")
  peak=$(awk '/True peak:/ { on = 1 } on && /Peak:/ { print $2; exit }' <<<"$log")
  if [[ "$lufs" =~ ^-?[0-9.]+$ ]]; then
    if ge "$lufs" -15 && le "$lufs" -13; then report PASS loudness "$lufs LUFS"
    else report WARN loudness "$lufs LUFS (platforms level to about -14; render.sh does that)"; fi
  fi
  if [[ "$peak" =~ ^-?[0-9.]+$ ]]; then
    if le "$peak" -1; then report PASS peak "$peak dBTP"
    else report WARN peak "$peak dBTP (above -1: may distort after upload)"; fi
  fi
fi

echo "$pass passed, $warn warning(s), $fail failed"
[[ $fail -eq 0 ]]
