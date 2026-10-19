#!/usr/bin/env bash
# Speed up or slow down a video, or just one part of it, using ffmpeg.
#
# Without -s/-e the whole file changes speed. With them only the part between
# START and END does, and the rest plays normally around it, all in one file.
# Voices keep their pitch unless -p is given. The frame rate stays the same:
# frames are dropped when speeding up and repeated when slowing down, or with
# -i new in-between frames are made for smooth slow motion.
#
# Usage: ./speed.sh -x FACTOR [options] FILE
#   -x FACTOR  how fast: 2 = twice as fast, 0.5 = half speed (0.25 to 4)
#   -s START   change only from START: SS, MM:SS or HH:MM:SS, decimals ok
#              (default: beginning); snapped to the nearest frame
#   -e END     ... up to END (default: end of file)
#   -p         let the pitch move with the speed, like a tape (faster = higher)
#   -i         smooth slow motion: make in-between frames instead of repeating
#              them (only for factors below 1; slow, a few frames a second)
#   -o FILE    output file (default: next to the input, e.g. "clip (2x).mp4")
#   -f         fast draft: quicker encode, lower quality; with -i, frames are
#              blended instead of motion-tracked
#   -h         show this help
#
# Examples:
#   ./speed.sh -x 2 clip.mp4                        whole clip twice as fast
#   ./speed.sh -x 0.5 -s 12.3 -e 14.8 -i clip.mp4   smooth slow motion for 2.5 s
#   ./speed.sh -x 1.5 -p clip.mp4                   faster, with higher voices

set -euo pipefail

factor=""
start=""
end=""
pitch=false
interp=false
out=""
fast=false

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
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# The same file however it's spelled: "./a/../b.mp4" -> "/full/path/b.mp4"
abspath() { local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d=$(dirname "$1"); echo "$d/$(basename "$1")"; }
# 3723.5 -> "01:02:03.500", 75.5 -> "01:15.500"
hms()   { awk -v t="$1" 'BEGIN { h = int(t / 3600); m = int((t - h * 3600) / 60); s = t - h * 3600 - m * 60;
                                 if (h > 0) printf "%d:%02d:%06.3f", h, m, s; else printf "%02d:%06.3f", m, s }'; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":x:s:e:pio:fh" opt; do
  case "$opt" in
    x) factor="$OPTARG" ;;
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    p) pitch=true ;;
    i) interp=true ;;
    o) out="$OPTARG" ;;
    f) fast=true ;;
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
[[ "$(basename "$in")" == *.* ]] || die "input file needs an extension (e.g. .mp4)"

[[ -n "$factor" ]] || die "give the speed with -x (2 = twice as fast, 0.5 = half speed)"
[[ "$factor" =~ ^[0-9]*\.?[0-9]+$ ]] || die "-x expects a number like 2 or 0.5, got '$factor'"
if lt "$factor" 0.25 || lt 4 "$factor"; then die "-x must be between 0.25 and 4, got $factor"; fi
if $interp && ! lt "$factor" 1; then die "-i (smooth slow motion) only works when slowing down (-x below 1)"; fi
# 2.50 -> 2.5, for labels and filters
factor=$(awk -v f="$factor" 'BEGIN { printf "%g", f }')
s=0
e=""
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi

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

duration=$(probe -show_entries format=duration)
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $in"

# Cover art in MP3/M4A files shows up as a video stream; only count real video.
has_video=false
has_audio=false
grep -qx 0 <<<"$(probe -select_streams v -show_entries stream_disposition=attached_pic)" && has_video=true
acodec=$(probe -select_streams a:0 -show_entries stream=codec_name)
[[ -n "$acodec" ]] && has_audio=true
$has_video || $has_audio || die "no audio or video found in $in"

if $has_video; then
  IFS=, read -r iw ih < <(probe -select_streams v:0 -show_entries stream=width,height)
  # H.264 in yuv420p needs even sizes: an odd size loses its last row/column.
  even=""
  if (( iw % 2 || ih % 2 )); then even="crop=$(( iw / 2 * 2 )):$(( ih / 2 * 2 )):0:0,"; iw=$(( iw / 2 * 2 )); ih=$(( ih / 2 * 2 )); fi
  rate=$(probe -select_streams v:0 -show_entries stream=r_frame_rate)
  [[ "$rate" =~ ^[0-9]+(/[0-9]+)?$ && "$rate" != 0* ]] || die "could not read the frame rate of $in"
  fps=$(awk -v r="$rate" 'BEGIN { n = split(r, p, "/"); printf "%.6f", (n == 2 ? p[1] / p[2] : p[1]) }')
fi
if $has_audio; then
  srate=$(probe -select_streams a:0 -show_entries stream=sample_rate)
  [[ "$srate" =~ ^[0-9]+$ ]] || die "could not read the sample rate of $in"
fi
if $interp && ! $has_video; then die "-i needs a video; $in only has sound"; fi

# --- Work out the parts ------------------------------------------------------

lt "$s" "$duration" || die "start ${start:-0} is past the end of the file ($(calc "$duration") s)"
# An end past the end of the file just means "to the end".
if [[ -n "$e" ]] && ! lt "$e" "$duration"; then e=""; fi
if [[ -n "$e" ]] && ! lt "$s" "$e"; then die "end ($end) must be after start (${start:-0})"; fi

# Cut on frame boundaries so the parts join without a gap in picture or sound.
snap() { awk -v t="$1" -v f="$fps" 'BEGIN { printf "%.6f", int(t * f + 0.5) / f }'; }
if $has_video; then
  s=$(snap "$s")
  if [[ -n "$e" ]]; then e=$(snap "$e"); fi
  if [[ -n "$e" ]] && ! lt "$s" "$e"; then die "the range ${start:-0} to $end is shorter than one frame"; fi
fi

# Each part is "start:end:factor" in seconds; an empty end means "to the end".
segs=()
if lt 0 "$s"; then segs+=("0:$s:1"); fi
segs+=("$s:$e:$factor")
if [[ -n "$e" ]]; then segs+=("$e::1"); fi
n=${#segs[@]}

# atempo works best between 0.5 and 2, so bigger changes are made in steps.
tempo_chain() {
  awk -v f="$1" 'BEGIN { s = ""; while (f > 2) { s = s "atempo=2,"; f /= 2 }
                         while (f < 0.5) { s = s "atempo=0.5,"; f /= 0.5 }
                         printf "%satempo=%.6f", s, f }'
}

# --- Output name ---------------------------------------------------------------

in_ext="${in##*.}"
out_ext=mp4
$has_video || out_ext="$in_ext"
if [[ -z "$out" ]]; then
  base="${in%.*}"
  out="$base (${factor}x).$out_ext"
  i=2
  while [[ -e "$out" ]]; do
    out="$base (${factor}x $i).$out_ext"
    i=$((i + 1))
  done
fi
[[ "$(abspath "$out")" != "$(abspath "$in")" ]] || die "output would overwrite the input"
out_ext=$(lower "${out##*.}")
case "$out_ext" in
  mp3|m4a|aac|wav|flac|ogg|opus|aif|aiff) has_video=false ;;
esac
if ! $has_video && ! $has_audio; then die "$in has no audio to save as .$out_ext"; fi

# --- Build the filter --------------------------------------------------------

inputs=()
graph=""
concat_in=""
for ((i = 0; i < n; i++)); do
  IFS=: read -r a b f <<<"${segs[$i]}"
  if lt 0 "$a"; then inputs+=(-ss "$a"); fi
  if [[ -n "$b" ]]; then inputs+=(-t "$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.6f", b - a }')"); fi
  inputs+=(-i "$in")

  if $has_video; then
    # minterpolate needs a frame after the last one to blend towards, so the
    # last frame is repeated twice and the result cut to the expected length.
    if [[ -n "$b" ]]; then seg_len=$(awk -v a="$a" -v b="$b" 'BEGIN { print b - a }'); else seg_len=$(awk -v a="$a" -v d="$duration" 'BEGIN { print d - a }'); fi
    frames_out=$(awk -v l="$seg_len" -v r="$fps" -v f="$f" 'BEGIN { printf "%d", l * r / f + 0.5 }')
    if [[ "$f" == 1 ]]; then
      graph+="[$i:v:0]${even}setpts=PTS-STARTPTS,fps=$rate[v$i];"
    elif $interp; then
      mode="mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
      if $fast; then mode="mi_mode=blend"; fi
      graph+="[$i:v:0]${even}setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop=2,setpts=PTS/$f,minterpolate=fps=$rate:$mode,trim=end_frame=$frames_out[v$i];"
    else
      graph+="[$i:v:0]${even}setpts=(PTS-STARTPTS)/$f,fps=$rate[v$i];"
    fi
    concat_in+="[v$i]"
  fi
  if $has_audio; then
    if [[ "$f" == 1 ]]; then
      graph+="[$i:a:0]asetpts=PTS-STARTPTS[a$i];"
    elif $pitch; then
      graph+="[$i:a:0]asetpts=PTS-STARTPTS,asetrate=$(awk -v r="$srate" -v f="$f" 'BEGIN { printf "%d", r * f + 0.5 }'),aresample=$srate[a$i];"
    else
      graph+="[$i:a:0]asetpts=PTS-STARTPTS,$(tempo_chain "$f")[a$i];"
    fi
    concat_in+="[a$i]"
  fi
done

v=0; a=0; maps=()
if $has_video; then v=1; maps+=(-map "[v]"); fi
if $has_audio; then a=1; maps+=(-map "[a]"); fi
if [[ $n -eq 1 ]]; then
  graph="${graph%;}"
  graph="${graph//\[v0\]/[v]}"
  graph="${graph//\[a0\]/[a]}"
else
  labels=""
  if $has_video; then labels+="[v]"; fi
  if $has_audio; then labels+="[a]"; fi
  graph+="${concat_in}concat=n=$n:v=$v:a=$a$labels"
fi

# --- Run ffmpeg --------------------------------------------------------------

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y "${inputs[@]}" -filter_complex "$graph" "${maps[@]}")
if $has_video; then
  if $fast; then
    cmd+=(-c:v libx264 -crf 23 -preset veryfast -pix_fmt yuv420p)
  else
    cmd+=(-c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p)
  fi
fi
if $has_audio; then
  case "$out_ext" in
    mp3)           cmd+=(-c:a libmp3lame -q:a 0) ;;
    webm|ogg|opus) cmd+=(-c:a libopus -b:a 192k) ;;
    flac)          cmd+=(-c:a flac) ;;
    wav|aif|aiff)  ;; # ffmpeg's default for these is uncompressed PCM
    *)             cmd+=(-c:a aac -b:a 192k) ;;
  esac
fi
case "$out_ext" in
  mp4|m4v|mov|m4a) cmd+=(-movflags +faststart) ;;
esac
cmd+=(-map_chapters -1 "$out")

if [[ -z "$e" ]]; then changed=$(calc "$duration - $s"); else changed=$(calc "$e - $s"); fi
new_len=$(calc "$changed / $factor")
how="keeping the pitch"
if $pitch; then how="pitch follows the speed"; fi
if ! $has_audio; then how="no sound"; fi
if $interp; then how+=", smooth slow motion"; fi
if [[ $n -eq 1 ]]; then
  echo "Whole file at ${factor}x: $(calc "$duration") s becomes about $new_len s ($how)..."
else
  echo "$(hms "$s") to $(hms "${e:-$duration}") at ${factor}x: $changed s becomes $new_len s," \
       "at $(hms "$s") to $(hms "$(calc "$s + $new_len")") in the result ($how)..."
fi
if ! "${cmd[@]}"; then
  rm -f "$out"
  die "ffmpeg failed"
fi

# A quick summary so the result can be checked without another probe.
read -r dur <<<"$("$FP" -v error -show_entries format=duration -of csv=p=0 "$out")"
if $has_video; then
  printf 'Result: %sx%s, %s fps, %.2f s (was %.2f s)\n' "$iw" "$ih" "$(awk -v f="$fps" 'BEGIN { printf "%g", f }')" "$dur" "$duration"
else
  printf 'Result: %.2f s (was %.2f s)\n' "$dur" "$duration"
fi
echo "Saved to: $out"
