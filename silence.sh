#!/usr/bin/env bash
# Find the pauses in a recording and the stretches of sound between them,
# using ffmpeg.
#
# A pause is at least -m seconds quieter than the noise floor. Prints the
# pauses, then the sound ranges between them, then a summary, and saves the
# same. Each sound range is widened by -p seconds into the pauses on either
# side so words aren't clipped; ranges that then overlap are joined. To cut
# out dead air, keep one clip per sound range. Times are in the file's own
# time, also with -s/-e.
#
# Usage: ./silence.sh [options] FILE
#   -s START  look from START: SS, MM:SS or HH:MM:SS, decimals ok
#             (default: beginning)
#   -e END    ... up to END (default: end of file)
#   -n DB     noise floor in dB: anything quieter counts as silence
#             (default: -35); "auto" puts it 10 dB under the sound's typical
#             level, which finds the gaps in speech over a music bed or room
#             noise (TV shows), where -35 finds none
#   -m SECS   shortest pause to report (default: 0.5)
#   -p PAD    seconds of each pause to keep next to the sound in the sound
#             ranges (default: 0.15)
#   -j        save JSON instead of text, and print only the summary:
#             {"duration": file length, "start", "end",
#              "silences": [[s, e], ...], "sounds": [[s, e], ...]}
#   -o FILE   where to save (default: out/work/NAME.silence.txt, or
#             NAME.silence.json with -j, next to this script)
#   -h        show this help
#
# Examples:
#   ./silence.sh clip.mp4                       pauses of half a second or more
#   ./silence.sh -m 0.3 -p 0.1 clip.mp4         tighter, for fast-paced edits
#   ./silence.sh -s 2:00 -e 3:00 -j talk.m4a    one minute, as JSON

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

start=""
end=""
noise=-35
minpause=0.5
pad=0.15
json=false
out=""

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
is_num() { [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]]; }
fix3()  { awk -v x="$1" 'BEGIN { printf "%.3f", x }'; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":s:e:n:m:p:jo:h" opt; do
  case "$opt" in
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    n) noise="$OPTARG" ;;
    m) minpause="$OPTARG" ;;
    p) pad="$OPTARG" ;;
    j) json=true ;;
    o) out="$OPTARG" ;;
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
noise="${noise%dB}"
[[ "$noise" == auto || "$noise" =~ ^-[0-9]*\.?[0-9]+$ || "$noise" == 0 ]] || die "-n must be a level below 0 dB, like -35, or auto"
{ is_num "$minpause" && lt 0 "$minpause"; } || die "-m must be a number of seconds above 0"
is_num "$pad" || die "-p must be a number of seconds"

if ! pick_ffmpeg >/dev/null; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ffmpeg..."
    brew install ffmpeg
  else
    die "ffmpeg is not installed and Homebrew isn't available to install it."
  fi
fi
FF=$(pick_ffmpeg)
FP="${FF%ffmpeg}ffprobe"

# --- Inspect the input -------------------------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0 "$in"; }

duration=$(probe -show_entries format=duration 2>/dev/null) || die "can't read $in (not audio or video?)"
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "can't tell how long $in is"
[[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name)" ]] || die "no audio found in $in"

s=0
e=$(fix3 "$duration")
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then
  e=$(to_seconds "$end")
  # An end past the end of the file just means "to the end".
  lt "$e" "$duration" || e=$(fix3 "$duration")
fi
lt "$s" "$duration" || die "start $start is past the end of the file"
lt "$s" "$e" || die "end ($end) must be after start (${start:-0})"

if [[ -z "$out" ]]; then
  name=$(basename "$in")
  name="${name%.*}"
  # A range gets its own file, so looking at another part doesn't replace it.
  if [[ -n "$start$end" ]]; then name+=$(awk -v a="$s" -v b="$e" 'BEGIN { printf "-%ds-%ds", a, b }'); fi
  if $json; then out="$HERE/out/work/$name.silence.json"; else out="$HERE/out/work/$name.silence.txt"; fi
fi
[[ "$out" != "$in" ]] || die "output would overwrite the input"
mkdir -p "$(dirname "$out")"

# --- Detect the pauses -------------------------------------------------------

# silencedetect tags the audio with lavfi.silence_start/_end (to the sample);
# ametadata prints those tags. Input seeking makes times start at 0, so START
# is added back below. A pause still open at the end gets no silence_end.
# apad fills in silence where the sound stops before the picture does.
len=$(minus "$e" "$s")
if [[ "$noise" == auto ]]; then
  # The typical level: the median of the sound's loudness in 50 ms steps.
  levels=("$FF" -hide_banner -loglevel error -nostdin)
  if lt 0 "$s"; then levels+=(-ss "$s"); fi
  if lt "$e" "$duration"; then levels+=(-t "$len"); fi
  levels+=(-vn -sn -dn -i "$in" -map 0:a:0 -af "aresample=16000,asetnsamples=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" -f null -)
  noise=$("${levels[@]}" | awk -F= '/RMS_level=/ && $2 != "-inf" { v[++n] = $2 } END {
    if (!n) { print -35; exit }
    for (i = 2; i <= n; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
    f = v[int((n + 1) / 2)] - 10; if (f < -50) f = -50; if (f > -12) f = -12; printf "%.0f", f }')
  echo "Noise floor: $noise dB (10 dB under the typical level)"
fi
cmd=("$FF" -hide_banner -loglevel error -nostdin)
if lt 0 "$s"; then cmd+=(-ss "$s"); fi
if lt "$e" "$duration"; then cmd+=(-t "$len"); fi
cmd+=(-vn -sn -dn -i "$in" -map 0:a:0
      -af "apad=whole_dur=$len,silencedetect=n=${noise}dB:d=$minpause,ametadata=print:file=-"
      -f null -)

marks=$("${cmd[@]}") || die "ffmpeg could not read the audio in $in"

# --- List pauses and sound ---------------------------------------------------

# All arithmetic is in whole milliseconds, so the listed lengths add up.
# The output path comes in through the environment: awk -v would mangle backslashes.
summary=$(OUT="$out" awk -v s="$s" -v e="$e" -v pad="$pad" -v dur="$duration" -v json="$json" '
  function ms(t) { return int(t * 1000 + 0.5) }
  function clock(m,   h, mm) {
    h = int(m / 3600000); mm = int(m % 3600000 / 60000)
    return h ? sprintf("%d:%02d:%06.3f", h, mm, (m % 60000) / 1000) : sprintf("%02d:%06.3f", mm, (m % 60000) / 1000)
  }
  function sec(m) { return sprintf("%.3f", m / 1000) }
  function pair(a, b) { return "[" sec(a) "," sec(b) "]" }
  BEGIN { S = ms(s); E = ms(e); P = ms(pad); n = 0; open = 0; out = ENVIRON["OUT"] }
  /^lavfi\.silence_start=/ {
    if (!open) { t = substr($0, index($0, "=") + 1); a[++n] = S + ms(t); open = 1 }
  }
  /^lavfi\.silence_end=/ {
    if (open) { t = substr($0, index($0, "=") + 1); b[n] = S + ms(t); open = 0 }
  }
  END {
    if (open) b[n] = E
    # Keep the pauses inside [START, END], in order, without zero-length ones.
    k = 0
    for (i = 1; i <= n; i++) {
      x = a[i] < S ? S : a[i]; y = b[i] > E ? E : b[i]
      # Pauses that touch (silencedetect sometimes splits one) become one.
      if (k && x <= pb[k] + 10) { if (y > pb[k]) pb[k] = y; continue }
      if (y > x) { pa[++k] = x; pb[k] = y }
    }
    # Sound is what lies between the pauses, widened by PAD, overlaps joined.
    m = 0; prev = S; silent = 0
    for (i = 1; i <= k + 1; i++) {
      x = prev; y = (i <= k) ? pa[i] : E
      if (i <= k) { prev = pb[i]; silent += pb[i] - pa[i] }
      if (y <= x) continue
      x -= P; y += P
      if (x < S) x = S
      if (y > E) y = E
      if (m && x <= sb[m]) { if (y > sb[m]) sb[m] = y }
      else { sa[++m] = x; sb[m] = y }
    }
    len = E - S
    line = sprintf("%d pause%s, %.2f s silent of %.2f s (%d %%)", k, (k == 1 ? "" : "s"), silent / 1000, len / 1000, int(100 * silent / len + 0.5))
    if (json == "true") {
      o = "{\"duration\":" sprintf("%.3f", dur) ",\"start\":" sec(S) ",\"end\":" sec(E) ",\"silences\":["
      for (i = 1; i <= k; i++) o = o (i > 1 ? "," : "") pair(pa[i], pb[i])
      o = o "],\"sounds\":["
      for (i = 1; i <= m; i++) o = o (i > 1 ? "," : "") pair(sa[i], sb[i])
      print o "]}" > out
    } else {
      for (i = 1; i <= k; i++) printf "pause  %s – %s %6.2f s\n", clock(pa[i]), clock(pb[i]), (pb[i] - pa[i]) / 1000 > out
      for (i = 1; i <= m; i++) printf "sound  %s – %s %6.2f s\n", clock(sa[i]), clock(sb[i]), (sb[i] - sa[i]) / 1000 > out
      print line > out
    }
    print line
  }' <<<"$marks")

if $json; then echo "$summary"; else cat "$out"; fi
echo "Saved to: $out"
