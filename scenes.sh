#!/usr/bin/env bash
# Find the shot changes (camera cuts) in a video, using ffmpeg.
#
# Every frame is compared with the one before it on a small copy of the
# picture; where the picture changes almost completely, a new shot starts.
# Prints one line per shot with its start, end and length, then a summary,
# and saves the same list. Times are in the file's own time, also with -s/-e.
# A cut that changes only part of the picture (a clip inside a meme
# template, a split screen) scores lower: try -t 0.15 for those.
#
# Usage: ./scenes.sh [options] FILE
#   -s START      look from START: SS, MM:SS or HH:MM:SS, decimals ok
#                 (default: beginning)
#   -e END        ... up to END (default: end of file)
#   -t THRESHOLD  how different two frames must be to count as a cut, 0 to 1
#                 (default: 0.3); lower finds softer cuts but also fast
#                 movement and flashes, higher keeps only the hardest cuts
#   -m MINGAP     ignore a cut less than MINGAP seconds after the previous one
#                 (default: 0.5)
#   -o FILE       where to save the list (default: out/work/NAME.scenes.txt
#                 next to this script)
#   -h            show this help
#
# Examples:
#   ./scenes.sh clip.mp4                        every shot in the clip
#   ./scenes.sh -s 5:00 -e 6:00 episode.mp4     the shots in that minute
#   ./scenes.sh -t 0.2 -m 1 clip.mp4            softer cuts, shots of 1 s or more

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

start=""
end=""
threshold=0.3
mingap=0.5
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

while getopts ":s:e:t:m:o:h" opt; do
  case "$opt" in
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    t) threshold="$OPTARG" ;;
    m) mingap="$OPTARG" ;;
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
{ is_num "$threshold" && ! lt 1 "$threshold"; } || die "-t must be a number from 0 to 1"
is_num "$mingap" || die "-m must be a number of seconds"

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

duration=$(probe -show_entries format=duration 2>/dev/null) || die "can't read $in (not a video?)"
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "can't tell how long $in is (a still image?)"
# Cover art in MP3/M4A files shows up as a video stream; only count real video.
grep -x 0 <<<"$(probe -select_streams v -show_entries stream_disposition=attached_pic)" >/dev/null ||
  die "no video stream found in $in"

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
  out="$HERE/out/work/$name.scenes.txt"
fi
[[ "$out" != "$in" ]] || die "output would overwrite the input"
mkdir -p "$(dirname "$out")"

# --- Score every frame -------------------------------------------------------

# Input seeking makes the frame times start at 0, so START is added back below.
# Scoring a 320-pixel-wide copy is as good as full size and many times faster.
cmd=("$FF" -hide_banner -loglevel error -nostdin -threads 0)
if lt 0 "$s"; then cmd+=(-ss "$s"); fi
if lt "$e" "$duration"; then cmd+=(-t "$(minus "$e" "$s")"); fi
cmd+=(-an -sn -dn -i "$in" -map 0:v:0
      -vf "scale='min(320,iw)':-2,select='gt(scene,$threshold)',metadata=print:file=-"
      -f null -)

cuts=$("${cmd[@]}") || die "ffmpeg could not read the video in $in"

# --- List the shots ----------------------------------------------------------

awk -v s="$s" -v e="$e" -v gap="$mingap" '
  function clock(t,   ms, h, m) {
    ms = int(t * 1000 + 0.5); h = int(ms / 3600000); m = int(ms % 3600000 / 60000)
    return h ? sprintf("%d:%02d:%06.3f", h, m, (ms % 60000) / 1000) : sprintf("%02d:%06.3f", m, (ms % 60000) / 1000)
  }
  BEGIN { n = 0; b[0] = s + 0; last = s + 0 }
  /pts_time:/ {
    t = $0; sub(/.*pts_time:/, "", t); t = s + t
    if (t > s && t < e && t - last >= gap - 0.0005) { b[++n] = t; last = t }
  }
  END {
    b[++n] = e + 0
    w = length(n "") < 2 ? 2 : length(n "")
    fmt = "shot %" w "d  %s – %s %6.2f s\n"
    for (i = 1; i <= n; i++) printf fmt, i, clock(b[i - 1]), clock(b[i]), b[i] - b[i - 1]
    len = e - s; shots = n
    printf "%d shot%s in %.2f s, average %.2f s\n", shots, (shots == 1 ? "" : "s"), len, len / shots
  }' <<<"$cuts" >"$out"

cat "$out"
echo "Saved to: $out"
