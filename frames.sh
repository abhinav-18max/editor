#!/usr/bin/env bash
# Grab frames from a video so you can look at them, using ffmpeg.
#
# Either one frame at a given time, or a contact sheet: a grid of frames
# spread evenly over a time range, each labelled with its time in the video.
#
# Usage: ./frames.sh [options] FILE
#   -t TIME     one frame at TIME: SS, MM:SS or HH:MM:SS, decimals ok
#   -s START    contact sheet from START (default: beginning)
#   -e END      ... up to END (default: end of file)
#   -n COUNT    frames in the sheet (default: 12)
#   -i SECONDS  seconds between frames, instead of a count
#   -c COLS     columns in the sheet (default: 4)
#   -W WIDTH    sheet width in pixels (default: 1536)
#   -o FILE     output .jpg (default: out/frames/NAME-<time>.jpg next to this script)
#   -q N        JPEG quality, 2 (best) to 8 (default: 3)
#   -h          show this help
#
# Examples:
#   ./frames.sh -t 1:05 clip.mp4                     one frame at 1:05
#   ./frames.sh -s 5:00 -e 6:00 -n 12 episode.mp4    12 frames over that minute
#   ./frames.sh -i 10 clip.mp4                       a frame every 10 seconds

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

time=""
start=""
end=""
count=12
interval=""
cols=""
width=1536
out=""
quality=3

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
calc()  { awk "BEGIN { printf \"%.3f\", $1 }"; }
# 3723.5 -> "01:02:03.5"
hms()   { awk -v t="$1" 'BEGIN { h = int(t / 3600); m = int((t - h * 3600) / 60); s = t - h * 3600 - m * 60; printf "%02d:%02d:%04.1f", h, m, s }'; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":t:s:e:n:i:c:W:o:q:h" opt; do
  case "$opt" in
    t) time="$OPTARG" ;;
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    n) count="$OPTARG" ;;
    i) interval="$OPTARG" ;;
    c) cols="$OPTARG" ;;
    W) width="$OPTARG" ;;
    o) out="$OPTARG" ;;
    q) quality="$OPTARG" ;;
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
for n in "$count" "$width" "$quality" ${cols:+"$cols"}; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "expected a whole number, got '$n'"
done

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

probe() { "$FP" -v error -select_streams v:0 -show_entries "$1" -of csv=p=0 "$in"; }
duration=$(probe format=duration)
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $in"
IFS=, read -r iw ih < <(probe stream=width,height) || true
[[ "$iw" =~ ^[0-9]+$ && "$ih" =~ ^[0-9]+$ ]] || die "no video stream found in $in"

name=$(basename "$in")
name="${name%.*}"
mkdir -p "$HERE/out/frames"

# --- One frame ---------------------------------------------------------------

if [[ -n "$time" ]]; then
  [[ -z "$start$end$interval" ]] || die "-t can't be combined with -s, -e or -i"
  t=$(to_seconds "$time")
  lt "$t" "$duration" || die "$time is past the end of the file"
  [[ -n "$out" ]] || out="$HERE/out/frames/$name-$(hms "$t" | tr ':' '-').jpg"
  "$FF" -hide_banner -loglevel error -nostdin -y -ss "$t" -i "$in" \
    -vf "scale='min(1280,iw)':-2" -frames:v 1 -q:v 2 -update 1 "$out"
  echo "Frame at $(hms "$t")"
  echo "Saved to: $out"
  exit 0
fi

# --- Contact sheet -----------------------------------------------------------

s=0
e="$duration"
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi
lt "$s" "$duration" || die "start $start is past the end of the file"
if ! lt "$e" "$duration"; then e="$duration"; fi
lt "$s" "$e" || die "end ($end) must be after start (${start:-0})"
length=$(calc "$e - $s")

if [[ -n "$interval" ]]; then
  [[ "$interval" =~ ^[0-9]*\.?[0-9]+$ ]] || die "-i expects seconds, got '$interval'"
  count=$(awk -v l="$length" -v i="$interval" 'BEGIN { n = int(l / i); if (n < 1) n = 1; print n }')
else
  [[ "$count" -ge 1 ]] || die "-n must be at least 1"
  interval=$(calc "$length / $count")
fi
lt 0 "$interval" || die "the range is too short for that many frames"

# Vertical video gets more, narrower columns so the sheet stays roughly square.
if [[ -z "$cols" ]]; then
  # Also for vertical video: narrower tiles are too small to judge a crop.
  cols=4
fi
[[ "$cols" -ge 1 ]] || die "-c must be at least 1"
[[ "$cols" -gt "$count" ]] && cols=$count
rows=$(( (count + cols - 1) / cols ))
pad=4
tile_w=$(( (width - 2 * pad - (cols - 1) * pad) / cols / 2 * 2 ))
[[ "$tile_w" -ge 64 ]] || die "sheet too narrow for $cols columns (use -W or -c)"
tile_h=$(( tile_w * ih / iw ))
# Big enough to read, small enough that "00:00:00.000" fits in a narrow tile.
font=$(( tile_h / 9 ))
[[ "$font" -le $(( tile_w / 8 )) ]] || font=$(( tile_w / 8 ))
[[ "$font" -ge 14 ]] || font=14

# Seeking resets timestamps to 0, so the label gets the start time added back.
label="drawtext=fontfile=/System/Library/Fonts/Menlo.ttc:fontsize=$font:fontcolor=white"
# Bottom left: titles sit at the top, captions above the bottom.
label+=":box=1:boxcolor=black@0.6:boxborderw=4:x=6:y=h-th-10:text='%{pts\:hms\:$s}'"
# (ffmpeg -h filter=NAME answers "Unknown filter" for ones it wasn't built with.)
if [[ "$("$FF" -hide_banner -h filter=drawtext 2>&1)" != "Filter drawtext"* ]]; then
  echo "Note: this ffmpeg can't draw text, so tiles are unlabelled (brew install ffmpeg-full)" >&2
  label="null"
fi

[[ -n "$out" ]] || out="$HERE/out/frames/$name-$(hms "$s" | tr ':' '-')-$(hms "$e" | tr ':' '-').jpg"
"$FF" -hide_banner -loglevel error -nostdin -y -ss "$s" -t "$length" -i "$in" \
  -vf "select='gte(t,selected_n*$interval)',trim=end_frame=$count,scale=$tile_w:-2,$label,tile=${cols}x${rows}:padding=$pad:margin=$pad:color=0x202020" \
  -frames:v 1 -q:v "$quality" -update 1 "$out"

# Each tile is the first real frame at or after its moment, so a label is
# that frame's own time (the fps filter would show a neighbour of it, up to
# half a step later or earlier).
rate=$(probe stream=r_frame_rate)
frame_time() {  # first frame at or after START + K steps, in the file's time
  awk -v s="$s" -v k="$1" -v i="$interval" -v r="$rate" 'BEGIN {
    split(r, p, "/"); f = p[1] / (p[2] ? p[2] : 1); if (f <= 0) f = 25
    j = k * i * f; n = int(j); if (n < j - 1e-6) n++; printf "%.3f", s + n / f }'
}

# Reading order is left to right, then top to bottom.
echo "$count frames, every $(calc "$interval") s, $cols per row:"
for ((r = 0; r < rows; r++)); do
  line="  row $((r + 1)):"
  for ((c = 0; c < cols; c++)); do
    k=$((r * cols + c))
    [[ "$k" -lt "$count" ]] || break
    line+=" $(hms "$(frame_time "$k")")"
  done
  echo "$line"
done
echo "Saved to: $out"
