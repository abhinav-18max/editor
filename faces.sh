#!/usr/bin/env bash
# Find the faces in a video, who is talking, and where a vertical crop should
# sit, using Apple's on-device face detection (Vision) and ffmpeg.
#
# Looks at the picture a few times a second, finds every face and follows it
# through each shot (shots come from scenes.sh); a face whose lips keep moving
# is taken to be talking. For each shot it prints the faces, as the centre of
# each across the width (0 = left edge, 1 = right edge) and how much its mouth
# moves, and where a 9:16 crop should sit: on everyone if they fit, on whoever
# is talking if they don't (following the conversation within the shot), or
# "blur" for a wide group shot with no clear speaker. The last line is that
# plan as a reframe.sh -x string, in the file's own time; it goes straight
# into an edit file's "reframe" (or use "reframe": "auto" there).
#
# Usage: ./faces.sh [options] FILE
#   -s START   look from START: SS, MM:SS or HH:MM:SS, decimals ok (default: beginning)
#   -e END     ... up to END (default: end of file)
#   -r RATE    pictures looked at per second (default: 6)
#   -a ASPECT  the crop to plan for: 9:16 (default), 4:5 or 1:1
#   -o FILE    where to save the details as JSON (default: out/work/NAME.faces.json
#              next to this script, with the range in the name)
#   -h         show this help
#
# The first run builds the face finder from faces.swift (about 30 s).
# Speed: about 10 s for a minute of video.
#
# Examples:
#   ./faces.sh clip.mp4                          whole clip
#   ./faces.sh -s 7:25.6 -e 7:57.8 episode.mp4   one moment of an episode

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

start=""
end=""
rate=6
aspect="9:16"
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

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":s:e:r:a:o:h" opt; do
  case "$opt" in
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    r) rate="$OPTARG" ;;
    a) aspect="$OPTARG" ;;
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
[[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] && lt 0.5 "$rate" && ! lt 25 "$rate" || die "-r must be between 0.5 and 25"
case "$aspect" in
  9:16) ow=1080; oh=1920 ;;
  4:5)  ow=1080; oh=1350 ;;
  1:1)  ow=1080; oh=1080 ;;
  *)    die "-a must be 9:16, 4:5 or 1:1" ;;
esac
command -v swiftc >/dev/null 2>&1 || die "swiftc not found; install Xcode's command line tools: xcode-select --install"
FF=$(pick_ffmpeg) || die "ffmpeg is not installed (brew install ffmpeg-full)"
FP="${FF%ffmpeg}ffprobe"

# --- Inspect the input -------------------------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0 "$in"; }
duration=$(probe -show_entries format=duration)
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $in"
IFS=, read -r iw ih < <(probe -select_streams v:0 -show_entries stream=width,height) || true
[[ "${iw:-}" =~ ^[0-9]+$ && "${ih:-}" =~ ^[0-9]+$ ]] || die "no video stream found in $in"

s=0
e="$duration"
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi
lt "$s" "$duration" || die "start $start is past the end of the file"
if ! lt "$e" "$duration"; then e="$duration"; fi
lt "$s" "$e" || die "end ($end) must be after start (${start:-0})"
length=$(minus "$e" "$s")

# The crop window's width as a share of the picture, as reframe.sh cuts it.
window=$(awk -v iw="$iw" -v ih="$ih" -v ow="$ow" -v oh="$oh" \
  'BEGIN { cw = int(ih * ow / oh / 2) * 2; if (cw > iw) cw = iw; printf "%.4f", cw / iw }')

if [[ -z "$out" ]]; then
  name=$(basename "$in")
  name="${name%.*}"
  if [[ -n "$start$end" ]]; then
    name+=$(awk -v a="$s" -v b="$e" 'BEGIN { printf "-%ds-%ds", a, b }')
  fi
  mkdir -p "$HERE/out/work"
  out="$HERE/out/work/$name.faces.json"
fi
[[ "$out" == *.json ]] || die "-o should end in .json"

# --- The face finder, built once from faces.swift ----------------------------

cache="${XDG_CACHE_HOME:-$HOME/Library/Caches}/editor-tools"
finder="$cache/faces-$(md5 -q "$HERE/faces.swift")"
if [[ ! -x "$finder" ]]; then
  echo "Building the face finder (once, about 30 s)..."
  mkdir -p "$cache"
  swiftc -O -o "$finder.tmp" "$HERE/faces.swift" 2>"$cache/build.log" || { tail -5 "$cache/build.log" >&2; die "could not build faces.swift"; }
  mv "$finder.tmp" "$finder"
fi

# --- Look --------------------------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/f"

printf 'Looking at %.0f s of video, %s pictures a second...\n' "$length" "$rate"
SECONDS=0
"$FF" -hide_banner -loglevel error -nostdin -ss "$s" -t "$length" -i "$in" -an \
  -vf "fps=$rate,scale=640:-2" -q:v 3 "$tmp/f/%06d.jpg"
"$HERE/scenes.sh" -s "$s" -e "$e" -o "$tmp/shots.txt" "$in" >/dev/null
# Vision logs chatter on stderr; keep it for when something goes wrong.
"$finder" "$tmp/f" >"$tmp/frames.jsonl" 2>"$tmp/finder.log" || { tail -5 "$tmp/finder.log" >&2; die "the face finder failed"; }

python3 -I "$HERE/faces-track.py" --start "$s" --end "$e" --fps "$rate" --window "$window" \
  "$tmp/frames.jsonl" "$tmp/shots.txt" "${out%.json}"
echo "Done in ${SECONDS} s"
echo "Saved to: $out"
